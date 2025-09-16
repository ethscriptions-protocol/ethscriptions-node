class EthscriptionDetector
  include SysConfig

  # Event signatures
  ESIP1_SIG = '0x' + Eth::Util.keccak256('ethscriptions_protocol_TransferEthscription(address,bytes32)').unpack1('H*')
  ESIP2_SIG = '0x' + Eth::Util.keccak256('ethscriptions_protocol_TransferEthscriptionForPreviousOwner(address,address,bytes32)').unpack1('H*')
  CREATE_SIG = '0x' + Eth::Util.keccak256('ethscriptions_protocol_CreateEthscription(address,string)').unpack1('H*')

  attr_reader :operations

  def initialize(eth_transaction)
    @eth_tx = eth_transaction
    @operations = []
    @seen_creates = Set.new  # Deduplicate creates by tx hash
    detect_all_operations
  end

  private

  def detect_all_operations
    return unless @eth_tx.status == 1

    # 1. Check for creation (from input or events)
    detect_creation

    # 2. Process transfers via input (single transfers from genesis, multi from ESIP-5)
    process_input_transfers

    # 3. Process transfers via events (ESIP-1/2)
    process_event_transfers
  end

  def detect_creation
    content = decoded_input
    if @eth_tx.to_address.present? && content && DataUri.valid?(content)
      add_create_operation(
        transaction_hash: @eth_tx.transaction_hash,
        creator: @eth_tx.from_address,  # L1 sender is creator
        initial_owner: @eth_tx.to_address,
        content_uri: content,
        source: :input
      )
    end

    # Also check for create events (ESIP-3)
    if SysConfig.esip3_enabled?(@eth_tx.block_number) && @eth_tx.logs
      process_create_events
    end
  end

  def process_create_events
    ordered_events.each do |log|
      next unless log['topics']&.first == CREATE_SIG

      begin
        # Exact topic length match like original
        next unless log['topics'].length == 2

        # Decode exactly like the original
        initial_owner = Eth::Abi.decode(['address'], log['topics'].second).first
        content_uri_data = Eth::Abi.decode(['string'], log['data']).first
        content_uri = HexDataProcessor.clean_utf8(content_uri_data)

        add_create_operation(
          transaction_hash: @eth_tx.transaction_hash,
          creator: log['address'],  # Contract address is creator for events (matches original)
          initial_owner: initial_owner,
          content_uri: content_uri,
          event_log_index: log['logIndex'].to_i(16),
          source: :event
        )
      rescue Eth::Abi::DecodingError => e
        Rails.logger.error "Failed to decode create event: #{e.message}"
        next
      end
    end
  end

  def process_event_transfers
    ordered_events.each do |log|
      begin
        case log['topics']&.first
        when ESIP1_SIG
          handle_esip1_event(log) if SysConfig.esip1_enabled?(@eth_tx.block_number)
        when ESIP2_SIG
          handle_esip2_event(log) if SysConfig.esip2_enabled?(@eth_tx.block_number)
        end
      rescue Eth::Abi::DecodingError => e
        Rails.logger.error "Failed to decode transfer event: #{e.message}"
        next
      end
    end
  end

  def process_input_transfers
    return unless @eth_tx.to_address.present?

    # ByteString to hex conversion
    input_hex = @eth_tx.input.to_hex.delete_prefix('0x')

    # Check for valid transfer input
    # Single transfers (64 chars) supported from genesis
    # Multi transfers (n*64 chars) supported from ESIP-5
    valid_length = if SysConfig.esip5_enabled?(@eth_tx.block_number)
      # ESIP-5: Allow multiple transfers
      input_hex.length > 0 && input_hex.length % 64 == 0
    else
      # Pre-ESIP-5: Only single transfers (exactly 64 hex chars)
      input_hex.length == 64
    end

    return unless valid_length

    # Parse each 32-byte hash
    input_hex.scan(/.{64}/).each_with_index do |hash_hex, index|
      @operations << {
        type: :transfer,
        ethscription_id: normalize_hash("0x#{hash_hex}"),
        from: normalize_address(@eth_tx.from_address),  # Sender for input transfers
        to: normalize_address(@eth_tx.to_address),
        transfer_index: index
      }
    end
  end

  def handle_esip1_event(log)
    # Exact topic length match like original
    return unless log['topics'].length == 3

    # Decode exactly like the original
    event_to = Eth::Abi.decode(['address'], log['topics'].second).first
    tx_hash = Eth::Util.bin_to_prefixed_hex(
      Eth::Abi.decode(['bytes32'], log['topics'].third).first
    )

    @operations << {
      type: :transfer,
      ethscription_id: normalize_hash(tx_hash),
      from: normalize_address(log['address']),  # Contract address (matches original)
      to: normalize_address(event_to),
      event_log_index: log['logIndex'].to_i(16)
    }
  end

  def handle_esip2_event(log)
    # Exact topic length match like original
    return unless log['topics'].length == 4

    # Decode exactly like the original
    event_previous_owner = Eth::Abi.decode(['address'], log['topics'].second).first
    event_to = Eth::Abi.decode(['address'], log['topics'].third).first
    tx_hash = Eth::Util.bin_to_prefixed_hex(
      Eth::Abi.decode(['bytes32'], log['topics'].fourth).first
    )

    @operations << {
      type: :transfer_with_previous_owner,
      ethscription_id: normalize_hash(tx_hash),
      from: normalize_address(log['address']),  # Contract address (matches original)
      to: normalize_address(event_to),
      previous_owner: normalize_address(event_previous_owner),
      event_log_index: log['logIndex'].to_i(16)
    }
  end


  def ordered_events
    # Handle nil or missing logs gracefully
    return [] if @eth_tx.logs.nil?

    @eth_tx.logs.reject { |log| log['removed'] }
                .sort_by { |log| log['logIndex'].to_i(16) }
  end

  def add_create_operation(params)
    # Deduplicate creates by transaction hash
    tx_hash = normalize_hash(params[:transaction_hash])
    return if @seen_creates.include?(tx_hash)
    @seen_creates.add(tx_hash)

    data_uri = DataUri.new(params[:content_uri])

    @operations << {
      type: :create,
      transaction_hash: tx_hash,
      creator: normalize_address(params[:creator]),
      initial_owner: normalize_address(params[:initial_owner]),
      content_uri: params[:content_uri],
      mimetype: data_uri.mimetype,
      esip6: DataUri.esip6?(params[:content_uri]),
      esip7_compressed: false,  # Will add compression detection later
      event_log_index: params[:event_log_index],
      source: params[:source]
    }
  end

  def decoded_input
    HexDataProcessor.hex_to_utf8(
      @eth_tx.input.to_hex,
      support_gzip: SysConfig.esip7_enabled?(@eth_tx.block_number)
    )
  end
  
  def normalize_address(addr)
    return nil unless addr
    # Handle both Address20 objects and strings
    addr_str = addr.respond_to?(:to_hex) ? addr.to_hex : addr.to_s
    addr_str.downcase
  end

  def normalize_hash(hash)
    return nil unless hash
    # Handle both Hash32 objects and strings
    hash_str = hash.respond_to?(:to_hex) ? hash.to_hex : hash.to_s
    hash_str.downcase
  end
end

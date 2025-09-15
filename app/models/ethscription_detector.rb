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

    # 2. Check for transfers via events (ESIP-1/2)
    detect_event_transfers if SysConfig.esip1_enabled?(@eth_tx.block_number)

    # 3. Check for transfers via input (ESIP-5)
    detect_input_transfers if SysConfig.esip5_enabled?(@eth_tx.block_number)
  end

  def detect_creation
    if @eth_tx.to_address.present? && DataUri.valid?(decoded_input)
      add_create_operation(
        transaction_hash: @eth_tx.transaction_hash,
        creator: @eth_tx.from_address,  # L1 sender is creator
        initial_owner: @eth_tx.to_address,
        content_uri: decoded_input,
        source: :input
      )
    end

    # Also check for create events (ESIP-3)
    if SysConfig.esip3_enabled?(@eth_tx.block_number) && @eth_tx.logs
      detect_create_events
    end
  end

  def detect_create_events
    @eth_tx.logs.each do |log|
      next if log['removed']
      next unless log['topics']&.first == CREATE_SIG

      begin
        handle_create_event(log)
      rescue Eth::Abi::DecodingError => e
        Rails.logger.error "Failed to decode create event: #{e.message}"
      end
    end
  end

  def detect_event_transfers
    return unless @eth_tx.logs

    @eth_tx.logs.each_with_index do |log, index|
      next if log['removed']

      begin
        case log['topics']&.first
        when ESIP1_SIG
          handle_esip1_event(log, index) if SysConfig.esip1_enabled?(@eth_tx.block_number)
        when ESIP2_SIG
          handle_esip2_event(log, index) if SysConfig.esip2_enabled?(@eth_tx.block_number)
        end
      rescue Eth::Abi::DecodingError => e
        Rails.logger.error "Failed to decode transfer event: #{e.message}"
      end
    end
  end

  def detect_input_transfers
    return unless @eth_tx.to_address.present? && @eth_tx.status == 1

    # ByteString to hex conversion
    input_hex = @eth_tx.input.to_hex.delete_prefix('0x')

    # Check for valid transfer input (64 hex chars = 32 bytes per hash)
    valid_length = if SysConfig.esip5_enabled?(@eth_tx.block_number)
      input_hex.length > 0 && input_hex.length % 64 == 0
    else
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

  def handle_esip1_event(log, index)
    return unless log['topics'].size == 3

    to_address = decode_address(log['topics'][1])
    ethscription_id = log['topics'][2]

    @operations << {
      type: :transfer,
      ethscription_id: normalize_hash(ethscription_id),
      from: normalize_address(log['address']),  # Contract address (matches original)
      to: normalize_address(to_address),
      event_log_index: log['logIndex'].to_i(16)
    }
  end

  def handle_esip2_event(log, index)
    return unless log['topics'].size == 4

    previous_owner = decode_address(log['topics'][1])
    to_address = decode_address(log['topics'][2])
    ethscription_id = log['topics'][3]

    @operations << {
      type: :transfer_with_previous_owner,
      ethscription_id: normalize_hash(ethscription_id),
      from: normalize_address(log['address']),  # Contract address (matches original)
      to: normalize_address(to_address),
      previous_owner: normalize_address(previous_owner),
      event_log_index: log['logIndex'].to_i(16)
    }
  end

  def handle_create_event(log)
    return unless log['topics'].size == 2

    initial_owner = decode_address(log['topics'][1])
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
  end

  def add_create_operation(params)
    # Deduplicate creates by transaction hash
    tx_hash = normalize_hash(params[:transaction_hash])
    return if @seen_creates.include?(tx_hash)
    @seen_creates.add(tx_hash)

    # Validate and parse data URI
    return unless DataUri.valid?(params[:content_uri])
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

  def decode_address(topic)
    # Topics are 32 bytes, addresses are last 20 bytes
    "0x#{topic[-40..]}"
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

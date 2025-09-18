class EthscriptionTransaction < T::Struct
  include SysConfig
  include AttrAssignable

  # Only what's needed for to_deposit_payload
  prop :from_address, T.nilable(Address20)

  # Block reference (used by importer)
  prop :ethscriptions_block, T.nilable(EthscriptionsBlock)

  # Operation data (for building calldata and validation)
  prop :eth_transaction, T.nilable(Object)

  # Create operation fields
  prop :creator, T.nilable(String)
  prop :initial_owner, T.nilable(String)
  prop :content_uri, T.nilable(String)

  # Transfer operation fields
  prop :ethscription_id, T.nilable(String)
  prop :transfer_from_address, T.nilable(String)
  prop :transfer_to_address, T.nilable(String)
  prop :enforced_previous_owner, T.nilable(String)
  prop :input_index, T.nilable(Integer)
  prop :log_index, T.nilable(Integer)

  # Debug info (can be removed if not needed)
  prop :ethscription_operation, T.nilable(String) # 'create', 'transfer', 'transfer_with_previous_owner'

  DEPOSIT_TX_TYPE = 0x7D
  MINT = 0
  VALUE = 0
  GAS_LIMIT = 1_000_000_000
  TO_ADDRESS = SysConfig::ETHSCRIPTIONS_ADDRESS
  
  class << self
    def reset_seen_creates!
      @seen_creates = Concurrent::Set.new
    end

    def add_seen_create(tx_hash)
      seen_creates.add(tx_hash)
    end

    # Thread-safe lazy initialization
    def seen_creates
      @seen_creates_mutex ||= Mutex.new
      return @seen_creates if @seen_creates

      @seen_creates_mutex.synchronize do
        @seen_creates ||= Concurrent::Set.new
      end
    end
  end

  # Dynamic source hash based on operation type
  def source_hash
    case ethscription_operation
    when 'create'
      # Creates are one-to-one with transactions
      eth_transaction.transaction_hash
    when 'transfer', 'transfer_with_previous_owner'
      # Transfers need unique hash within transaction
      if input_index
        compute_transfer_source_hash(:input, input_index)
      elsif log_index
        compute_transfer_source_hash(:event, log_index)
      else
        raise "Transfer must have either input_index or log_index"
      end
    else
      raise "Unknown ethscription operation: #{ethscription_operation}"
    end
  end


  # Factory method for create operations
  def self.create_ethscription(
    eth_transaction:,
    creator:,
    initial_owner:,
    content_uri:
  )
    new(
      from_address: Address20.from_hex(creator.is_a?(String) ? creator : creator.to_hex),
      eth_transaction: eth_transaction,
      creator: creator,
      initial_owner: initial_owner,
      content_uri: content_uri,
      ethscription_operation: 'create'
    )
  end

  # Factory method for transfer operations
  def self.transfer_ethscription(
    eth_transaction:,
    from_address:,
    to_address:,
    ethscription_id:,
    enforced_previous_owner: nil,
    input_index: nil,
    log_index: nil
  )
    operation_type = enforced_previous_owner ? 'transfer_with_previous_owner' : 'transfer'

    new(
      from_address: Address20.from_hex(from_address.is_a?(String) ? from_address : from_address.to_hex),
      eth_transaction: eth_transaction,
      ethscription_id: ethscription_id,
      transfer_from_address: from_address,
      transfer_to_address: to_address,
      enforced_previous_owner: enforced_previous_owner,
      input_index: input_index,
      log_index: log_index,
      ethscription_operation: operation_type
    )
  end

  # Instance method to compute transfer source hash
  def compute_transfer_source_hash(operation_type, index)
    tag = (operation_type == :input) ? 0 : 1
    payload = ByteString.from_bin(
      eth_transaction.transaction_hash.to_bin +
      Eth::Util.zpad_int(tag, 32) +
      Eth::Util.zpad_int(index, 32)
    )
    bin_val = Eth::Util.keccak256(
      Eth::Util.zpad_int(2, 32) + Eth::Util.keccak256(payload.to_bin)
    )
    Hash32.from_bin(bin_val)
  end

  # Check if this is a valid, unseen ethscription
  def valid_and_unseen?
    valid_ethscription? && !already_seen?
  end

  # Mark this transaction as seen (for create deduplication)
  def mark_as_seen!
    if ethscription_operation == 'create'
      self.class.add_seen_create(source_hash)
    end
  end

  # Check if we've already seen this create transaction
  def already_seen?
    return false unless ethscription_operation == 'create'
    self.class.seen_creates.include?(source_hash)
  end

  # Check if this is a valid ethscription
  def valid_ethscription?
    case ethscription_operation
    when 'create'
      valid_create?
    when 'transfer', 'transfer_with_previous_owner'
      valid_transfer?
    else
      raise "Unknown ethscription operation: #{ethscription_operation}"
    end
  end

  def valid_create?
    content_uri.present? &&
    creator.present? &&
    initial_owner.present? &&
    DataUri.valid?(content_uri)
  end

  def valid_transfer?
    # Basic field validation - if we extracted the data properly, ABI encoding should work
    ethscription_id.present? &&
    transfer_from_address.present? &&
    transfer_to_address.present?
  end

  public

  # Dynamic input method - builds calldata on demand
  def input
    return @cached_input if defined?(@cached_input)

    @cached_input = case ethscription_operation
    when 'create'
      ByteString.from_bin(build_create_calldata)
    when 'transfer'
      ByteString.from_bin(build_transfer_calldata)
    when 'transfer_with_previous_owner'
      ByteString.from_bin(build_transfer_with_previous_owner_calldata)
    else
      raise "Unknown ethscription operation: #{ethscription_operation}"
    end
  end

  # Method for deposit payload generation (used by GethDriver)
  sig { returns(ByteString) }
  def to_deposit_payload
    tx_data = []
    tx_data.push(source_hash.to_bin)
    tx_data.push(from_address.to_bin)
    tx_data.push(TO_ADDRESS.to_bin)
    tx_data.push(Eth::Util.serialize_int_to_big_endian(MINT))
    tx_data.push(Eth::Util.serialize_int_to_big_endian(VALUE))
    tx_data.push(Eth::Util.serialize_int_to_big_endian(GAS_LIMIT))
    tx_data.push('')
    tx_data.push(input.to_bin)
    tx_encoded = Eth::Rlp.encode(tx_data)

    tx_type = Eth::Util.serialize_int_to_big_endian(DEPOSIT_TX_TYPE)
    ByteString.from_bin("#{tx_type}#{tx_encoded}")
  end

  # Build calldata for create operations (same for both input and event-based)
  def build_create_calldata
    # Get function selector as binary
    function_sig = Eth::Util.keccak256(
      'createEthscription((bytes32,bytes32,address,bytes,string,string,string,bool,(string,string,string,uint256,uint256,uint256)))'
    )[0...4].b

    # Both input and event-based creates use data URI format
    # Events are "equivalent of an EOA hex-encoding contentURI and putting it in the calldata"
    data_uri = DataUri.new(content_uri)
    mimetype = data_uri.mimetype.to_s
    media_type = mimetype&.split('/')&.first
    mime_subtype = mimetype&.split('/')&.last
    raw_content = data_uri.decoded_data.b
    esip6 = DataUri.esip6?(content_uri) || false
    token_params = TokenParamsExtractor.extract(content_uri)

    # Hash the content for protocol uniqueness
    content_uri_hash_hex = Digest::SHA256.hexdigest(content_uri)
    content_uri_hash = [content_uri_hash_hex].pack('H*')

    # Convert hex strings to binary for ABI encoding
    tx_hash_bin = hex_to_bin(eth_transaction.transaction_hash)
    owner_bin = address_to_bin(initial_owner)

    # Encode parameters
    params = [
      tx_hash_bin,                            # bytes32 transactionHash
      content_uri_hash,                        # bytes32 contentUriHash
      owner_bin,                               # address
      raw_content,                             # bytes content
      mimetype.b,                              # string
      media_type.to_s.b,                       # string
      mime_subtype.to_s.b,                     # string
      esip6,                                   # bool esip6
      token_params                             # TokenParams tuple
    ]

    encoded = Eth::Abi.encode(
      ['(bytes32,bytes32,address,bytes,string,string,string,bool,(string,string,string,uint256,uint256,uint256))'],
      [params]
    )

    # Ensure binary encoding
    (function_sig + encoded).b
  end

  def build_transfer_calldata
    # Get function selector as binary
    function_sig = Eth::Util.keccak256('transferEthscription(address,bytes32)')[0...4].b

    # Convert to binary for ABI
    to_bin = address_to_bin(transfer_to_address)
    id_bin = hex_to_bin(ethscription_id)

    encoded = Eth::Abi.encode(['address', 'bytes32'], [to_bin, id_bin])

    # Ensure binary encoding
    (function_sig + encoded).b
  end

  def build_transfer_with_previous_owner_calldata
    # Get function selector as binary
    function_sig = Eth::Util.keccak256(
      'transferEthscriptionForPreviousOwner(address,bytes32,address)'
    )[0...4].b

    # Convert to binary for ABI
    to_bin = address_to_bin(transfer_to_address)
    id_bin = hex_to_bin(ethscription_id)
    prev_bin = address_to_bin(enforced_previous_owner)

    encoded = Eth::Abi.encode(['address', 'bytes32', 'address'], [to_bin, id_bin, prev_bin])

    # Ensure binary encoding
    (function_sig + encoded).b
  end

  # Helper to convert hex string to binary
  def hex_to_bin(hex_str)
    return nil unless hex_str
    # Hash32 objects have .to_bin, strings need conversion
    hex_str.respond_to?(:to_bin) ? hex_str.to_bin : [hex_str.delete_prefix('0x')].pack('H*')
  end

  # Helper to convert address to binary (20 bytes)
  def address_to_bin(addr_str)
    return nil unless addr_str
    # Handle Address20 objects that have .to_bin method
    if addr_str.respond_to?(:to_bin)
      return addr_str.to_bin
    end

    clean_hex = addr_str.to_s.delete_prefix('0x')
    # Ensure 20 bytes (40 hex chars)
    clean_hex = clean_hex.rjust(40, '0')[-40..]
    [clean_hex].pack('H*')
  end
end
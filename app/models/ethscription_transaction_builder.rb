class EthscriptionTransactionBuilder
  include SysConfig

  # Build deposit transactions from an L1 transaction
  def self.build_deposits(eth_transaction, ethscriptions_block)
    detector = EthscriptionDetector.new(eth_transaction)

    deposits = []
    detector.operations.each_with_index do |operation, index|
      deposit = build_single_deposit(
        operation: operation,
        eth_transaction: eth_transaction,
        ethscriptions_block: ethscriptions_block,
        operation_index: index
      )
      deposits << deposit if deposit
    end

    deposits
  end

  private

  def self.build_single_deposit(operation:, eth_transaction:, ethscriptions_block:, operation_index:)
    # Build calldata based on operation type
    calldata = case operation[:type]
    when :create
      build_create_calldata(operation)
    when :transfer
      build_transfer_calldata(operation)
    when :transfer_with_previous_owner
      build_transfer_with_previous_owner_calldata(operation)
    else
      return nil
    end

    # Generate source hash
    # source_hash = generate_source_hash(eth_transaction.transaction_hash, operation_index)

    # Build the T::Struct deposit transaction
    EthscriptionTransaction.new(
      chain_id: ChainIdManager.current_l2_chain_id,
      eth_transaction_hash: eth_transaction.transaction_hash,
      eth_transaction_input: eth_transaction.input,
      eth_call_index: operation_index,
      block_hash: ethscriptions_block.block_hash,
      block_number: ethscriptions_block.number,
      deposit_receipt_version: '0x01',
      from_address: Address20.from_hex(determine_from_address(operation)),
      gas_limit: 1_000_000_000,  # High limit for large creates
      tx_hash: eth_transaction.transaction_hash,
      input: ByteString.from_bin(calldata),
      source_hash: eth_transaction.transaction_hash,
      to_address: SysConfig::ETHSCRIPTIONS_ADDRESS,
      transaction_index: nil,  # Set during block building
      mint: 0,
      value: 0,
      ethscriptions_block: ethscriptions_block,
      ethscription_operation: operation[:type].to_s,
      ethscription_data: operation
    )
  end

  def self.build_create_calldata(operation)
    # Get function selector as binary
    function_sig = Eth::Util.keccak256(
      'createEthscription((bytes32,bytes32,address,bytes,string,string,string,bool,bool,(string,string,string,uint256,uint256,uint256)))'
    )[0...4].b

    # Parse mimetype
    mimetype = operation[:mimetype].to_s
    media_type = mimetype&.split('/')&.first
    mime_subtype = mimetype&.split('/')&.last

    # Hash the raw content URI for protocol uniqueness
    content_uri_hash_hex = Digest::SHA256.hexdigest(operation[:content_uri].to_s)
    content_uri_hash = [content_uri_hash_hex].pack('H*')  # Convert to binary

    # Parse the data URI and extract content
    data_uri = DataUri.new(operation[:content_uri].to_s)
    # decoded_data only decodes base64, otherwise returns data as-is (preserving percent-encoding)
    # TODO: Decode percent encoding?
    raw_content = data_uri.decoded_data.b
    was_base64 = data_uri.base64?

    # Convert hex strings to binary for ABI encoding
    tx_hash_bin = hex_to_bin(operation[:transaction_hash])
    owner_bin = address_to_bin(operation[:initial_owner])

    # Encode parameters with proper binary values
    params = [
      tx_hash_bin,                            # bytes32 transactionHash (binary)
      content_uri_hash,                        # bytes32 contentUriHash (binary)
      owner_bin,                               # address (binary)
      raw_content,                             # bytes content (decoded raw bytes)
      mimetype.b,                              # string
      media_type.to_s.b,                       # string
      mime_subtype.to_s.b,                     # string
      was_base64,                              # bool wasBase64
      operation[:esip6] || false,              # bool esip6
      ['', '', '', 0, 0, 0]                   # TokenParams tuple
    ]

    encoded = Eth::Abi.encode(
      ['(bytes32,bytes32,address,bytes,string,string,string,bool,bool,(string,string,string,uint256,uint256,uint256))'],
      [params]
    )
    # binding.irb if operation[:transaction_hash] == '0x3ee220285361b903eef2e05a7d4d5379a03db81868d350bcb3710cc55821d278'
    # Ensure binary encoding
    (function_sig + encoded).b
  rescue => e
    binding.irb
    raise e
  end

  def self.build_transfer_calldata(operation)
    # Get function selector as binary
    function_sig = Eth::Util.keccak256('transferEthscription(address,bytes32)')[0...4].b

    # Convert to binary for ABI
    to_bin = address_to_bin(operation[:to])
    id_bin = hex_to_bin(operation[:ethscription_id])

    encoded = Eth::Abi.encode(['address', 'bytes32'], [to_bin, id_bin])

    # Ensure binary encoding
    (function_sig + encoded).b
  end

  def self.build_transfer_with_previous_owner_calldata(operation)
    # Get function selector as binary
    function_sig = Eth::Util.keccak256(
      'transferEthscriptionForPreviousOwner(address,bytes32,address)'
    )[0...4].b

    # Convert to binary for ABI
    to_bin = address_to_bin(operation[:to])
    id_bin = hex_to_bin(operation[:ethscription_id])
    prev_bin = address_to_bin(operation[:previous_owner])

    encoded = Eth::Abi.encode(['address', 'bytes32', 'address'], [to_bin, id_bin, prev_bin])

    # Ensure binary encoding
    (function_sig + encoded).b
  end

  def self.determine_from_address(operation)
    case operation[:type]
    when :create
      operation[:creator]
    when :transfer, :transfer_with_previous_owner
      operation[:from]
    else
      raise "Unknown operation type: #{operation[:type]}"
    end
  end

  def self.generate_source_hash(l1_tx_hash, index)
    # Deterministic hash: L1 tx hash + operation index
    data = [
      l1_tx_hash.to_hex.delete_prefix('0x'),
      index.to_s(16).rjust(8, '0')
    ].join

    Hash32.new('0x' + Eth::Util.keccak256([data].pack('H*')).unpack1('H*'))
  end

  # Helper to convert hex string to binary
  def self.hex_to_bin(hex_str)
    return nil unless hex_str
    clean_hex = hex_str.to_s.delete_prefix('0x')
    [clean_hex].pack('H*')
  end

  # Helper to convert address to binary (20 bytes)
  def self.address_to_bin(addr_str)
    return nil unless addr_str
    clean_hex = addr_str.to_s.delete_prefix('0x')
    # Ensure 20 bytes (40 hex chars)
    clean_hex = clean_hex.rjust(40, '0')[-40..]
    [clean_hex].pack('H*')
  end
end
class CollectionsReader
  COLLECTIONS_MANAGER_ADDRESS = '0x3300000000000000000000000000000000000006'

  # Define struct ABIs matching CollectionsManager.sol
  COLLECTION_METADATA_STRUCT = {
    'components' => [
      { 'name' => 'name', 'type' => 'string' },
      { 'name' => 'symbol', 'type' => 'string' },
      { 'name' => 'totalSupply', 'type' => 'uint256' },
      { 'name' => 'description', 'type' => 'string' },
      { 'name' => 'logoImageUri', 'type' => 'string' },
      { 'name' => 'bannerImageUri', 'type' => 'string' },
      { 'name' => 'backgroundColor', 'type' => 'string' },
      { 'name' => 'websiteLink', 'type' => 'string' },
      { 'name' => 'twitterLink', 'type' => 'string' },
      { 'name' => 'discordLink', 'type' => 'string' }
    ],
    'type' => 'tuple'
  }

  COLLECTION_STATE_STRUCT = {
    'components' => [
      { 'name' => 'collectionContract', 'type' => 'address' },
      { 'name' => 'createTxHash', 'type' => 'bytes32' },
      { 'name' => 'currentSize', 'type' => 'uint256' },
      { 'name' => 'locked', 'type' => 'bool' }
    ],
    'type' => 'tuple'
  }

  # Contract ABI for functions we need
  CONTRACT_ABI = [
    {
      'name' => 'collectionState',
      'type' => 'function',
      'stateMutability' => 'view',
      'inputs' => [
        { 'name' => 'collectionId', 'type' => 'bytes32' }
      ],
      'outputs' => [
        COLLECTION_STATE_STRUCT
      ]
    },
    {
      'name' => 'collectionMetadata',
      'type' => 'function',
      'stateMutability' => 'view',
      'inputs' => [
        { 'name' => 'collectionId', 'type' => 'bytes32' }
      ],
      'outputs' => [
        COLLECTION_METADATA_STRUCT
      ]
    }
  ]

  def self.get_collection_state(collection_id, block_tag: 'latest')
    # Encode the function call
    input_types = ['bytes32']

    # Encode parameters
    encoded_params = Eth::Abi.encode(input_types, [normalize_bytes32(collection_id)])
    function_selector = Eth::Util.keccak256('getCollectionState(bytes32)')[0..3]
    data = (function_selector + encoded_params).unpack1('H*')
    data = '0x' + data

    # Make the call
    result = EthRpcClient.l2.eth_call(
      to: COLLECTIONS_MANAGER_ADDRESS,
      data: data,
      block_number: block_tag
    )

    return nil if result == '0x' || result.nil?

    # Decode the result - expect a tuple with (address, bytes32, uint256, bool)
    output_types = ['(address,bytes32,uint256,bool)']
    # Remove '0x' prefix before packing to avoid shifting the bytes
    decoded = Eth::Abi.decode(output_types, [result.delete_prefix('0x')].pack('H*'))
    state_tuple = decoded[0]

    # Debug the raw bytes32 value
    raw_bytes32 = state_tuple[1]
    hex_value = raw_bytes32.unpack1('H*')

    # Ensure we have a proper 32-byte hex string (64 hex chars)
    if hex_value.length < 64
      hex_value = hex_value.rjust(64, '0')
    end

    {
      collectionContract: state_tuple[0],
      createTxHash: '0x' + hex_value,
      currentSize: state_tuple[2],
      locked: state_tuple[3]
    }
  end

  def self.get_collection_metadata(collection_id, block_tag: 'latest')
    # Encode the function call
    input_types = ['bytes32']

    # Encode parameters
    encoded_params = Eth::Abi.encode(input_types, [normalize_bytes32(collection_id)])
    function_selector = Eth::Util.keccak256('getCollectionMetadata(bytes32)')[0..3]
    data = (function_selector + encoded_params).unpack1('H*')
    data = '0x' + data

    # Make the call
    result = EthRpcClient.l2.eth_call(
      to: COLLECTIONS_MANAGER_ADDRESS,
      data: data,
      block_number: block_tag
    )

    return nil if result == '0x' || result.nil?

    # Decode the result - CollectionMetadata tuple with 10 string/uint256 fields
    output_types = ['(string,string,uint256,string,string,string,string,string,string,string)']
    # Remove '0x' prefix before packing to avoid shifting the bytes
    decoded = Eth::Abi.decode(output_types, [result.delete_prefix('0x')].pack('H*'))
    metadata_tuple = decoded[0]

    {
      name: metadata_tuple[0],
      symbol: metadata_tuple[1],
      totalSupply: metadata_tuple[2],
      description: metadata_tuple[3],
      logoImageUri: metadata_tuple[4],
      bannerImageUri: metadata_tuple[5],
      backgroundColor: metadata_tuple[6],
      websiteLink: metadata_tuple[7],
      twitterLink: metadata_tuple[8],
      discordLink: metadata_tuple[9]
    }
  end

  def self.collection_exists?(collection_id, block_tag: 'latest')
    state = get_collection_state(collection_id, block_tag: block_tag)
    return false if state.nil?

    # Collection exists if collectionContract is not zero address
    state[:collectionContract] != '0x0000000000000000000000000000000000000000'
  end

  private

  def self.normalize_bytes32(value)
    # Ensure value is a 32-byte hex string
    hex = value.to_s.delete_prefix('0x')
    hex = hex.rjust(64, '0') if hex.length < 64
    [hex].pack('H*')
  end
end
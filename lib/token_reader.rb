class TokenReader
  TOKEN_MANAGER_ADDRESS = '0x3300000000000000000000000000000000000002'

  # Token struct from TokenManager.sol
  TOKEN_STRUCT = {
    'components' => [
      { 'name' => 'tick', 'type' => 'string' },
      { 'name' => 'maxSupply', 'type' => 'uint256' },
      { 'name' => 'mintAmount', 'type' => 'uint256' },
      { 'name' => 'totalMinted', 'type' => 'uint256' },
      { 'name' => 'deployer', 'type' => 'address' },
      { 'name' => 'tokenContract', 'type' => 'address' },
      { 'name' => 'ethscriptionId', 'type' => 'bytes32' }
    ],
    'type' => 'tuple'
  }

  # Mint record struct
  MINT_STRUCT = {
    'components' => [
      { 'name' => 'amount', 'type' => 'uint256' },
      { 'name' => 'minter', 'type' => 'address' },
      { 'name' => 'ethscriptionId', 'type' => 'bytes32' },
      { 'name' => 'currentOwner', 'type' => 'address' }
    ],
    'type' => 'tuple'
  }

  def self.get_token(tick, block_tag: 'latest')
    # Encode function call for getTokenInfoByTick(string)
    input_types = ['string']
    encoded_params = Eth::Abi.encode(input_types, [tick])
    function_selector = Eth::Util.keccak256('getTokenInfoByTick(string)')[0..3]
    data = (function_selector + encoded_params).unpack1('H*')
    data = '0x' + data

    # Make the call
    result = EthRpcClient.l2.eth_call(
      to: TOKEN_MANAGER_ADDRESS,
      data: data,
      block_number: block_tag
    )

    return nil if result == '0x' || result.nil?

    # Decode the result - TokenInfo struct
    # struct TokenInfo {
    #   address tokenContract;
    #   bytes32 deployTxHash;
    #   string protocol;
    #   string tick;
    #   uint256 maxSupply;
    #   uint256 mintAmount;
    #   uint256 totalMinted;
    # }
    output_types = ['(address,bytes32,string,string,uint256,uint256,uint256)']
    decoded = Eth::Abi.decode(output_types, [result.delete_prefix('0x')].pack('H*'))
    token_tuple = decoded[0]

    {
      tokenContract: token_tuple[0],
      deployTxHash: '0x' + token_tuple[1].unpack1('H*'),
      protocol: token_tuple[2],
      tick: token_tuple[3],
      maxSupply: token_tuple[4],
      mintLimit: token_tuple[5], # mintAmount field is used as mintLimit
      totalMinted: token_tuple[6],
      # For backwards compatibility, add deployer field (not available in TokenInfo)
      deployer: nil,
      ethscriptionId: '0x' + token_tuple[1].unpack1('H*') # deployTxHash is the ethscriptionId
    }
  rescue => e
    Rails.logger.error "Failed to get token #{tick}: #{e.message}"
    nil
  end

  def self.token_exists?(tick, block_tag: 'latest')
    token = get_token(tick, block_tag: block_tag)
    return false if token.nil?

    # Token exists if tokenContract is not zero address
    token[:tokenContract] != '0x0000000000000000000000000000000000000000'
  end

  # Note: TokenManager doesn't track mints by tick+id, it tracks token items by ethscription hash
  # This method is kept for compatibility but may need redesign
  def self.get_token_item(ethscription_tx_hash, block_tag: 'latest')
    # Encode function call for getTokenItem(bytes32)
    input_types = ['bytes32']

    # Normalize the ethscription hash to bytes32
    hash_hex = ethscription_tx_hash.to_s.delete_prefix('0x')
    hash_hex = hash_hex.rjust(64, '0') if hash_hex.length < 64
    hash_bytes = [hash_hex].pack('H*')

    encoded_params = Eth::Abi.encode(input_types, [hash_bytes])
    function_selector = Eth::Util.keccak256('getTokenItem(bytes32)')[0..3]
    data = (function_selector + encoded_params).unpack1('H*')
    data = '0x' + data

    # Make the call
    result = EthRpcClient.l2.eth_call(
      to: TOKEN_MANAGER_ADDRESS,
      data: data,
      block_number: block_tag
    )

    return nil if result == '0x' || result.nil?

    # Decode the result - TokenItem struct
    # struct TokenItem {
    #   bytes32 deployTxHash;  // Which token this ethscription belongs to
    #   uint256 amount;        // How many tokens this ethscription represents
    # }
    output_types = ['(bytes32,uint256)']
    decoded = Eth::Abi.decode(output_types, [result.delete_prefix('0x')].pack('H*'))
    item_tuple = decoded[0]

    {
      deployTxHash: '0x' + item_tuple[0].unpack1('H*'),
      amount: item_tuple[1]
    }
  rescue => e
    Rails.logger.error "Failed to get token item #{ethscription_tx_hash}: #{e.message}"
    nil
  end

  # Legacy compatibility - mints aren't tracked by ID in new TokenManager
  def self.get_mint(tick, mint_id, block_tag: 'latest')
    # This would need to be reimplemented if mint tracking by ID is needed
    # For now, return nil as TokenManager doesn't support this
    nil
  end

  def self.mint_exists?(tick, mint_id, block_tag: 'latest')
    # TokenManager doesn't track mints by tick+id
    false
  end

  def self.get_token_balance(tick, address, block_tag: 'latest')
    token = get_token(tick, block_tag: block_tag)
    return 0 if token.nil? || token[:tokenContract] == '0x0000000000000000000000000000000000000000'

    # Call balanceOf on the ERC20 token contract
    input_types = ['address']
    encoded_params = Eth::Abi.encode(input_types, [address])
    function_selector = Eth::Util.keccak256('balanceOf(address)')[0..3]
    data = (function_selector + encoded_params).unpack1('H*')
    data = '0x' + data

    # Make the call to the token contract
    result = EthRpcClient.l2.eth_call(
      to: token[:tokenContract],
      data: data,
      block_number: block_tag
    )

    return 0 if result == '0x' || result.nil?

    # Decode the balance
    decoded = Eth::Abi.decode(['uint256'], [result.delete_prefix('0x')].pack('H*'))
    # Convert from 18 decimals to user units (divide by 10^18)
    decoded[0] / (10**18)
  rescue => e
    Rails.logger.error "Failed to get balance for #{address} in token #{tick}: #{e.message}"
    0
  end
end
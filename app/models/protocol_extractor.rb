# Unified protocol extractor that delegates to appropriate extractors
class ProtocolExtractor
  # Default return values to check if extraction succeeded
  TOKEN_DEFAULT_PARAMS = TokenParamsExtractor::DEFAULT_PARAMS
  COLLECTIONS_DEFAULT_PARAMS = CollectionsParamsExtractor::DEFAULT_PARAMS
  GENERIC_DEFAULT_PARAMS = GenericProtocolExtractor::DEFAULT_PARAMS

  def self.extract(content_uri)
    return nil unless content_uri.is_a?(String)

    # Quick check if it starts with data:,
    return nil unless content_uri.start_with?('data:,')

    # Try extractors in order of strictness
    # 1. Token protocol (most strict - exact character position matters)
    # 2. Collections protocol (strict - exact key order required)
    # 3. Generic protocol (flexible - for all other protocols)

    # Try token extractor first (most strict)
    result = try_token_extractor(content_uri)
    return result if result

    # Try collections extractor next
    result = try_collections_extractor(content_uri)
    return result if result

    # Try generic extractor last (most flexible)
    result = try_generic_extractor(content_uri)
    return result if result

    # No protocol could be extracted
    nil
  end

  private

  def self.try_token_extractor(content_uri)
    # TokenParamsExtractor uses strict regex and returns DEFAULT_PARAMS if no match
    params = TokenParamsExtractor.extract(content_uri)

    # Check if extraction succeeded (returns non-default params)
    if params != TOKEN_DEFAULT_PARAMS
      {
        type: :token,
        protocol: 'erc-20',
        operation: params[0], # 'deploy' or 'mint'
        params: params,
        encoded_params: encode_token_params(params)
      }
    else
      nil
    end
  end

  def self.try_collections_extractor(content_uri)
    # CollectionsParamsExtractor returns [''.b, ''.b, ''.b] if no match
    protocol, operation, encoded_data = CollectionsParamsExtractor.extract(content_uri)

    # Check if extraction succeeded
    if protocol != ''.b && operation != ''.b
      {
        type: :collections,
        protocol: protocol,
        operation: operation,
        params: nil, # Collections doesn't return decoded params
        encoded_params: encoded_data
      }
    else
      nil
    end
  end

  def self.try_generic_extractor(content_uri)
    # GenericProtocolExtractor returns [''.b, ''.b, ''.b] if no match
    protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

    # Check if extraction succeeded
    if protocol != ''.b && operation != ''.b
      {
        type: :generic,
        protocol: protocol,
        operation: operation,
        params: nil, # Generic doesn't return decoded params
        encoded_params: encoded_data
      }
    else
      nil
    end
  end

  def self.encode_token_params(params)
    # Convert token params to format expected by contracts
    # params format: [op, protocol, tick, val1, val2, val3]
    op, _protocol, tick, val1, val2, val3 = params

    case op
    when 'deploy'.b
      # For deploy: tick, max, lim
      {
        op: op,
        tick: tick,
        max: val1,
        lim: val2,
        amt: 0
      }
    when 'mint'.b
      # For mint: tick, id, amt
      {
        op: op,
        tick: tick,
        id: val1,
        amt: val3
      }
    else
      nil
    end
  end

  # Get protocol data formatted for L2 calldata
  # Returns [protocol, operation, encoded_data] for contract consumption
  def self.for_calldata(content_uri)
    result = extract(content_uri)

    if result.nil?
      # No protocol detected - return empty protocol params
      [''.b, ''.b, ''.b]
    elsif result[:type] == :token
      # Token protocol - return in new format
      protocol = result[:protocol].b
      operation = result[:operation]
      # For tokens, encode the params properly
      encoded_data = encode_token_data(result[:params])
      [protocol, operation, encoded_data]
    elsif result[:type] == :collections
      # Collections protocol - already has encoded data
      [result[:protocol], result[:operation], result[:encoded_params]]
    else
      # Generic protocol - already has encoded data
      [result[:protocol], result[:operation], result[:encoded_params]]
    end
  end

  # Encode token params as bytes for contract consumption
  def self.encode_token_data(params)
    # params format: [op, protocol, tick, val1, val2, val3]
    op, _protocol, tick, val1, val2, val3 = params

    # Encode based on operation type (operation is passed separately now)
    # Use tuple encoding for struct compatibility with contracts
    # IMPORTANT: Field order must match TokenManager's struct definitions!
    if op == 'deploy'.b
      # DeployOperation struct: tick, maxSupply, mintAmount
      # Our params: tick, max (val1), lim (val2)
      # So: tick, maxSupply=val1, mintAmount=val2
      Eth::Abi.encode(['(string,uint256,uint256)'], [[tick.b, val1, val2]])
    elsif op == 'mint'.b
      # MintOperation struct: tick, id, amount
      # Our params: tick, id (val1), amt (val3)
      # So: tick, id=val1, amount=val3
      Eth::Abi.encode(['(string,uint256,uint256)'], [[tick.b, val1, val3]])
    else
      ''.b
    end
  end
end
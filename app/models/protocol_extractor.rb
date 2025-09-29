# Unified protocol extractor that delegates to appropriate extractors
class ProtocolExtractor
  # Quick regex checks to identify protocol type without full parsing
  # These are optimized for speed and used to determine which extractor to use

  # erc-20 token protocol - must match exact format for backwards compatibility
  # Checks for the specific structure required by TokenParamsExtractor
  TOKEN_PROTOCOL_REGEX = /\A
    data:,\{
      "p":"erc-20",
      "op":"(deploy|mint)",
      "tick":"[a-z0-9]{1,28}",
      (?:
        # Deploy format
        "max":"(?:0|[1-9][0-9]*)",
        "lim":"(?:0|[1-9][0-9]*)"
        |
        # Mint format
        "id":"(?:0|[1-9][0-9]*)",
        "amt":"(?:0|[1-9][0-9]*)"
      )
    \}\z
  /x.freeze

  # Default return values for different scenarios
  TOKEN_DEFAULT_PARAMS = TokenParamsExtractor::DEFAULT_PARAMS
  GENERIC_DEFAULT_PARAMS = GenericProtocolExtractor::DEFAULT_PARAMS

  def self.extract(content_uri)
    return nil unless content_uri.is_a?(String)

    # Quick check if it starts with data:,{
    return nil unless content_uri.start_with?('data:,{')

    # Check if it's a token protocol first (needs exact format)
    if matches_token_protocol?(content_uri)
      extract_token_protocol(content_uri)
    elsif matches_generic_protocol?(content_uri)
      extract_generic_protocol(content_uri)
    else
      # Not a recognized protocol format
      nil
    end
  end

  private

  def self.matches_token_protocol?(content_uri)
    # Quick check for erc-20 protocol signature
    # This is more lenient than the full regex, just checking for key markers
    content_uri.include?('"p":"erc-20"') &&
    (content_uri.include?('"op":"deploy"') || content_uri.include?('"op":"mint"')) &&
    content_uri.include?('"tick":"')
  end

  def self.matches_generic_protocol?(content_uri)
    # Check if it has p and op fields by parsing JSON
    # This supports multi-line JSON and is more reliable than regex
    begin
      json_str = content_uri[6..] # Remove 'data:,'
      data = JSON.parse(json_str, max_nesting: 10)

      # Must be an object with p and op fields
      data.is_a?(Hash) &&
        data.key?('p') && data['p'].is_a?(String) &&
        data.key?('op') && data['op'].is_a?(String)
    rescue JSON::ParserError
      false
    end
  end

  def self.extract_token_protocol(content_uri)
    # Use TokenParamsExtractor for erc-20 tokens
    # This maintains backwards compatibility with exact format requirements
    params = TokenParamsExtractor.extract(content_uri)

    # Check if extraction succeeded
    if params != TOKEN_DEFAULT_PARAMS
      {
        type: :token,
        protocol: 'erc-20',
        operation: params[0], # 'deploy' or 'mint'
        params: params,
        # For L2 bridge, we need the params in the expected format
        encoded_params: encode_token_params(params)
      }
    else
      # Failed token extraction - might be malformed
      # Return nil to indicate this isn't a valid token protocol
      nil
    end
  end

  def self.extract_generic_protocol(content_uri)
    # Use GenericProtocolExtractor for all other protocols
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
      # Failed generic extraction
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
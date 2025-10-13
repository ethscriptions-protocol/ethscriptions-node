# Generic protocol extractor for JSON-based ethscription protocols
# Extracts protocol and operation, then ABI-encodes remaining parameters
class GenericProtocolExtractor
  # Security limits
  MAX_DEPTH = 5           # Maximum JSON nesting depth (increased for nested collection attributes)
  MAX_STRING_LENGTH = 1000 # Maximum length for any string value
  MAX_ARRAY_LENGTH = 100   # Maximum array length
  MAX_OBJECT_KEYS = 20     # Maximum keys in an object
  UINT256_MAX = 2**256 - 1  # Maximum uint256 value

  # Standard protocol fields
  PROTOCOL_FIELD = 'p'
  OPERATION_FIELD = 'op'
  RESERVED_FIELDS = [PROTOCOL_FIELD, OPERATION_FIELD].freeze

  # Default return for invalid input
  DEFAULT_PARAMS = [''.b, ''.b, ''.b].freeze # [protocol, operation, abi_encoded_data]

  class ExtractionError < StandardError; end

  def self.extract(content_uri)
    new.extract(content_uri)
  end

  def extract(content_uri)
    return DEFAULT_PARAMS unless valid_data_uri?(content_uri)
    begin
      # Extract JSON from data URI using DataUri to support optional params (e.g., ESIP6)
      json_str = if content_uri.start_with?("data:,{")
        content_uri.sub(/\Adata:,/, '')
      else
        DataUri.new(content_uri).decoded_data
      end
      # Parse with security checks
      data = parse_json_safely(json_str)

      # Extract protocol and operation
      protocol = data[PROTOCOL_FIELD]
      operation = data[OPERATION_FIELD]

      return DEFAULT_PARAMS unless valid_protocol_fields?(protocol, operation)

      # Remove reserved fields and encode the rest
      params = data.reject { |k, _| RESERVED_FIELDS.include?(k) }

      # ABI encode the parameters
      encoded_data = encode_parameters(params)

      [protocol.b, operation.b, encoded_data.b]

    rescue JSON::ParserError, ExtractionError => e
      Rails.logger.debug "Protocol extraction failed: #{e.message}"
      DEFAULT_PARAMS
    end
  end

  private

  def valid_data_uri?(uri)
    return false unless uri.is_a?(String)
    return false unless DataUri.valid?(uri)

    return true if uri.start_with?("data:,{")
    
    # Ensure the payload is JSON (starts with '{')
    begin
      payload = DataUri.new(uri).decoded_data
      payload.is_a?(String) && payload.start_with?('{')
    rescue StandardError
      false
    end
  end

  def valid_protocol_fields?(protocol, operation)
    protocol.is_a?(String) &&
    operation.is_a?(String) &&
    protocol.length.between?(1, 50) &&
    operation.length.between?(1, 50) &&
    protocol.match?(/\A[a-z0-9\-_]+\z/) &&  # lowercase alphanumeric with dash/underscore
    operation.match?(/\A[a-z0-9\-_]+\z/)     # lowercase alphanumeric with dash/underscore
  end

  def parse_json_safely(json_str)
    # Size check
    raise ExtractionError, "JSON too large" if json_str.bytesize > 10_000

    # Parse (allow one extra level for JSON parsing)
    data = JSON.parse(json_str, max_nesting: MAX_DEPTH + 1)

    # Must be an object at root
    raise ExtractionError, "Root must be object" unless data.is_a?(Hash)

    # Validate structure with depth limit
    validate_structure(data, 0)

    data
  end

  def validate_structure(value, depth)
    raise ExtractionError, "Max depth exceeded" if depth > MAX_DEPTH

    case value
    when Hash
      raise ExtractionError, "Too many object keys" if value.size > MAX_OBJECT_KEYS
      value.each do |k, v|
        raise ExtractionError, "Invalid key type" unless k.is_a?(String)
        raise ExtractionError, "Key too long" if k.length > MAX_STRING_LENGTH
        validate_structure(v, depth + 1)
      end

    when Array
      raise ExtractionError, "Array too long" if value.size > MAX_ARRAY_LENGTH
      value.each { |v| validate_structure(v, depth + 1) }

    when String
      raise ExtractionError, "String too long" if value.length > MAX_STRING_LENGTH

    when Integer
      # Check uint256 bounds
      raise ExtractionError, "Number out of bounds" if value < 0 || value > UINT256_MAX

    when Float
      # Convert to integer if whole number, otherwise reject
      if value == value.to_i
        validate_structure(value.to_i, depth)
      else
        raise ExtractionError, "Decimal numbers not supported"
      end

    when TrueClass, FalseClass
      # Booleans allowed

    when NilClass
      # Nulls not allowed
      raise ExtractionError, "Null values not supported"

    else
      raise ExtractionError, "Unsupported type: #{value.class}"
    end
  end

  def encode_parameters(params)
    return ''.b if params.empty?

    # Build dynamic ABI encoding based on inferred types
    types = []
    values = []

    # Preserve key order (don't sort) - users must match contract struct order
    params.each do |key, value|
      type, encoded_value = infer_type_and_value(value, 0, key)
      types << type
      values << encoded_value
    end

    # Ensure all string values have consistent encoding
    encoded_values = values.map do |v|
      encode_value_for_abi(v)
    end

    # Create the tuple type string
    tuple_type = "(#{types.join(',')})"

    Eth::Abi.encode([tuple_type], [encoded_values])
  rescue StandardError => e
    Rails.logger.error "ABI encoding failed: #{e.message}"
    Rails.logger.error "Types: #{types.inspect}"
    Rails.logger.error "Values: #{values.inspect}"
    raise ExtractionError, "Failed to encode parameters"
  end

  def infer_type_and_value(value, depth = 0, key = nil)
    raise ExtractionError, "Max nesting depth exceeded" if depth > MAX_DEPTH

    # Check if this is a type hint array: ["type", value]
    if value.is_a?(Array) && value.length == 2 && value[0].is_a?(String) && looks_like_type_hint?(value[0])
      return handle_type_hint(value[0], value[1], depth)
    end

    case value
    when Integer
      ['uint256', value]

    when String
      infer_string_type(value)

    when TrueClass, FalseClass
      ['bool', value]

    when NilClass
      raise ExtractionError, "Null values not supported"

    when Array
      # Handle arrays recursively
      if value.empty?
        # Special case for attributes field - empty array should be Attribute[] type
        if key == 'attributes'
          return ['(string,string)[]', []]
        end
        # Default to uint256[] for other empty arrays
        return ['uint256[]', []]
      end

      # Check if this is an array of objects (potential tuple array)
      if value.all? { |item| item.is_a?(Hash) }
        infer_tuple_array_type(value, depth + 1)
      elsif value.all? { |item| item.is_a?(Array) }
        # Could be array of tuples represented as arrays (for items)
        # or simple 2D array (for attributes)
        infer_array_based_type(value, depth + 1)
      else
        # Regular array - all elements must be same type
        first_type, first_value = infer_type_and_value(value.first, depth + 1)

        # Validate and encode all elements
        encoded_array = value.map do |item|
          item_type, item_value = infer_type_and_value(item, depth + 1)
          if item_type != first_type
            raise ExtractionError, "Mixed types in array: expected #{first_type}, got #{item_type}"
          end
          item_value
        end

        # Add [] to the type to indicate it's an array
        ["#{first_type}[]", encoded_array]
      end

    when Hash
      raise ExtractionError, "Nested objects not supported"

    else
      raise ExtractionError, "Cannot infer type for #{value.class}"
    end
  end

  def infer_array_based_type(value, depth)
    # Determine if this is:
    # 1. A simple 2D array (all elements same type) like [["a","b"],["c","d"]]
    # 2. An array of tuples (mixed types per position) like [[0,"name","0x..."],[1,"name2","0x..."]]

    # First check consistency of inner array lengths
    first_length = value.first.length
    unless value.all? { |item| item.is_a?(Array) && item.length == first_length }
      raise ExtractionError, "Inconsistent inner array sizes"
    end

    # Analyze types at each position across all arrays
    position_types = Array.new(first_length) { [] }

    value.each do |inner_array|
      inner_array.each_with_index do |elem, i|
        type, _ = infer_type_and_value(elem, depth + 1)
        position_types[i] << type
      end
    end

    # Check if each position has consistent types
    is_uniform = position_types.all? { |types| types.uniq.length == 1 }

    if is_uniform
      # Get the single type for each position
      tuple_types = position_types.map { |types| types.first }

      # Check if ALL positions have the same type (simple 2D array)
      if tuple_types.uniq.length == 1
        # Simple 2D array - all elements are the same type
        base_type = tuple_types.first

        # Encode the values
        encoded_array = value.map do |inner|
          inner.map do |elem|
            _, elem_value = infer_type_and_value(elem, depth + 1)
            elem_value
          end
        end

        ["#{base_type}[][]", encoded_array]
      else
        # Array of tuples - each position has its own type
        # Encode as tuple array
        encoded_array = value.map do |inner|
          inner.map.with_index do |elem, i|
            _, elem_value = infer_type_and_value(elem, depth + 1)
            elem_value
          end
        end

        # Return as tuple array: (type1,type2,...)[]
        tuple_type_str = "(#{tuple_types.join(',')})"
        ["#{tuple_type_str}[]", encoded_array]
      end
    else
      raise ExtractionError, "Inconsistent types within array positions"
    end
  end


  def infer_tuple_array_type(objects, depth)
    # Check if this is standard NFT attributes format
    if is_nft_attributes_array?(objects)
      return convert_nft_attributes_to_tuples(objects)
    end

    # All objects must have the same keys in the same order
    first_keys = objects.first.keys
    unless objects.all? { |obj| obj.keys == first_keys }
      raise ExtractionError, "Inconsistent object keys or key order in array"
    end

    # Build tuple type definition from first object
    tuple_types = []
    tuple_values = []

    objects.map do |obj|
      single_tuple_values = []
      first_keys.each_with_index do |key, i|
        type, value = infer_type_and_value(obj[key], depth + 1)

        # Store type from first object
        if tuple_types.length <= i
          tuple_types << type
        elsif tuple_types[i] != type
          raise ExtractionError, "Type mismatch for key '#{key}': expected #{tuple_types[i]}, got #{type}"
        end

        single_tuple_values << value
      end
      tuple_values << single_tuple_values
    end

    # Return as tuple array type
    # Format: "(type1,type2,type3)[]" for ABI encoding
    tuple_type_str = "(#{tuple_types.join(',')})"
    ["#{tuple_type_str}[]", tuple_values]
  end

  # Check if array contains standard NFT attribute objects
  def is_nft_attributes_array?(objects)
    return false if objects.empty?

    # Check if all objects have exactly "trait_type" and "value" keys
    # (or the snake_case versions)
    objects.all? do |obj|
      keys = obj.keys.map(&:to_s).sort
      keys == ['trait_type', 'value'].sort ||
      keys == ['traitType', 'value'].sort
    end
  end

  # Convert NFT attributes to Attribute struct tuples
  def convert_nft_attributes_to_tuples(objects)
    tuple_values = objects.map do |obj|
      # Handle both camelCase and snake_case
      trait_type = obj['trait_type'] || obj['traitType'] || ''
      value = obj['value'] || ''

      # Both fields are strings in the Attribute struct
      [trait_type.to_s, value.to_s]
    end

    # Return as array of (string,string) tuples for Attribute struct
    ['(string,string)[]', tuple_values]
  end

  def encode_value_for_abi(value)
    case value
    when String
      # Eth::Abi expects binary encoding - just call .b on everything
      value.b
    when Array
      # Recursively handle arrays that might contain strings
      value.map { |item| encode_value_for_abi(item) }
    when Hash
      # Recursively handle hashes that might contain strings
      value.transform_values { |v| encode_value_for_abi(v) }
    else
      value
    end
  end

  def infer_string_type(value)
    # Check if it's a pure numeric string (for compatibility with JS clients)
    # This allows JS to pass large numbers as strings
    # But reject numbers with leading zeros (like "01", "001") as these are often IDs
    if value.match?(/\A[1-9]\d*\z/) || value == "0"
      begin
        num = value.to_i
        if num >= 0 && num <= UINT256_MAX
          return ['uint256', num]
        else
          # Number is too large for uint256 - this is likely an error
          raise ExtractionError, "Number exceeds uint256 maximum"
        end
      rescue StandardError => e
        # Re-raise our extraction error, but fall through for other errors
        raise if e.is_a?(ExtractionError)
        # Fall through to string if conversion fails for other reasons
      end
    end

    # Hex strings (addresses, bytes32, etc)
    if value.start_with?('0x')
      process_hex_string(value)
    else
      # All other strings stay as strings
      # Including "true"/"false" - use JSON booleans for actual booleans
      ['string', value]
    end
  end

  def process_hex_string(value)
    hex_part = value[2..]

    # Validation
    raise ExtractionError, "Empty hex string" if hex_part.empty?
    raise ExtractionError, "Invalid hex: odd length" if hex_part.length % 2 != 0

    # If contains non-hex chars, treat as regular string
    return ['string', value] unless hex_part.match?(/\A[0-9a-fA-F]+\z/)

    byte_length = hex_part.length / 2
    raise ExtractionError, "Hex string too long (max 32 bytes)" if byte_length > 32

    hex_data = hex_part.downcase

    case byte_length
    when 20
      # Address
      ["address", "0x" + hex_data]
    when 32
      # bytes32 (hashes, IDs)
      ["bytes32", [hex_data].pack('H*')]
    else
      # Other fixed-length bytes - now supported!
      ["bytes#{byte_length}", [hex_data].pack('H*')]
    end
  end



  # Type hint support methods
  def looks_like_type_hint?(str)
    # Use eth.rb's parser to validate - if it parses, it's a valid type hint
    begin
      Eth::Abi::Type.parse(str)
      true
    rescue Eth::Abi::Type::ParseError
      false
    end
  end

  def handle_type_hint(type_hint, value, depth)
    # Parse the type using eth.rb's robust parser
    type = Eth::Abi::Type.parse(type_hint)

    # Route to appropriate handler based on parsed type
    if type.dimensions.any?
      # It's an array type
      handle_array_type(type, type_hint, value)
    elsif type.base_type == 'tuple'
      # It's a tuple type (but not implemented yet for non-arrays)
      raise ExtractionError, "Standalone tuples not yet supported"
    else
      # It's a base type (but not implemented yet)
      raise ExtractionError, "Base type hints not yet supported"
    end
  rescue Eth::Abi::Type::ParseError => e
    raise ExtractionError, "Invalid type hint: #{e.message}"
  end

  def handle_array_type(type, type_str, value)
    unless value.is_a?(Array)
      raise ExtractionError, "Expected array for #{type_str}"
    end

    # Special handling for known types
    if type.base_type == 'tuple' && type.components&.length == 2 &&
       type.components.all? { |c| c.base_type == 'string' }
      # This is (string,string)[] - our Attribute array
      handle_attribute_array_hint(value)
    elsif type.base_type == 'uint' && type.sub_type == '256'
      # uint256[]
      handle_uint_array_hint(value)
    elsif type.base_type == 'string'
      # string[]
      handle_string_array_hint(value)
    elsif type.base_type == 'address'
      # address[]
      handle_address_array_hint(value)
    else
      raise ExtractionError, "Unsupported array type: #{type_str}"
    end
  end

  def handle_uint_array_hint(value)
    unless value.is_a?(Array)
      raise ExtractionError, "Expected array for uint256[]"
    end

    encoded = value.map do |v|
      unless v.is_a?(Integer) || (v.is_a?(String) && v.match?(/^\d+$/))
        raise ExtractionError, "Invalid uint256 value: #{v}"
      end
      v.is_a?(String) ? v.to_i : v
    end

    ['uint256[]', encoded]
  end

  def handle_string_array_hint(value)
    unless value.is_a?(Array)
      raise ExtractionError, "Expected array for string[]"
    end

    ['string[]', value.map(&:to_s)]
  end

  def handle_attribute_array_hint(value)
    unless value.is_a?(Array)
      raise ExtractionError, "Expected array for (string,string)[]"
    end

    # Empty array case - this is what we wanted to support!
    return ['(string,string)[]', []] if value.empty?

    # Process non-empty attributes
    encoded = value.map do |item|
      if item.is_a?(Hash)
        # Standard format: {"trait_type": "x", "value": "y"}
        trait = item['trait_type'] || item['traitType'] || ''
        val = item['value'] || ''
        [trait.to_s, val.to_s]
      elsif item.is_a?(Array) && item.length == 2
        # Array format: ["trait", "value"]
        [item[0].to_s, item[1].to_s]
      else
        raise ExtractionError, "Invalid attribute format"
      end
    end

    ['(string,string)[]', encoded]
  end

  def handle_address_array_hint(value)
    unless value.is_a?(Array)
      raise ExtractionError, "Expected array for address[]"
    end

    encoded = value.map do |v|
      unless v.is_a?(String) && v.match?(/^0x[0-9a-fA-F]{40}$/i)
        raise ExtractionError, "Invalid address: #{v}"
      end
      v.downcase  # Just lowercase, keep full format with 0x
    end

    ['address[]', encoded]
  end

  def handle_bytes_hint(type_hint, value)
    unless value.is_a?(String) && value.start_with?('0x')
      raise ExtractionError, "Invalid bytes format for #{type_hint}"
    end

    hex_part = value[2..]
    byte_length = type_hint[5..].to_i  # Extract number from "bytes32"

    expected_hex_length = byte_length * 2
    unless hex_part.length == expected_hex_length
      raise ExtractionError, "Wrong length for #{type_hint}: expected #{expected_hex_length} hex chars"
    end

    [type_hint, [hex_part.downcase].pack('H*')]
  end

  # Helper method for legacy token protocol (maintains compatibility)
  def self.extract_token_params(content_uri)
    # Use the strict regex-based extractor for token protocol
    TokenParamsExtractor.extract(content_uri)
  end
end

# Generic protocol extractor for JSON-based ethscription protocols
# Extracts protocol and operation, then ABI-encodes remaining parameters
class GenericProtocolExtractor
  # Security limits
  MAX_DEPTH = 3           # Maximum JSON nesting depth
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
      # Extract JSON from data URI
      json_str = content_uri[6..] # Remove 'data:,'

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
    uri.is_a?(String) && uri.start_with?('data:,{')
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

    # Parse
    data = JSON.parse(json_str, max_nesting: MAX_DEPTH)

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

    # Sort keys for deterministic encoding
    params.keys.sort.each do |key|
      value = params[key]
      type, encoded_value = infer_type_and_value(value)
      types << type
      values << encoded_value
    end

    # ABI encode all parameters as a tuple
    Eth::Abi.encode(types, values)
  rescue StandardError => e
    Rails.logger.error "ABI encoding failed: #{e.message}"
    raise ExtractionError, "Failed to encode parameters"
  end

  def infer_type_and_value(value)
    case value
    when Integer
      ['uint256', value]

    when String
      # Check if it's a boolean string
      if value == 'true'
        ['bool', true]
      elsif value == 'false'
        ['bool', false]
      # Check if it starts with 0x - could be hex string
      elsif value.start_with?('0x')
        hex_part = value[2..]

        # Check for invalid hex patterns that should be rejected
        if hex_part.empty?
          # "0x" with nothing after
          raise ExtractionError, "Empty hex string"
        elsif hex_part.length % 2 != 0
          # Odd number of hex characters
          raise ExtractionError, "Invalid hex string: odd number of characters"
        elsif !hex_part.match?(/\A[0-9a-fA-F]+\z/)
          # Contains non-hex characters - treat as regular string
          ['string', value]
        else
          # Valid hex string
          byte_length = hex_part.length / 2

          if byte_length > 32
            # Too long for fixed bytes type
            raise ExtractionError, "Hex string too long for bytes32"
          end

          # Normalize to lowercase
          hex_data = hex_part.downcase

          # Common lengths we handle specially
          case byte_length
          when 20
            # Address (bytes20) - keep as hex string, Eth::Abi will handle conversion
            ["address", "0x" + hex_data]
          when 32
            # Common for hashes, IDs (bytes32) - convert to binary for encoding
            # Eth::Abi expects bytes32 as a binary string, not hex
            ["bytes32", [hex_data].pack('H*')]
          else
            # Other fixed-length bytes (bytes1-bytes31) - convert to binary
            # ["bytes#{byte_length}", [hex_data].pack('H*')]
            # TODO: Fix this
            raise ExtractionError, "Not supported"
          end
        end
      # Check if it's a valid number string (like token extractor pattern)
      elsif value.match?(/\A(0|[1-9][0-9]*)\z/)
        # Valid positive integer string - convert to uint256
        num = value.to_i
        if num <= UINT256_MAX
          ['uint256', num]
        else
          raise ExtractionError, "Number too large for uint256"
        end
      else
        # Regular string
        ['string', value]
      end

    when TrueClass, FalseClass
      ['bool', value]

    when NilClass
      # Reject null values
      raise ExtractionError, "Null values not supported"

    when Array
      if value.empty?
        # Empty array defaults to uint256[]
        ['uint256[]', []]
      else
        # Infer from first element
        first_type, first_value = infer_type_and_value(value.first)
        base_type = first_type.sub('[]', '')

        # For address and bytes types, we need to ensure consistent handling
        # since they return the hex string with 0x prefix
        is_bytes_type = base_type.start_with?('bytes') || base_type == 'address'

        # Ensure all elements match the type
        encoded_array = value.map do |item|
          item_type, item_value = infer_type_and_value(item)
          if item_type.sub('[]', '') != base_type
            raise ExtractionError, "Mixed types in array"
          end
          item_value
        end

        ["#{base_type}[]", encoded_array]
      end

    when Hash
      # Reject nested objects - use basic types and arrays only
      raise ExtractionError, "Nested objects not supported"

    else
      raise ExtractionError, "Cannot infer type for #{value.class}"
    end
  end

  # Helper method for legacy token protocol (maintains compatibility)
  def self.extract_token_params(content_uri)
    # Use the strict regex-based extractor for token protocol
    TokenParamsExtractor.extract(content_uri)
  end
end
# Strict extractor for Collections protocol with canonical JSON validation
class CollectionsParamsExtractor
  # Default return for invalid input
  DEFAULT_PARAMS = [''.b, ''.b, ''.b].freeze

  # Maximum value for uint256
  UINT256_MAX = 2**256 - 1

  # Operation schemas defining exact structure and ABI encoding
  OPERATION_SCHEMAS = {
    'create_collection' => {
      keys: %w[name symbol total_supply description logo_image_uri banner_image_uri background_color website_link twitter_link discord_link],
      abi_type: '(string,string,uint256,string,string,string,string,string,string,string)',
      validators: {
        'name' => :string,
        'symbol' => :string,
        'total_supply' => :uint256,
        'description' => :string,
        'logo_image_uri' => :string,
        'banner_image_uri' => :string,
        'background_color' => :string,
        'website_link' => :string,
        'twitter_link' => :string,
        'discord_link' => :string
      }
    },
    'add_items_batch' => {
      keys: %w[collection_id items],
      abi_type: '(bytes32,(uint256,string,bytes32,string,string,(string,string)[])[])',
      validators: {
        'collection_id' => :bytes32,
        'items' => :items_array
      }
    },
    'remove_items' => {
      keys: %w[collection_id ethscription_ids],
      abi_type: '(bytes32,bytes32[])',
      validators: {
        'collection_id' => :bytes32,
        'ethscription_ids' => :bytes32_array
      }
    },
    'edit_collection' => {
      keys: %w[collection_id description logo_image_uri banner_image_uri background_color website_link twitter_link discord_link],
      abi_type: '(bytes32,string,string,string,string,string,string,string)',
      validators: {
        'collection_id' => :bytes32,
        'description' => :string,
        'logo_image_uri' => :string,
        'banner_image_uri' => :string,
        'background_color' => :string,
        'website_link' => :string,
        'twitter_link' => :string,
        'discord_link' => :string
      }
    },
    'edit_collection_item' => {
      keys: %w[collection_id item_index name background_color description attributes],
      abi_type: '(bytes32,uint256,string,string,string,(string,string)[])',
      validators: {
        'collection_id' => :bytes32,
        'item_index' => :uint256,
        'name' => :string,
        'background_color' => :string,
        'description' => :string,
        'attributes' => :attributes_array
      }
    },
    'lock_collection' => {
      keys: %w[collection_id],
      abi_type: 'bytes32', # Not a tuple
      validators: {
        'collection_id' => :bytes32
      }
    },
    'sync_ownership' => {
      keys: %w[collection_id ethscription_ids],
      abi_type: '(bytes32,bytes32[])',
      validators: {
        'collection_id' => :bytes32,
        'ethscription_ids' => :bytes32_array
      }
    }
  }.freeze

  # Item keys for add_items_batch validation
  ITEM_KEYS = %w[item_index name ethscription_id background_color description attributes].freeze

  # Attribute keys for NFT metadata
  ATTRIBUTE_KEYS = %w[trait_type value].freeze

  class ValidationError < StandardError; end

  def self.extract(content_uri)
    new.extract(content_uri)
  end

  def extract(content_uri)
    return DEFAULT_PARAMS unless valid_data_uri?(content_uri)

    begin
      # Parse JSON (preserves key order)
      # Use DataUri to correctly handle optional parameters like ESIP6
      json_str = if content_uri.start_with?("data:,{")
        content_uri.sub(/\Adata:,/, '')
      else
        DataUri.new(content_uri).decoded_data
      end
      
      # TODO: make sure this is safe
      data = JSON.parse(json_str)

      # Must be an object
      return DEFAULT_PARAMS unless data.is_a?(Hash)

      # Check protocol
      return DEFAULT_PARAMS unless data['p'] == 'collections'

      # Get operation
      operation = data['op']
      return DEFAULT_PARAMS unless OPERATION_SCHEMAS.key?(operation)

      # Validate exact key order (including p and op at start)
      schema = OPERATION_SCHEMAS[operation]
      expected_keys = ['p', 'op'] + schema[:keys]
      return DEFAULT_PARAMS unless data.keys == expected_keys

      # Remove protocol fields for encoding
      encoding_data = data.reject { |k, _| k == 'p' || k == 'op' }

      # Validate field types and encode
      encoded_data = encode_operation(operation, encoding_data, schema)

      ['collections'.b, operation.b, encoded_data.b]

    rescue JSON::ParserError, ValidationError => e
      Rails.logger.debug "Collections extraction failed: #{e.message}" if defined?(Rails)
      DEFAULT_PARAMS
    end
  end

  private

  def valid_data_uri?(uri)
    DataUri.valid?(uri)
  end

  def encode_operation(operation, data, schema)
    # Validate and transform fields according to schema
    validated_data = validate_fields(data, schema[:validators])

    # Build values array based on operation
    values = case operation
    when 'create_collection'
      build_create_collection_values(validated_data)
    when 'add_items_batch'
      build_add_items_batch_values(validated_data)
    when 'remove_items'
      build_remove_items_values(validated_data)
    when 'edit_collection'
      build_edit_collection_values(validated_data)
    when 'edit_collection_item'
      build_edit_collection_item_values(validated_data)
    when 'lock_collection'
      build_lock_collection_values(validated_data)
    when 'sync_ownership'
      build_sync_ownership_values(validated_data)
    else
      raise ValidationError, "Unknown operation: #{operation}"
    end

    # Use ABI type from schema for encoding
    Eth::Abi.encode([schema[:abi_type]], [values])
  end

  def validate_fields(data, validators)
    validated = {}

    data.each do |key, value|
      validator = validators[key]

      # All fields must have explicit validators - no silent coercion
      unless validator
        raise ValidationError, "No validator defined for field: #{key}"
      end

      validated[key] = send("validate_#{validator}", value, key)
    end

    validated
  end

  # Validators

  def validate_string(value, field_name)
    unless value.is_a?(String)
      raise ValidationError, "Field #{field_name} must be a string, got #{value.class.name}"
    end
    value
  end

  def validate_uint256(value, field_name)
    unless value.is_a?(String) && value.match?(/\A(0|[1-9]\d*)\z/)
      raise ValidationError, "Invalid uint256 for #{field_name}: #{value}"
    end

    num = value.to_i
    if num > UINT256_MAX
      raise ValidationError, "Value exceeds uint256 maximum for #{field_name}: #{value}"
    end

    num
  end

  def validate_bytes32(value, field_name)
    unless value.is_a?(String) && value.match?(/\A0x[0-9a-f]{64}\z/)
      raise ValidationError, "Invalid bytes32 for #{field_name}: #{value}"
    end
    # Return as packed bytes for ABI encoding
    [value[2..]].pack('H*')
  end

  def validate_bytes32_array(value, field_name)
    unless value.is_a?(Array)
      raise ValidationError, "Expected array for #{field_name}"
    end

    value.map do |item|
      unless item.is_a?(String) && item.match?(/\A0x[0-9a-f]{64}\z/)
        raise ValidationError, "Invalid bytes32 in array: #{item}"
      end
      [item[2..]].pack('H*')
    end
  end

  def validate_items_array(value, field_name)
    unless value.is_a?(Array)
      raise ValidationError, "Expected array for #{field_name}"
    end

    value.map do |item|
      validate_item(item)
    end
  end

  def validate_item(item)
    unless item.is_a?(Hash)
      raise ValidationError, "Item must be an object"
    end

    # Check exact key order
    unless item.keys == ITEM_KEYS
      raise ValidationError, "Invalid item keys or order. Expected: #{ITEM_KEYS.join(',')}, got: #{item.keys.join(',')}"
    end

    # Validate each field - return in internal format for encoding
    {
      itemIndex: validate_uint256(item['item_index'], 'item_index'),
      name: validate_string(item['name'], 'name'),
      ethscriptionId: validate_bytes32(item['ethscription_id'], 'ethscription_id'),
      backgroundColor: validate_string(item['background_color'], 'background_color'),
      description: validate_string(item['description'], 'description'),
      attributes: validate_attributes_array(item['attributes'], 'attributes')
    }
  end

  def validate_attributes_array(value, field_name)
    unless value.is_a?(Array)
      raise ValidationError, "Expected array for #{field_name}"
    end

    value.map do |attr|
      validate_attribute(attr)
    end
  end

  def validate_attribute(attr)
    unless attr.is_a?(Hash)
      raise ValidationError, "Attribute must be an object"
    end

    # Check exact key order
    unless attr.keys == ATTRIBUTE_KEYS
      raise ValidationError, "Invalid attribute keys or order. Expected: #{ATTRIBUTE_KEYS.join(',')}, got: #{attr.keys.join(',')}"
    end

    # Both must be strings - no coercion
    [
      validate_string(attr['trait_type'], 'trait_type'),
      validate_string(attr['value'], 'value')
    ]
  end

  # Encoders

  def build_create_collection_values(data)
    [
      data['name'],
      data['symbol'],
      data['total_supply'],
      data['description'],
      data['logo_image_uri'],
      data['banner_image_uri'],
      data['background_color'],
      data['website_link'],
      data['twitter_link'],
      data['discord_link']
    ]
  end

  def build_add_items_batch_values(data)
    # Transform items to array format for encoding
    items_array = data['items'].map do |item|
      [
        item[:itemIndex],
        item[:name],
        item[:ethscriptionId],
        item[:backgroundColor],
        item[:description],
        item[:attributes]
      ]
    end

    [data['collection_id'], items_array]
  end

  def build_remove_items_values(data)
    [data['collection_id'], data['ethscription_ids']]
  end

  def build_edit_collection_values(data)
    [
      data['collection_id'],
      data['description'],
      data['logo_image_uri'],
      data['banner_image_uri'],
      data['background_color'],
      data['website_link'],
      data['twitter_link'],
      data['discord_link']
    ]
  end

  def build_edit_collection_item_values(data)
    [
      data['collection_id'],
      data['item_index'],
      data['name'],
      data['background_color'],
      data['description'],
      data['attributes']
    ]
  end

  def build_lock_collection_values(data)
    # Single bytes32, not a tuple - but we need to return just the value
    data['collection_id']
  end

  def build_sync_ownership_values(data)
    [data['collection_id'], data['ethscription_ids']]
  end
end

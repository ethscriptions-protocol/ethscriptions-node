require 'rails_helper'

# Test GenericProtocolExtractor type inference through ProtocolExtractor
# This ensures type inference works properly when accessed via the unified interface
RSpec.describe 'GenericProtocolExtractor Type Inference via ProtocolExtractor' do

  # Helper to test type inference through ProtocolExtractor
  def test_protocol_inference(field_name, value, expected_type)
    json = if value.is_a?(String) && !value.start_with?('"')
      "\"#{field_name}\":\"#{value}\""
    else
      "\"#{field_name}\":#{value.to_json}"
    end

    content_uri = "data:,{\"p\":\"test\",\"op\":\"infer\",#{json}}"
    result = ProtocolExtractor.extract(content_uri)

    return [nil, nil] if result.nil?

    # For generic protocols, decode the encoded data
    if result[:type] == :generic
      encoded_data = result[:encoded_params]
      # Decode with the expected type to verify inference
      decoded = Eth::Abi.decode([expected_type], encoded_data)
      [expected_type, decoded[0]]
    else
      [nil, nil]
    end
  end

  describe 'Boolean inference' do
    it 'infers "true" string as bool' do
      type, value = test_protocol_inference('flag', 'true', 'bool')
      expect(type).to eq('bool')
      expect(value).to eq(true)
    end

    it 'infers "false" string as bool' do
      type, value = test_protocol_inference('flag', 'false', 'bool')
      expect(type).to eq('bool')
      expect(value).to eq(false)
    end

    it 'infers native true as bool' do
      type, value = test_protocol_inference('flag', true, 'bool')
      expect(type).to eq('bool')
      expect(value).to eq(true)
    end

    it 'infers native false as bool' do
      type, value = test_protocol_inference('flag', false, 'bool')
      expect(type).to eq('bool')
      expect(value).to eq(false)
    end
  end

  describe 'Number inference' do
    it 'infers integer as uint256' do
      type, value = test_protocol_inference('num', 123, 'uint256')
      expect(type).to eq('uint256')
      expect(value).to eq(123)
    end

    it 'infers "0" string as uint256' do
      type, value = test_protocol_inference('num', '0', 'uint256')
      expect(type).to eq('uint256')
      expect(value).to eq(0)
    end

    it 'infers "123" string as uint256' do
      type, value = test_protocol_inference('num', '123', 'uint256')
      expect(type).to eq('uint256')
      expect(value).to eq(123)
    end

    it 'treats "01" as string (leading zero)' do
      type, value = test_protocol_inference('num', '01', 'string')
      expect(type).to eq('string')
      expect(value).to eq('01')
    end

    it 'treats "-1" as string (negative)' do
      type, value = test_protocol_inference('num', '-1', 'string')
      expect(type).to eq('string')
      expect(value).to eq('-1')
    end
  end

  describe 'Bytes type inference' do
    it 'infers 20-byte hex as address' do
      addr = '0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb1'
      type, value = test_protocol_inference('addr', addr, 'address')
      expect(type).to eq('address')
      expect(value.downcase).to eq(addr.downcase)
    end

    it 'infers 32-byte hex as bytes32' do
      hash = '0x' + 'a' * 64
      type, value = test_protocol_inference('hash', hash, 'bytes32')
      expect(type).to eq('bytes32')
      expect('0x' + value.unpack1('H*')).to eq(hash)
    end

    it 'infers 4-byte hex as bytes4' do
      byte4 = '0x12345678'
      type, value = test_protocol_inference('b', byte4, 'bytes4')
      expect(type).to eq('bytes4')
      expect('0x' + value.unpack1('H*')).to eq(byte4)
    end

    it 'treats invalid hex as string' do
      type, value = test_protocol_inference('text', '0xGGGG', 'string')
      expect(type).to eq('string')
      expect(value).to eq('0xGGGG')
    end
  end

  describe 'String inference' do
    it 'infers regular text as string' do
      type, value = test_protocol_inference('text', 'hello world', 'string')
      expect(type).to eq('string')
      expect(value).to eq('hello world')
    end

    it 'infers URL as string' do
      type, value = test_protocol_inference('url', 'https://example.com', 'string')
      expect(type).to eq('string')
      expect(value).to eq('https://example.com')
    end
  end

  describe 'Array inference' do
    it 'infers array of numbers as uint256[]' do
      json = '"nums":["1","2","3"]'
      content_uri = "data:,{\"p\":\"test\",\"op\":\"infer\",#{json}}"
      result = ProtocolExtractor.extract(content_uri)

      expect(result).not_to be_nil
      expect(result[:type]).to eq(:generic)

      decoded = Eth::Abi.decode(['uint256[]'], result[:encoded_params])
      expect(decoded[0]).to eq([1, 2, 3])
    end

    it 'infers array of addresses as address[]' do
      addrs = [
        '0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb1',
        '0x5aAeb6053f3E94C9b9A09f33669435E7Ef1BeAed'
      ]
      json = "\"addrs\":#{addrs.to_json}"
      content_uri = "data:,{\"p\":\"test\",\"op\":\"infer\",#{json}}"
      result = ProtocolExtractor.extract(content_uri)

      expect(result).not_to be_nil
      expect(result[:type]).to eq(:generic)

      decoded = Eth::Abi.decode(['address[]'], result[:encoded_params])
      expect(decoded[0].map(&:downcase)).to eq(addrs.map(&:downcase))
    end

    it 'infers array of bools as bool[]' do
      json = '"flags":["true","false","true"]'
      content_uri = "data:,{\"p\":\"test\",\"op\":\"infer\",#{json}}"
      result = ProtocolExtractor.extract(content_uri)

      expect(result).not_to be_nil
      expect(result[:type]).to eq(:generic)

      decoded = Eth::Abi.decode(['bool[]'], result[:encoded_params])
      expect(decoded[0]).to eq([true, false, true])
    end
  end

  describe 'Mixed field types' do
    it 'correctly infers multiple field types' do
      json = '{
        "p": "test",
        "op": "mixed",
        "amount": "1000",
        "recipient": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb1",
        "enabled": "true",
        "name": "Test Token"
      }'

      content_uri = "data:,#{json}"
      result = ProtocolExtractor.extract(content_uri)

      expect(result).not_to be_nil
      expect(result[:type]).to eq(:generic)

      # Fields are sorted alphabetically: amount, enabled, name, recipient
      types = ['uint256', 'bool', 'string', 'address']
      decoded = Eth::Abi.decode(types, result[:encoded_params])

      expect(decoded[0]).to eq(1000)         # amount
      expect(decoded[1]).to eq(true)         # enabled
      expect(decoded[2]).to eq('Test Token') # name
      expect(decoded[3]).to be_a(String)     # recipient address
    end
  end

  describe 'Protocol rejection cases' do
    it 'returns nil for null values' do
      content_uri = 'data:,{"p":"test","op":"action","value":null}'
      result = ProtocolExtractor.extract(content_uri)
      expect(result).to be_nil
    end

    it 'returns nil for nested objects' do
      content_uri = 'data:,{"p":"test","op":"action","value":{"nested":"object"}}'
      result = ProtocolExtractor.extract(content_uri)
      expect(result).to be_nil
    end

    it 'returns nil for mixed-type arrays' do
      content_uri = 'data:,{"p":"test","op":"action","mixed":[1,"string",true]}'
      result = ProtocolExtractor.extract(content_uri)
      expect(result).to be_nil
    end

    it 'returns nil for invalid hex strings' do
      content_uri = 'data:,{"p":"test","op":"action","bad":"0x123"}' # Odd length
      result = ProtocolExtractor.extract(content_uri)
      expect(result).to be_nil
    end

    it 'returns nil for hex strings too long' do
      content_uri = 'data:,{"p":"test","op":"action","bad":"0x' + '0' * 66 + '"}'
      result = ProtocolExtractor.extract(content_uri)
      expect(result).to be_nil
    end

    it 'returns nil for empty hex strings' do
      content_uri = 'data:,{"p":"test","op":"action","bad":"0x"}'
      result = ProtocolExtractor.extract(content_uri)
      expect(result).to be_nil
    end

    it 'returns nil for decimal numbers' do
      content_uri = 'data:,{"p":"test","op":"action","value":123.456}'
      result = ProtocolExtractor.extract(content_uri)
      expect(result).to be_nil
    end

    it 'returns nil for negative numbers' do
      content_uri = 'data:,{"p":"test","op":"action","value":-100}'
      result = ProtocolExtractor.extract(content_uri)
      expect(result).to be_nil
    end
  end

  describe 'Real protocol examples' do
    it 'handles collections protocol with proper type inference' do
      content_uri = 'data:,{"p":"collections","op":"create_collection","name":"My NFTs","symbol":"MNFT","maxSupply":"10000","baseUri":"https://api.example.com/"}'
      result = ProtocolExtractor.extract(content_uri)

      expect(result).not_to be_nil
      expect(result[:type]).to eq(:generic)
      expect(result[:protocol]).to eq('collections'.b)
      expect(result[:operation]).to eq('create_collection'.b)

      # Verify the types were inferred correctly
      types = ['string', 'uint256', 'string', 'string']
      decoded = Eth::Abi.decode(types, result[:encoded_params])

      expect(decoded[0]).to eq('https://api.example.com/') # baseUri (alphabetically first)
      expect(decoded[1]).to eq(10000)                       # maxSupply
      expect(decoded[2]).to eq('My NFTs')                   # name
      expect(decoded[3]).to eq('MNFT')                      # symbol
    end

    it 'handles governance protocol with mixed types' do
      content_uri = 'data:,{"p":"governance","op":"create_proposal","title":"Upgrade","votingPeriod":"86400","quorum":"100","active":"true"}'
      result = ProtocolExtractor.extract(content_uri)

      expect(result).not_to be_nil
      expect(result[:type]).to eq(:generic)

      # Fields sorted: active, quorum, title, votingPeriod
      types = ['bool', 'uint256', 'string', 'uint256']
      decoded = Eth::Abi.decode(types, result[:encoded_params])

      expect(decoded[0]).to eq(true)      # active
      expect(decoded[1]).to eq(100)       # quorum
      expect(decoded[2]).to eq('Upgrade') # title
      expect(decoded[3]).to eq(86400)     # votingPeriod
    end
  end
end
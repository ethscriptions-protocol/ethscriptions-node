require 'rails_helper'

RSpec.describe 'GenericProtocolExtractor Type Inference' do
  # Helper to extract a single field and check what type was inferred
  def test_type_inference(field_name, value, expected_type, expected_value = nil)
    json = if value.is_a?(String) && !value.start_with?('"')
      "\"#{field_name}\":\"#{value}\""
    else
      "\"#{field_name}\":#{value.to_json}"
    end

    content_uri = "data:,{\"p\":\"test\",\"op\":\"infer\",#{json}}"
    _protocol, _operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

    return [nil, nil] if encoded_data == ''.b

    # Decode with the expected type to verify
    decoded = Eth::Abi.decode([expected_type], encoded_data)
    [expected_type, decoded[0]]
  end

  describe 'Boolean inference' do
    it 'infers "true" string as bool' do
      type, value = test_type_inference('flag', 'true', 'bool')
      expect(type).to eq('bool')
      expect(value).to eq(true)
    end

    it 'infers "false" string as bool' do
      type, value = test_type_inference('flag', 'false', 'bool')
      expect(type).to eq('bool')
      expect(value).to eq(false)
    end

    it 'infers native true as bool' do
      type, value = test_type_inference('flag', true, 'bool')
      expect(type).to eq('bool')
      expect(value).to eq(true)
    end

    it 'infers native false as bool' do
      type, value = test_type_inference('flag', false, 'bool')
      expect(type).to eq('bool')
      expect(value).to eq(false)
    end
  end

  describe 'Number inference' do
    it 'infers integer as uint256' do
      type, value = test_type_inference('num', 123, 'uint256')
      expect(type).to eq('uint256')
      expect(value).to eq(123)
    end

    it 'infers "0" string as uint256' do
      type, value = test_type_inference('num', '0', 'uint256')
      expect(type).to eq('uint256')
      expect(value).to eq(0)
    end

    it 'infers "123" string as uint256' do
      type, value = test_type_inference('num', '123', 'uint256')
      expect(type).to eq('uint256')
      expect(value).to eq(123)
    end

    it 'infers "999999999" string as uint256' do
      type, value = test_type_inference('num', '999999999', 'uint256')
      expect(type).to eq('uint256')
      expect(value).to eq(999999999)
    end

    it 'treats "01" as string (leading zero)' do
      type, value = test_type_inference('num', '01', 'string')
      expect(type).to eq('string')
      expect(value).to eq('01')
    end

    it 'treats "00" as string (leading zero)' do
      type, value = test_type_inference('num', '00', 'string')
      expect(type).to eq('string')
      expect(value).to eq('00')
    end

    it 'treats "-1" as string (negative)' do
      type, value = test_type_inference('num', '-1', 'string')
      expect(type).to eq('string')
      expect(value).to eq('-1')
    end

    it 'treats "1.5" as string (decimal)' do
      type, value = test_type_inference('num', '1.5', 'string')
      expect(type).to eq('string')
      expect(value).to eq('1.5')
    end
  end

  describe 'Bytes type inference' do
    it 'infers 20-byte hex as address' do
      addr = '0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb1'
      type, value = test_type_inference('addr', addr, 'address')
      expect(type).to eq('address')
      expect(value.downcase).to eq(addr.downcase)
    end

    it 'infers 32-byte hex as bytes32' do
      hash = '0x' + 'a' * 64
      type, value = test_type_inference('hash', hash, 'bytes32')
      expect(type).to eq('bytes32')
      # bytes32 returns as binary string, convert to hex for comparison
      expect('0x' + value.unpack1('H*')).to eq(hash)
    end

    it 'infers 1-byte hex as bytes1' do
      byte1 = '0x12'
      type, value = test_type_inference('b', byte1, 'bytes1')
      expect(type).to eq('bytes1')
      # bytes1 returns as binary string, convert to hex for comparison
      expect('0x' + value.unpack1('H*')).to eq(byte1)
    end

    it 'infers 4-byte hex as bytes4' do
      byte4 = '0x12345678'
      type, value = test_type_inference('b', byte4, 'bytes4')
      expect(type).to eq('bytes4')
      # bytes4 returns as binary string, convert to hex for comparison
      expect('0x' + value.unpack1('H*')).to eq(byte4)
    end

    it 'infers 16-byte hex as bytes16' do
      byte16 = '0x' + '1234567890abcdef' * 2
      type, value = test_type_inference('b', byte16, 'bytes16')
      expect(type).to eq('bytes16')
      # bytes16 returns as binary string, convert to hex for comparison
      expect('0x' + value.unpack1('H*')).to eq(byte16)
    end

    it 'handles uppercase hex and normalizes to lowercase' do
      addr = '0x742D35CC6634C0532925A3B844BC9E7595F0BEB1'
      type, value = test_type_inference('addr', addr, 'address')
      expect(type).to eq('address')
      expect(value).to eq(addr.downcase)
    end

    it 'treats invalid hex as string' do
      type, value = test_type_inference('text', '0xGGGG', 'string')
      expect(type).to eq('string')
      expect(value).to eq('0xGGGG')
    end

    it 'treats non-hex 0x prefix as string' do
      type, value = test_type_inference('text', '0x_not_hex', 'string')
      expect(type).to eq('string')
      expect(value).to eq('0x_not_hex')
    end
  end

  describe 'String inference' do
    it 'infers regular text as string' do
      type, value = test_type_inference('text', 'hello world', 'string')
      expect(type).to eq('string')
      expect(value).to eq('hello world')
    end

    it 'infers empty string as string' do
      type, value = test_type_inference('text', '', 'string')
      expect(type).to eq('string')
      expect(value).to eq('')
    end

    it 'infers URL as string' do
      type, value = test_type_inference('url', 'https://example.com', 'string')
      expect(type).to eq('string')
      expect(value).to eq('https://example.com')
    end

    it 'infers mixed content as string' do
      type, value = test_type_inference('text', 'user@123', 'string')
      expect(type).to eq('string')
      expect(value).to eq('user@123')
    end
  end

  describe 'Array type inference' do
    it 'infers array of numbers as uint256[]' do
      json = '"nums":["1","2","3"]'
      content_uri = "data:,{\"p\":\"test\",\"op\":\"infer\",#{json}}"
      _protocol, _operation, encoded = GenericProtocolExtractor.extract(content_uri)

      decoded = Eth::Abi.decode(['uint256[]'], encoded)
      expect(decoded[0]).to eq([1, 2, 3])
    end

    it 'infers array of addresses as address[]' do
      addrs = [
        '0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb1',
        '0x5aAeb6053f3E94C9b9A09f33669435E7Ef1BeAed'
      ]
      json = "\"addrs\":#{addrs.to_json}"
      content_uri = "data:,{\"p\":\"test\",\"op\":\"infer\",#{json}}"
      _protocol, _operation, encoded = GenericProtocolExtractor.extract(content_uri)

      decoded = Eth::Abi.decode(['address[]'], encoded)
      expect(decoded[0].map(&:downcase)).to eq(addrs.map(&:downcase))
    end

    it 'infers array of bytes32 as bytes32[]' do
      hashes = [
        '0x' + '1' * 64,
        '0x' + '2' * 64
      ]
      json = "\"hashes\":#{hashes.to_json}"
      content_uri = "data:,{\"p\":\"test\",\"op\":\"infer\",#{json}}"
      _protocol, _operation, encoded = GenericProtocolExtractor.extract(content_uri)

      decoded = Eth::Abi.decode(['bytes32[]'], encoded)
      # Each bytes32 in the array returns as binary, convert to hex for comparison
      hex_results = decoded[0].map { |b| '0x' + b.unpack1('H*') }
      expect(hex_results).to eq(hashes)
    end

    it 'infers array of bools as bool[]' do
      json = '"flags":["true","false","true"]'
      content_uri = "data:,{\"p\":\"test\",\"op\":\"infer\",#{json}}"
      _protocol, _operation, encoded = GenericProtocolExtractor.extract(content_uri)

      decoded = Eth::Abi.decode(['bool[]'], encoded)
      expect(decoded[0]).to eq([true, false, true])
    end

    it 'infers array of strings as string[]' do
      json = '"names":["alice","bob","charlie"]'
      content_uri = "data:,{\"p\":\"test\",\"op\":\"infer\",#{json}}"
      _protocol, _operation, encoded = GenericProtocolExtractor.extract(content_uri)

      decoded = Eth::Abi.decode(['string[]'], encoded)
      expect(decoded[0]).to eq(['alice', 'bob', 'charlie'])
    end

    it 'infers empty array as uint256[]' do
      json = '"empty":[]'
      content_uri = "data:,{\"p\":\"test\",\"op\":\"infer\",#{json}}"
      _protocol, _operation, encoded = GenericProtocolExtractor.extract(content_uri)

      decoded = Eth::Abi.decode(['uint256[]'], encoded)
      expect(decoded[0]).to eq([])
    end
  end

  describe 'Mixed field types' do
    it 'correctly infers multiple field types' do
      json = '{
        "p": "test",
        "op": "mixed",
        "amount": "1000",
        "recipient": "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb1",
        "txHash": "0x' + 'a' * 64 + '",
        "enabled": "true",
        "name": "Test Token",
        "ids": ["1", "2", "3"],
        "owners": ["0x' + '1' * 40 + '", "0x' + '2' * 40 + '"]
      }'

      content_uri = "data:,#{json}"
      _protocol, _operation, encoded = GenericProtocolExtractor.extract(content_uri)

      # Fields are sorted alphabetically: amount, enabled, ids, name, owners, recipient, txHash
      types = ['uint256', 'bool', 'uint256[]', 'string', 'address[]', 'address', 'bytes32']
      decoded = Eth::Abi.decode(types, encoded)

      expect(decoded[0]).to eq(1000)           # amount
      expect(decoded[1]).to eq(true)           # enabled
      expect(decoded[2]).to eq([1, 2, 3])      # ids
      expect(decoded[3]).to eq('Test Token')   # name
      expect(decoded[4].size).to eq(2)         # owners array
      expect(decoded[5]).to be_a(String)       # recipient address
      # txHash is bytes32, returns as binary string
      expect(decoded[6].bytesize).to eq(32)    # 32 bytes
    end
  end

  describe 'Edge cases and errors' do
    it 'rejects null values' do
      content_uri = 'data:,{"p":"test","op":"action","value":null}'
      result = GenericProtocolExtractor.extract(content_uri)
      expect(result).to eq([''.b, ''.b, ''.b])
    end

    it 'rejects nested objects' do
      content_uri = 'data:,{"p":"test","op":"action","value":{"nested":"object"}}'
      result = GenericProtocolExtractor.extract(content_uri)
      expect(result).to eq([''.b, ''.b, ''.b])
    end

    it 'rejects mixed-type arrays' do
      content_uri = 'data:,{"p":"test","op":"action","mixed":[1,"string",true]}'
      result = GenericProtocolExtractor.extract(content_uri)
      expect(result).to eq([''.b, ''.b, ''.b])
    end

    it 'rejects hex strings with odd length' do
      content_uri = 'data:,{"p":"test","op":"action","bad":"0x123"}'
      result = GenericProtocolExtractor.extract(content_uri)
      expect(result).to eq([''.b, ''.b, ''.b])
    end

    it 'rejects hex strings longer than 32 bytes' do
      content_uri = 'data:,{"p":"test","op":"action","bad":"0x' + '0' * 66 + '"}'
      result = GenericProtocolExtractor.extract(content_uri)
      expect(result).to eq([''.b, ''.b, ''.b])
    end

    it 'rejects empty hex strings' do
      content_uri = 'data:,{"p":"test","op":"action","bad":"0x"}'
      result = GenericProtocolExtractor.extract(content_uri)
      expect(result).to eq([''.b, ''.b, ''.b])
    end

    it 'rejects decimal numbers' do
      content_uri = 'data:,{"p":"test","op":"action","value":123.456}'
      result = GenericProtocolExtractor.extract(content_uri)
      expect(result).to eq([''.b, ''.b, ''.b])
    end

    it 'rejects negative numbers' do
      content_uri = 'data:,{"p":"test","op":"action","value":-100}'
      result = GenericProtocolExtractor.extract(content_uri)
      expect(result).to eq([''.b, ''.b, ''.b])
    end
  end

  describe 'Special cases' do
    it 'handles hexadecimal without 0x as regular string' do
      type, value = test_type_inference('text', 'abcdef123456', 'string')
      expect(type).to eq('string')
      expect(value).to eq('abcdef123456')
    end

    it 'handles numeric-looking strings that dont match pattern' do
      type, value = test_type_inference('text', '123abc', 'string')
      expect(type).to eq('string')
      expect(value).to eq('123abc')
    end

    it 'handles very large valid numbers' do
      big_num = '115792089237316195423570985008687907853269984665640564039457584007913129639935'
      type, value = test_type_inference('num', big_num, 'uint256')
      expect(type).to eq('uint256')
      expect(value).to eq(2**256 - 1)
    end

    it 'rejects numbers larger than uint256 max' do
      too_big = '115792089237316195423570985008687907853269984665640564039457584007913129639936'
      content_uri = "data:,{\"p\":\"test\",\"op\":\"action\",\"value\":\"#{too_big}\"}"
      result = GenericProtocolExtractor.extract(content_uri)
      expect(result).to eq([''.b, ''.b, ''.b])
    end
  end
end
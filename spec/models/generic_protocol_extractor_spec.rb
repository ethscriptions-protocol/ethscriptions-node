require 'rails_helper'

RSpec.describe GenericProtocolExtractor do
  let(:default_params) { [''.b, ''.b, ''.b] }

  describe '.extract' do
    context 'collections protocol' do
      it 'extracts createCollection operation with string numbers' do
        content_uri = 'data:,{"p":"collections","op":"create_collection","name":"My NFTs","symbol":"MNFT","maxSupply":"10000","baseUri":"https://api.example.com/"}'

        protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

        expect(protocol).to eq('collections'.b)
        expect(operation).to eq('create_collection'.b)

        # Decode to verify encoding - order matches JSON field order
        # Now encoded as a tuple for struct compatibility
        types = ['(string,string,uint256,string)']
        decoded_tuple = Eth::Abi.decode(types, encoded_data)
        decoded = decoded_tuple[0]  # Extract tuple contents

        expect(decoded[0]).to eq('My NFTs') # name (first in JSON)
        expect(decoded[1]).to eq('MNFT') # symbol (second in JSON)
        expect(decoded[2]).to eq(10000) # maxSupply (third in JSON)
        expect(decoded[3]).to eq('https://api.example.com/') # baseUri (fourth in JSON)
      end

      it 'handles add_members operation with address arrays' do
        content_uri = 'data:,{"p":"collections","op":"add_members","collectionId":"0x1234567890abcdef1234567890abcdef12345678","members":["0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb1","0x5aAeb6053f3E94C9b9A09f33669435E7Ef1BeAed"]}'

        protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

        expect(protocol).to eq('collections'.b)
        expect(operation).to eq('add_members'.b)

        # Arrays are supported - now encoded as tuple
        types = ['(address,address[])']
        decoded_tuple = Eth::Abi.decode(types, encoded_data)
        decoded = decoded_tuple[0]

        expect(decoded[0].downcase).to eq('0x1234567890abcdef1234567890abcdef12345678')
        expect(decoded[1][0].downcase).to eq('0x742d35cc6634c0532925a3b844bc9e7595f0beb1')
        expect(decoded[1][1].downcase).to eq('0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed')
      end
    end

    context 'governance protocol' do
      it 'extracts create_proposal with mixed types and string numbers' do
        content_uri = 'data:,{"p":"governance","op":"create_proposal","title":"Upgrade Protocol","votingPeriod":"86400","quorum":"100","choices":["Yes","No","Abstain"]}'

        protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

        expect(protocol).to eq('governance'.b)
        expect(operation).to eq('create_proposal'.b)

        # Order matches JSON field order - now encoded as tuple
        types = ['(string,uint256,uint256,string[])']
        decoded_tuple = Eth::Abi.decode(types, encoded_data)
        decoded = decoded_tuple[0]

        expect(decoded[0]).to eq('Upgrade Protocol') # title (first in JSON)
        expect(decoded[1]).to eq(86400) # votingPeriod (second in JSON)
        expect(decoded[2]).to eq(100) # quorum (third in JSON)
        expect(decoded[3]).to eq(['Yes', 'No', 'Abstain']) # choices (fourth in JSON)
      end

      it 'handles vote operation with JSON boolean' do
        # Use JSON boolean, not string "true"
        content_uri = 'data:,{"p":"governance","op":"vote","proposalId":"prop123","support":true,"reason":"Good idea"}'

        protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

        expect(protocol).to eq('governance'.b)
        expect(operation).to eq('vote'.b)

        # JSON boolean true becomes bool, not string
        types = ['(string,bool,string)']
        decoded_tuple = Eth::Abi.decode(types, encoded_data)
        decoded = decoded_tuple[0]

        expect(decoded[0]).to eq('prop123') # proposalId (first in JSON)
        expect(decoded[1]).to eq(true) # support as boolean (second in JSON)
        expect(decoded[2]).to eq('Good idea') # reason (third in JSON)
      end

      it 'keeps boolean strings as strings' do
        # String "false" remains a string - use JSON false for booleans
        content_uri = 'data:,{"p":"test","op":"toggle","enabled":"false"}'

        protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

        types = ['(string)']
        decoded_tuple = Eth::Abi.decode(types, encoded_data)
        decoded = decoded_tuple[0]

        expect(decoded[0]).to eq('false') # String "false", not boolean
      end

      it 'handles native JSON booleans' do
        content_uri = 'data:,{"p":"test","op":"flags","active":true,"disabled":false}'

        protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

        types = ['(bool,bool)']
        decoded_tuple = Eth::Abi.decode(types, encoded_data)
        decoded = decoded_tuple[0]

        expect(decoded[0]).to eq(true)  # active
        expect(decoded[1]).to eq(false) # disabled
      end
    end

    context 'marketplace protocol' do
      # it 'extracts create_listing with string numbers' do
      #   content_uri = 'data:,{"p":"marketplace","op":"create_listing","tokenId":"0x4567","price":"1000000000000000000","duration":"604800"}'

      #   protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

      #   expect(protocol).to eq('marketplace'.b)
      #   expect(operation).to eq('create_listing'.b)

      #   types = ['uint256', 'uint256', 'string']
      #   decoded = Eth::Abi.decode(types, encoded_data)

      #   expect(decoded[0]).to eq(604800)
      #   expect(decoded[1]).to eq(1000000000000000000) # 1 ETH in wei
      #   expect(decoded[2]).to eq('0x4567')
      # end
    end

    context 'type inference' do
      it 'recognizes Ethereum addresses as address type' do
        content_uri = 'data:,{"p":"test","op":"transfer","to":"0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb1"}'

        protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

        types = ['(address)']
        decoded_tuple = Eth::Abi.decode(types, encoded_data)
        decoded = decoded_tuple[0]

        expect(decoded[0].downcase).to eq('0x742d35cc6634c0532925a3b844bc9e7595f0beb1')
      end

      it 'recognizes bytes32 for 32-byte hex strings' do
        content_uri = 'data:,{"p":"test","op":"set_hash","txHash":"0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"}'

        protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

        types = ['(bytes32)']
        decoded_tuple = Eth::Abi.decode(types, encoded_data)
        decoded = decoded_tuple[0]

        expect(decoded[0]).to eq(ByteString.from_hex('0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef').to_bin)
      end

      # it 'recognizes various fixed-length bytes types' do
      #   content_uri = 'data:,{"p":"test","op":"bytes_test","byte1":"0x12","byte4":"0x12345678","byte16":"0x123456789abcdef0123456789abcdef0"}'

      #   protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

      #   types = ['bytes1', 'bytes16', 'bytes4']
      #   decoded = Eth::Abi.decode(types, encoded_data)

      #   expect(decoded[0]).to eq('0x12')
      #   expect(decoded[1]).to eq('0x123456789abcdef0123456789abcdef0')
      #   expect(decoded[2]).to eq('0x12345678')
      # end

      it 'rejects invalid hex strings' do
        # Odd number of hex chars
        content_uri = 'data:,{"p":"test","op":"bad","hash":"0x123"}'
        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)

        # Too long for bytes32
        content_uri = 'data:,{"p":"test","op":"bad","hash":"0x' + '00' * 33 + '"}'
        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)

        # Empty hex
        content_uri = 'data:,{"p":"test","op":"bad","hash":"0x"}'
        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)

        # Invalid hex characters
        content_uri = 'data:,{"p":"test","op":"bad","hash":"0xZZZZ"}'
        result = GenericProtocolExtractor.extract(content_uri)
        # This should be treated as a regular string since it doesn't match hex pattern
        protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)
        types = ['(string)']
        decoded_tuple = Eth::Abi.decode(types, encoded_data)
        decoded = decoded_tuple[0]
        expect(decoded[0]).to eq('0xZZZZ')
      end

      it 'accepts string numbers with proper format' do
        content_uri = 'data:,{"p":"test","op":"action","amount":"123","zero":"0","large":"999999"}'

        protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

        types = ['(uint256,uint256,uint256)']
        decoded_tuple = Eth::Abi.decode(types, encoded_data)
        decoded = decoded_tuple[0]

        # Order matches JSON field order
        expect(decoded[0]).to eq(123)     # amount (first in JSON)
        expect(decoded[1]).to eq(0)       # zero (second in JSON)
        expect(decoded[2]).to eq(999999)  # large (third in JSON)
      end

      it 'rejects string numbers with leading zeros' do
        content_uri = 'data:,{"p":"test","op":"action","amount":"01"}'

        result = GenericProtocolExtractor.extract(content_uri)

        # Should treat "01" as a string, not a number
        types = ['(string)']
        decoded_tuple = Eth::Abi.decode(types, result[2])
        decoded = decoded_tuple[0]
        expect(decoded[0]).to eq("01")
      end
      
      it 'rejects string numbers that are all 0s' do
        content_uri = 'data:,{"p":"test","op":"action","amount":"000"}'

        result = GenericProtocolExtractor.extract(content_uri)

        # Should treat "000" as a string, not a number
        types = ['(string)']
        decoded_tuple = Eth::Abi.decode(types, result[2])
        decoded = decoded_tuple[0]
        expect(decoded[0]).to eq("000")
      end


      it 'rejects null values' do
        content_uri = 'data:,{"p":"test","op":"action","optional":null,"required":"value"}'

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects nested objects' do
        content_uri = 'data:,{"p":"metadata","op":"update","data":{"name":"Item","attributes":{"color":"blue","size":10}}}'

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'handles empty arrays' do
        content_uri = 'data:,{"p":"test","op":"init","items":[]}'

        protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

        types = ['(uint256[])']
        decoded_tuple = Eth::Abi.decode(types, encoded_data)
        decoded = decoded_tuple[0]

        expect(decoded[0]).to eq([])
      end

      it 'handles arrays of bytes32 (transaction hashes)' do
        content_uri = 'data:,{"p":"test","op":"batch","txHashes":["0x1111111111111111111111111111111111111111111111111111111111111111","0x2222222222222222222222222222222222222222222222222222222222222222"]}'

        protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

        types = ['(bytes32[])']
        decoded_tuple = Eth::Abi.decode(types, encoded_data)
        decoded = decoded_tuple[0]

        # bytes32 are decoded as binary strings, not hex strings
        expected1 = ["1111111111111111111111111111111111111111111111111111111111111111"].pack('H*')
        expected2 = ["2222222222222222222222222222222222222222222222222222222222222222"].pack('H*')

        expect(decoded[0][0]).to eq(expected1)
        expect(decoded[0][1]).to eq(expected2)
      end
    end

    context 'security validations' do
      it 'rejects deeply nested objects' do
        content_uri = 'data:,{"p":"test","op":"bad","a":{"b":{"c":{"d":{"e":"too deep"}}}}}'

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects arrays that are too long' do
        long_array = (1..200).to_a
        content_uri = "data:,{\"p\":\"test\",\"op\":\"bad\",\"items\":#{long_array.to_json}}"

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects strings that are too long' do
        long_string = 'x' * 1001
        content_uri = "data:,{\"p\":\"test\",\"op\":\"bad\",\"text\":\"#{long_string}\"}"

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects numbers larger than uint256' do
        too_large = 2**256
        content_uri = "data:,{\"p\":\"test\",\"op\":\"bad\",\"number\":#{too_large}}"

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects negative numbers' do
        content_uri = 'data:,{"p":"test","op":"bad","amount":-100}'

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects decimal numbers' do
        content_uri = 'data:,{"p":"test","op":"bad","amount":123.456}'

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects mixed-type arrays' do
        content_uri = 'data:,{"p":"test","op":"bad","mixed":[1,"string",true]}'

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end
    end

    context 'protocol validation' do
      it 'rejects missing protocol field' do
        content_uri = 'data:,{"op":"action","param":"value"}'

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects missing operation field' do
        content_uri = 'data:,{"p":"test","param":"value"}'

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects invalid protocol names' do
        content_uri = 'data:,{"p":"Test Protocol!","op":"action"}'

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects invalid operation names with uppercase' do
        content_uri = 'data:,{"p":"test","op":"createAction"}'

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'accepts valid protocol and operation formats' do
        valid_cases = [
          ['collections', 'create_collection'],
          ['erc-20', 'mint'],
          ['my_protocol', 'do_something'],
          ['proto123', 'action-item'],
          ['a1b2c3', 'test_op']
        ]

        valid_cases.each do |proto, op|
          content_uri = "data:,{\"p\":\"#{proto}\",\"op\":\"#{op}\"}"
          protocol, operation, _ = GenericProtocolExtractor.extract(content_uri)
          expect(protocol).to eq(proto.b)
          expect(operation).to eq(op.b)
        end
      end
    end

    context 'edge cases' do
      it 'returns default params for invalid JSON' do
        content_uri = 'data:,{broken json'

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'returns default params for non-data URI' do
        content_uri = 'https://example.com'

        result = GenericProtocolExtractor.extract(content_uri)
        expect(result).to eq(default_params)
      end

      it 'returns default params for nil input' do
        result = GenericProtocolExtractor.extract(nil)
        expect(result).to eq(default_params)
      end

      it 'handles empty parameter object' do
        content_uri = 'data:,{"p":"test","op":"action"}'

        protocol, operation, encoded_data = GenericProtocolExtractor.extract(content_uri)

        expect(protocol).to eq('test'.b)
        expect(operation).to eq('action'.b)
        expect(encoded_data).to eq(''.b)
      end

      it 'preserves JSON field order (does NOT sort keys)' do
        content_uri1 = 'data:,{"p":"test","op":"action","z":"last","a":"first","m":"middle"}'
        content_uri2 = 'data:,{"p":"test","op":"action","a":"first","m":"middle","z":"last"}'

        _, _, data1 = GenericProtocolExtractor.extract(content_uri1)
        _, _, data2 = GenericProtocolExtractor.extract(content_uri2)

        # Different field orders produce different encodings
        # This is intentional - users control order to match Solidity structs
        expect(data1).not_to eq(data2)

        # Verify the order is preserved as expected
        types1 = ['(string,string,string)'] # z, a, m order
        decoded1_tuple = Eth::Abi.decode(types1, data1)
        decoded1 = decoded1_tuple[0]
        expect(decoded1).to eq(['last', 'first', 'middle'])

        types2 = ['(string,string,string)'] # a, m, z order
        decoded2_tuple = Eth::Abi.decode(types2, data2)
        decoded2 = decoded2_tuple[0]
        expect(decoded2).to eq(['first', 'middle', 'last'])
      end
    end

    context 'backwards compatibility' do
      it 'can still use TokenParamsExtractor for erc-20' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"1","amt":"100"}'

        # The token protocol should still use its strict extractor
        token_params = GenericProtocolExtractor.extract_token_params(content_uri)

        expect(token_params).to eq(['mint'.b, 'erc-20'.b, 'punk'.b, 1, 0, 100])
      end
    end
  end
end
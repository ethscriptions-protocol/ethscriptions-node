require 'rails_helper'

# Test GenericProtocolExtractor functionality through ProtocolExtractor
# This ensures generic protocols work properly when accessed via the unified interface
RSpec.describe 'GenericProtocolExtractor via ProtocolExtractor' do

  describe 'protocol extraction' do
    context 'collections protocol' do
      it 'extracts create_collection operation' do
        content_uri = 'data:,{"p":"collections","op":"create_collection","name":"My NFTs","symbol":"MNFT","maxSupply":"10000"}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:generic)
        expect(result[:protocol]).to eq('collections'.b)
        expect(result[:operation]).to eq('create_collection'.b)
        expect(result[:encoded_params]).not_to be_empty
      end

      it 'extracts add_members operation' do
        content_uri = 'data:,{"p":"collections","op":"add_members","collectionId":"0x123","members":["0xabc","0xdef"]}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:generic)
        expect(result[:protocol]).to eq('collections'.b)
        expect(result[:operation]).to eq('add_members'.b)
      end
    end

    context 'governance protocol' do
      it 'extracts create_proposal operation' do
        content_uri = 'data:,{"p":"governance","op":"create_proposal","title":"Test Proposal","quorum":"100"}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:generic)
        expect(result[:protocol]).to eq('governance'.b)
        expect(result[:operation]).to eq('create_proposal'.b)
      end

      it 'extracts vote operation' do
        content_uri = 'data:,{"p":"governance","op":"vote","proposalId":"prop123","support":"true"}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:generic)
        expect(result[:protocol]).to eq('governance'.b)
        expect(result[:operation]).to eq('vote'.b)
      end
    end

    context 'custom protocols' do
      it 'handles any protocol with p and op fields' do
        content_uri = 'data:,{"p":"my-custom-protocol","op":"do_something","param1":"value1","param2":"123"}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:generic)
        expect(result[:protocol]).to eq('my-custom-protocol'.b)
        expect(result[:operation]).to eq('do_something'.b)
      end

      it 'handles protocols with underscores' do
        content_uri = 'data:,{"p":"my_protocol","op":"my_operation","data":"test"}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:generic)
        expect(result[:protocol]).to eq('my_protocol'.b)
        expect(result[:operation]).to eq('my_operation'.b)
      end

      it 'handles protocols with numbers' do
        content_uri = 'data:,{"p":"proto123","op":"op456","value":"789"}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:generic)
        expect(result[:protocol]).to eq('proto123'.b)
        expect(result[:operation]).to eq('op456'.b)
      end
    end

    context 'protocol validation' do
      it 'rejects uppercase in protocol name' do
        content_uri = 'data:,{"p":"INVALID","op":"test"}'
        result = ProtocolExtractor.extract(content_uri)
        expect(result).to be_nil
      end

      it 'rejects uppercase in operation name' do
        content_uri = 'data:,{"p":"test","op":"InvalidOp"}'
        result = ProtocolExtractor.extract(content_uri)
        expect(result).to be_nil
      end

      it 'rejects missing protocol field' do
        content_uri = 'data:,{"op":"test","value":"123"}'
        result = ProtocolExtractor.extract(content_uri)
        expect(result).to be_nil
      end

      it 'rejects missing operation field' do
        content_uri = 'data:,{"p":"test","value":"123"}'
        result = ProtocolExtractor.extract(content_uri)
        expect(result).to be_nil
      end

      it 'rejects special characters in protocol' do
        content_uri = 'data:,{"p":"test!@#","op":"action"}'
        result = ProtocolExtractor.extract(content_uri)
        expect(result).to be_nil
      end
    end

    context 'data type handling' do
      it 'handles string numbers' do
        content_uri = 'data:,{"p":"test","op":"action","amount":"1000","count":"5"}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil

        # Decode to verify numbers were inferred
        types = ['uint256', 'uint256']
        decoded = Eth::Abi.decode(types, result[:encoded_params])
        expect(decoded[0]).to eq(1000) # amount
        expect(decoded[1]).to eq(5)    # count
      end

      it 'handles boolean strings' do
        content_uri = 'data:,{"p":"test","op":"toggle","active":"true","disabled":"false"}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil

        types = ['bool', 'bool']
        decoded = Eth::Abi.decode(types, result[:encoded_params])
        expect(decoded[0]).to eq(true)  # active
        expect(decoded[1]).to eq(false) # disabled
      end

      it 'handles addresses' do
        content_uri = 'data:,{"p":"test","op":"transfer","to":"0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb1"}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil

        types = ['address']
        decoded = Eth::Abi.decode(types, result[:encoded_params])
        expect(decoded[0]).to be_a(String)
      end

      it 'handles arrays' do
        content_uri = 'data:,{"p":"test","op":"batch","ids":["1","2","3"]}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil

        types = ['uint256[]']
        decoded = Eth::Abi.decode(types, result[:encoded_params])
        expect(decoded[0]).to eq([1, 2, 3])
      end
    end

    context 'security limits' do
      it 'rejects deeply nested objects' do
        nested = '{"a":' * 5 + '1' + '}' * 5
        content_uri = "data:,{\"p\":\"test\",\"op\":\"action\",\"data\":#{nested}}"
        result = ProtocolExtractor.extract(content_uri)
        expect(result).to be_nil
      end

      it 'rejects very long arrays' do
        long_array = (1..200).to_a
        content_uri = "data:,{\"p\":\"test\",\"op\":\"action\",\"items\":#{long_array.to_json}}"
        result = ProtocolExtractor.extract(content_uri)
        expect(result).to be_nil
      end

      it 'rejects very long strings' do
        long_string = 'x' * 1001
        content_uri = "data:,{\"p\":\"test\",\"op\":\"action\",\"text\":\"#{long_string}\"}"
        result = ProtocolExtractor.extract(content_uri)
        expect(result).to be_nil
      end

      it 'rejects null values' do
        content_uri = 'data:,{"p":"test","op":"action","value":null}'
        result = ProtocolExtractor.extract(content_uri)
        expect(result).to be_nil
      end

      it 'rejects nested hashes' do
        content_uri = 'data:,{"p":"test","op":"action","meta":{"nested":"object"}}'
        result = ProtocolExtractor.extract(content_uri)
        expect(result).to be_nil
      end
    end

    context 'edge cases' do
      it 'handles empty parameter set' do
        content_uri = 'data:,{"p":"test","op":"action"}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:generic)
        expect(result[:encoded_params]).to eq(''.b)
      end

      it 'maintains alphabetical sorting of fields' do
        content_uri = 'data:,{"p":"test","op":"sort","z":"last","a":"first","m":"middle"}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil

        # Decode with alphabetically sorted fields
        types = ['string', 'string', 'string']
        decoded = Eth::Abi.decode(types, result[:encoded_params])
        expect(decoded[0]).to eq('first')  # a
        expect(decoded[1]).to eq('middle') # m
        expect(decoded[2]).to eq('last')   # z
      end

      it 'returns nil for invalid JSON' do
        content_uri = 'data:,{broken json'
        result = ProtocolExtractor.extract(content_uri)
        expect(result).to be_nil
      end

      it 'returns nil for non-JSON content' do
        content_uri = 'data:,Hello World'
        result = ProtocolExtractor.extract(content_uri)
        expect(result).to be_nil
      end

      it 'returns nil for plain data URIs' do
        content_uri = 'data:text/plain,Hello'
        result = ProtocolExtractor.extract(content_uri)
        expect(result).to be_nil
      end
    end

    context 'backward compatibility check' do
      it 'does not pick up erc-20 tokens as generic protocol' do
        # Valid token should go through TokenParamsExtractor
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"test","id":"1","amt":"100"}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:token) # NOT :generic
        expect(result[:protocol]).to eq('erc-20')
      end

      it 'treats invalid erc-20 as generic if it has valid p/op structure' do
        # erc-20 with non-standard operation becomes generic
        content_uri = 'data:,{"p":"erc-20","op":"transfer","to":"0x123","amount":"100"}'
        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:generic)
        expect(result[:protocol]).to eq('erc-20'.b)
        expect(result[:operation]).to eq('transfer'.b)
      end
    end
  end

  describe 'for_calldata compatibility' do
    it 'returns default params for generic protocols' do
      # Until contracts are updated, generic protocols return default params
      content_uri = 'data:,{"p":"collections","op":"create","name":"Test"}'
      result = ProtocolExtractor.for_calldata(content_uri)

      expect(result).to eq([''.b, ''.b, ''.b, 0, 0, 0])
    end

    it 'returns actual params for token protocols' do
      content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"test","id":"1","amt":"100"}'
      result = ProtocolExtractor.for_calldata(content_uri)

      expect(result).to eq(['mint'.b, 'erc-20'.b, 'test'.b, 1, 0, 100])
    end
  end
end
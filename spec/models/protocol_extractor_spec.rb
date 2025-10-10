require 'rails_helper'

RSpec.describe ProtocolExtractor do
  describe '.extract' do
    context 'token protocol (erc-20)' do
      it 'delegates to TokenParamsExtractor for valid deploy' do
        content_uri = 'data:,{"p":"erc-20","op":"deploy","tick":"punk","max":"21000000","lim":"1000"}'

        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:token)
        expect(result[:protocol]).to eq('erc-20')
        expect(result[:operation]).to eq('deploy'.b)
        expect(result[:params]).to eq(['deploy'.b, 'erc-20'.b, 'punk'.b, 21000000, 1000, 0])
      end

      it 'delegates to TokenParamsExtractor for valid mint' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"1","amt":"100"}'

        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:token)
        expect(result[:protocol]).to eq('erc-20')
        expect(result[:operation]).to eq('mint'.b)
        expect(result[:params]).to eq(['mint'.b, 'erc-20'.b, 'punk'.b, 1, 0, 100])
      end

      it 'falls back to generic extractor for malformed token protocol' do
        # Missing required field (id) for token mint
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","amt":"100"}'

        result = ProtocolExtractor.extract(content_uri)

        # Should be extracted as generic protocol, not token
        expect(result).not_to be_nil
        expect(result[:type]).to eq(:generic)
        expect(result[:protocol]).to eq('erc-20')
        expect(result[:operation]).to eq('mint')
      end

      it 'falls back to generic extractor for token with extra fields' do
        # Extra fields should fail strict token validation
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"1","amt":"100","extra":"bad"}'

        result = ProtocolExtractor.extract(content_uri)

        # Should be extracted as generic protocol due to extra fields
        expect(result).not_to be_nil
        expect(result[:type]).to eq(:generic)
        expect(result[:protocol]).to eq('erc-20')
      end
    end

    context 'generic protocols' do
      it 'delegates to GenericProtocolExtractor for collections' do
        content_uri = 'data:,{"p":"collections","op":"create_collection","name":"My NFTs","maxSupply":"10000"}'

        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:generic)
        expect(result[:protocol]).to eq('collections'.b)
        expect(result[:operation]).to eq('create_collection'.b)
        expect(result[:encoded_params]).not_to be_empty
      end

      it 'delegates to GenericProtocolExtractor for governance' do
        content_uri = 'data:,{"p":"governance","op":"create_proposal","title":"Test","quorum":"100"}'

        result = ProtocolExtractor.extract(content_uri)

        expect(result).not_to be_nil
        expect(result[:type]).to eq(:generic)
        expect(result[:protocol]).to eq('governance'.b)
        expect(result[:operation]).to eq('create_proposal'.b)
      end

      it 'returns nil for invalid protocol format' do
        # Invalid protocol name (uppercase)
        content_uri = 'data:,{"p":"INVALID","op":"test"}'

        result = ProtocolExtractor.extract(content_uri)

        expect(result).to be_nil
      end

      it 'returns nil for missing protocol field' do
        content_uri = 'data:,{"op":"test","value":"123"}'

        result = ProtocolExtractor.extract(content_uri)

        expect(result).to be_nil
      end
    end

    context 'non-protocol data' do
      it 'returns nil for plain text' do
        content_uri = 'data:,Hello World'

        result = ProtocolExtractor.extract(content_uri)

        expect(result).to be_nil
      end

      it 'returns nil for non-JSON data' do
        content_uri = 'data:text/plain,Some text'

        result = ProtocolExtractor.extract(content_uri)

        expect(result).to be_nil
      end

      it 'returns nil for invalid JSON' do
        content_uri = 'data:,{invalid json'

        result = ProtocolExtractor.extract(content_uri)

        expect(result).to be_nil
      end

      it 'returns nil for nil input' do
        result = ProtocolExtractor.extract(nil)

        expect(result).to be_nil
      end
    end

    context 'backwards compatibility via for_calldata' do
      it 'returns token params for erc-20 deploy' do
        content_uri = 'data:,{"p":"erc-20","op":"deploy","tick":"punk","max":"21000000","lim":"1000"}'

        result = ProtocolExtractor.for_calldata(content_uri)

        expect(result[0]).to eq('erc-20'.b)  # protocol
        expect(result[1]).to eq('deploy'.b)   # operation
        expect(result[2]).not_to be_empty     # encoded data

        # Verify the encoded deploy params - now as tuple for struct compatibility
        types = ['(string,uint256,uint256)']
        decoded_tuple = Eth::Abi.decode(types, result[2])
        decoded = decoded_tuple[0]
        expect(decoded[0]).to eq('punk'.b)    # tick
        expect(decoded[1]).to eq(21000000)    # max
        expect(decoded[2]).to eq(1000)        # lim
      end

      it 'returns token params for erc-20 mint' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"1","amt":"100"}'

        result = ProtocolExtractor.for_calldata(content_uri)

        expect(result[0]).to eq('erc-20'.b)  # protocol
        expect(result[1]).to eq('mint'.b)     # operation
        expect(result[2]).not_to be_empty     # encoded data

        # Verify the encoded mint params - now as tuple for struct compatibility
        types = ['(string,uint256,uint256)']
        decoded_tuple = Eth::Abi.decode(types, result[2])
        decoded = decoded_tuple[0]
        expect(decoded[0]).to eq('punk'.b)    # tick
        expect(decoded[1]).to eq(1)           # id
        expect(decoded[2]).to eq(100)         # amt
      end

      it 'returns default params for non-protocol content' do
        content_uri = 'data:,Hello World'

        result = ProtocolExtractor.for_calldata(content_uri)

        expect(result).to eq([''.b, ''.b, ''.b])
      end

      it 'returns extracted params for generic protocols' do
        # Generic protocols now return actual extracted data
        content_uri = 'data:,{"p":"collections","op":"create","name":"Test"}'

        result = ProtocolExtractor.for_calldata(content_uri)

        expect(result[0]).to eq('collections'.b)  # protocol
        expect(result[1]).to eq('create'.b)        # operation
        expect(result[2]).not_to be_empty          # encoded data

        # Verify the encoded params - now as tuple
        types = ['(string)']
        decoded_tuple = Eth::Abi.decode(types, result[2])
        decoded = decoded_tuple[0]
        expect(decoded[0]).to eq('Test')
      end

      it 'returns generic protocol data for malformed token protocol' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk"}' # Missing id and amt

        result = ProtocolExtractor.for_calldata(content_uri)

        # Malformed token protocol is parsed as generic protocol
        expect(result[0]).to eq('erc-20'.b)
        expect(result[1]).to eq('mint'.b)
        expect(result[2]).not_to be_empty # Has encoded data
      end
    end

    context 'protocol priority' do
      it 'prioritizes token protocol over generic when both could match' do
        # This should be treated as token protocol despite being valid JSON
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"test","id":"1","amt":"100"}'

        result = ProtocolExtractor.extract(content_uri)

        expect(result[:type]).to eq(:token)
        expect(result[:protocol]).to eq('erc-20')
      end

      it 'falls back to generic for erc-20 with non-standard operations' do
        # erc-20 with invalid operation should not match token protocol
        content_uri = 'data:,{"p":"erc-20","op":"transfer","tick":"test","to":"0x1234567890123456789012345678901234567890","amt":"100"}'

        result = ProtocolExtractor.extract(content_uri)

        # This will be picked up by generic extractor
        expect(result[:type]).to eq(:generic)
        expect(result[:protocol]).to eq('erc-20'.b)
        expect(result[:operation]).to eq('transfer'.b)
      end
    end
  end

  describe 'edge cases' do
    it 'handles very long input gracefully' do
      long_value = 'x' * 10000
      content_uri = "data:,{\"p\":\"test\",\"op\":\"action\",\"data\":\"#{long_value}\"}"

      # Should fail due to size limits in GenericProtocolExtractor
      result = ProtocolExtractor.extract(content_uri)

      expect(result).to be_nil
    end

    it 'handles deeply nested JSON' do
      nested = '{"a":' * 10 + '1' + '}' * 10
      content_uri = "data:,{\"p\":\"test\",\"op\":\"action\",\"data\":#{nested}}"

      # Should fail due to depth limits
      result = ProtocolExtractor.extract(content_uri)

      expect(result).to be_nil
    end
  end
end
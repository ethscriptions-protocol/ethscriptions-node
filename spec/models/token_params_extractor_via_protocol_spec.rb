require 'rails_helper'

# Test TokenParamsExtractor functionality through ProtocolExtractor
# This ensures the token protocol continues to work properly when accessed via the unified interface
RSpec.describe 'TokenParamsExtractor via ProtocolExtractor' do
  let(:default_params) { [''.b, ''.b, ''.b, 0, 0, 0] }
  let(:uint256_max) { 2**256 - 1 }

  describe 'token protocol extraction' do
    context 'valid operations' do
      it 'extracts deploy operation params with all required fields' do
        content_uri = 'data:,{"p":"erc-20","op":"deploy","tick":"punk","max":"21000000","lim":"1000"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(['deploy'.b, 'erc-20'.b, 'punk'.b, 21000000, 1000, 0])
      end

      it 'extracts mint operation params with all required fields' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"1","amt":"100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(['mint'.b, 'erc-20'.b, 'punk'.b, 1, 0, 100])
      end

      it 'handles zero values correctly' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"0","amt":"0"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(['mint'.b, 'erc-20'.b, 'punk'.b, 0, 0, 0])
      end

      it 'handles single character tick' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"a","id":"1","amt":"100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(['mint'.b, 'erc-20'.b, 'a'.b, 1, 0, 100])
      end

      it 'handles max length tick (28 chars)' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"abcdefghijklmnopqrstuvwxyz12","id":"1","amt":"100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(['mint'.b, 'erc-20'.b, 'abcdefghijklmnopqrstuvwxyz12'.b, 1, 0, 100])
      end

      it 'handles exactly max uint256 value' do
        content_uri = "data:,{\"p\":\"erc-20\",\"op\":\"mint\",\"tick\":\"punk\",\"id\":\"1\",\"amt\":\"#{uint256_max}\"}"
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(['mint'.b, 'erc-20'.b, 'punk'.b, 1, 0, uint256_max])
      end
    end

    context 'strict format requirements' do
      it 'rejects mint with integer values instead of strings' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":1,"amt":100}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects mint with missing required fields' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","amt":"100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects extra spaces in JSON' do
        content_uri = 'data:,{"p": "erc-20","op": "mint","tick": "punk","id": "1","amt": "100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects wrong key order' do
        content_uri = 'data:,{"op":"mint","p":"erc-20","tick":"punk","id":"1","amt":"100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects extra fields' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"1","amt":"100","extra":"bad"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end
    end

    context 'security validations' do
      it 'rejects array in id field' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":[831,832],"amt":"1"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects SQL injection in tick' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk\nDROP TABLE"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects nested objects' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"1","amt":"100","meta":{"foo":"bar"}}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end
    end

    context 'number validation' do
      it 'rejects negative numbers' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"-1","amt":"100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects hex numbers' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"0x10","amt":"100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects leading zeros' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"01","amt":"100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects numbers too large for uint256' do
        content_uri = "data:,{\"p\":\"erc-20\",\"op\":\"mint\",\"tick\":\"punk\",\"id\":\"1\",\"amt\":\"#{uint256_max + 1}\"}"
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end
    end

    context 'tick validation' do
      it 'rejects uppercase ticks' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"PUNK","id":"1","amt":"100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects ticks with special characters' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"pu-nk","id":"1","amt":"100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects ticks too long' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"abcdefghijklmnopqrstuvwxyz123","id":"1","amt":"100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end
    end

    context 'protocol validation' do
      it 'rejects wrong protocol' do
        content_uri = 'data:,{"p":"erc-721","op":"mint","tick":"punk","id":"1","amt":"100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'rejects unknown operations for erc-20' do
        content_uri = 'data:,{"p":"erc-20","op":"transfer","tick":"punk","id":"1","amt":"100"}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end
    end

    context 'edge cases' do
      it 'returns default params for empty JSON' do
        content_uri = 'data:,{}'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'returns default params for non-protocol content' do
        content_uri = 'data:,Hello World!'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end

      it 'returns default params for nil input' do
        result = ProtocolExtractor.for_calldata(nil)
        expect(result).to eq(default_params)
      end

      it 'returns default params for invalid JSON' do
        content_uri = 'data:,{broken json'
        result = ProtocolExtractor.for_calldata(content_uri)
        expect(result).to eq(default_params)
      end
    end
  end

  describe 'extraction result structure' do
    it 'returns proper structure for valid token protocol' do
      content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"test","id":"1","amt":"100"}'
      result = ProtocolExtractor.extract(content_uri)

      expect(result).not_to be_nil
      expect(result[:type]).to eq(:token)
      expect(result[:protocol]).to eq('erc-20')
      expect(result[:operation]).to eq('mint'.b)
      expect(result[:params]).to eq(['mint'.b, 'erc-20'.b, 'test'.b, 1, 0, 100])
    end

    it 'returns nil for invalid token protocol' do
      content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"test"}' # Missing fields
      result = ProtocolExtractor.extract(content_uri)

      expect(result).to be_nil
    end
  end
end
require 'rails_helper'

RSpec.describe TokenParamsExtractor do
  let(:default_params) { [''.b, ''.b, ''.b, 0, 0, 0] }
  let(:uint256_max) { 2**256 - 1 }

  describe '.extract' do
    context 'valid operations' do
      it 'extracts deploy operation params with all required fields' do
        content_uri = 'data:,{"p":"erc-20","op":"deploy","tick":"punk","max":"21000000","lim":"1000"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(['deploy'.b, 'erc-20'.b, 'punk'.b, 21000000, 1000, 0])
      end

      it 'extracts mint operation params with all required fields' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(['mint'.b, 'erc-20'.b, 'punk'.b, 1, 0, 100])
      end

      it 'handles zero values correctly' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"0","amt":"0"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(['mint'.b, 'erc-20'.b, 'punk'.b, 0, 0, 0])
      end

      it 'handles single character tick' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"a","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(['mint'.b, 'erc-20'.b, 'a'.b, 1, 0, 100])
      end

      it 'handles max length tick (28 chars)' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"abcdefghijklmnopqrstuvwxyz12","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(['mint'.b, 'erc-20'.b, 'abcdefghijklmnopqrstuvwxyz12'.b, 1, 0, 100])
      end

      it 'handles exactly max uint256 value' do
        content_uri = "data:,{\"p\":\"erc-20\",\"op\":\"mint\",\"tick\":\"punk\",\"id\":\"1\",\"amt\":\"#{uint256_max}\"}"
        expect(TokenParamsExtractor.extract(content_uri)).to eq(['mint'.b, 'erc-20'.b, 'punk'.b, 1, 0, uint256_max])
      end

      it 'handles deploy with zero lim' do
        content_uri = 'data:,{"p":"erc-20","op":"deploy","tick":"test","max":"1000","lim":"0"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(['deploy'.b, 'erc-20'.b, 'test'.b, 1000, 0, 0])
      end
    end

    context 'strict format requirements' do
      it 'rejects mint with integer values instead of strings' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":1,"amt":100}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects mint with optional fields omitted (id missing)' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects mint with optional fields omitted (amt missing)' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"1"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects mint with only required protocol fields' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects extra spaces in JSON' do
        content_uri = 'data:,{"p": "erc-20","op": "mint","tick": "punk","id": "1","amt": "100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects wrong key order' do
        content_uri = 'data:,{"op":"mint","p":"erc-20","tick":"punk","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects extra fields' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"1","amt":"100","extra":"bad"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end
    end

    context 'security and data smuggling prevention' do
      it 'rejects array in id field (security issue)' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":[831,832],"amt":"1"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects object in amt field' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"1","amt":{"value":100}}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects SQL injection in tick' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk\nDROP TABLE"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects nested JSON objects' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"1","amt":"100","meta":{"foo":"bar"}}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end
    end

    context 'data type validation' do
      it 'rejects boolean in max field' do
        content_uri = 'data:,{"p":"erc-20","op":"deploy","tick":"punk","max":true,"lim":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects null values in deploy' do
        content_uri = 'data:,{"p":"erc-20","op":"deploy","tick":"punk","max":null,"lim":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects array as op' do
        content_uri = 'data:,{"p":"erc-20","op":["deploy"],"tick":"punk","max":"1000","lim":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects non-JSON object (array)' do
        content_uri = 'data:,["not","an","object"]'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end
    end

    context 'number format validation' do
      it 'rejects non-numeric string' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"abc","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects negative number' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"-1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects hex number' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"0x10","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects float number' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"1.5","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects number with whitespace' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":" 1 ","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects leading zeros (except standalone zero)' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"punk","id":"01","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects number too large for uint256' do
        content_uri = "data:,{\"p\":\"erc-20\",\"op\":\"mint\",\"tick\":\"punk\",\"id\":\"1\",\"amt\":\"#{uint256_max + 1}\"}"
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end
    end

    context 'tick validation' do
      it 'rejects tick with uppercase' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"PUNK","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects tick with special characters (hyphen)' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"pu-nk","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects tick too long (29 chars)' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"abcdefghijklmnopqrstuvwxyz123","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects tick with emoji' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"🚀moon","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects empty string tick' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end
    end

    context 'protocol and operation validation' do
      it 'rejects wrong protocol (erc-721)' do
        content_uri = 'data:,{"p":"erc-721","op":"mint","tick":"punk","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects protocol with underscore' do
        content_uri = 'data:,{"p":"erc_20","op":"mint","tick":"punk","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects protocol with uppercase' do
        content_uri = 'data:,{"p":"ERC-20","op":"mint","tick":"punk","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects unknown operations' do
        content_uri = 'data:,{"p":"erc-20","op":"transfer","tick":"punk","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'handles unknown operations with protocol/tick' do
        content_uri = 'data:,{"p":"new-proto","op":"custom","tick":"test"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end
    end

    context 'required fields validation' do
      it 'rejects missing op field' do
        content_uri = 'data:,{"p":"erc-20","tick":"punk","max":"1000","lim":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects missing protocol field' do
        content_uri = 'data:,{"op":"mint","tick":"punk","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects missing tick field' do
        content_uri = 'data:,{"p":"erc-20","op":"mint","id":"1","amt":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects deploy missing max' do
        content_uri = 'data:,{"p":"erc-20","op":"deploy","tick":"punk","lim":"100"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects deploy missing lim' do
        content_uri = 'data:,{"p":"erc-20","op":"deploy","tick":"punk","max":"1000"}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end
    end

    context 'JSON format validation' do
      it 'rejects invalid JSON' do
        content_uri = 'data:,{broken json'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'rejects JSON with incorrect format' do
        content_uri = 'data:,{"invalid":true}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end
    end

    context 'edge cases' do
      it 'returns default params for empty data URI' do
        content_uri = 'data:,{}'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'returns default params for non-data URI' do
        content_uri = 'https://example.com'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'returns default params for nil input' do
        expect(TokenParamsExtractor.extract(nil)).to eq(default_params)
      end

      it 'returns default params for non-token content' do
        content_uri = 'data:,Hello World!'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'returns default params for plain text data' do
        content_uri = 'data:text/plain,Hello'
        expect(TokenParamsExtractor.extract(content_uri)).to eq(default_params)
      end

      it 'returns default params for empty string' do
        expect(TokenParamsExtractor.extract('')).to eq(default_params)
      end
    end

    context 'non-string input types' do
      it 'returns default params for integer input' do
        expect(TokenParamsExtractor.extract(123)).to eq(default_params)
      end

      it 'returns default params for array input' do
        expect(TokenParamsExtractor.extract([])).to eq(default_params)
      end

      it 'returns default params for hash input' do
        expect(TokenParamsExtractor.extract({})).to eq(default_params)
      end
    end
  end
end
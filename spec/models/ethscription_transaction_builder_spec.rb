require 'rails_helper'

RSpec.describe EthscriptionTransactionBuilder do
  describe '.extract_token_params' do
    it 'extracts deploy operation params' do
      content_uri = 'data:,{"p":"erc-20","op":"deploy","tick":"eths","max":"21000000","lim":"1000"}'

      params = TokenParamsExtractor.extract(content_uri)

      expect(params).to eq(['deploy', 'erc-20', 'eths', 21000000, 1000, 0])
    end

    it 'extracts mint operation params' do
      content_uri = 'data:,{"p":"erc-20","op":"mint","tick":"eths","id":"1","amt":"1000"}'

      params = TokenParamsExtractor.extract(content_uri)

      expect(params).to eq(['mint', 'erc-20', 'eths', 1, 0, 1000])
    end

    it 'returns default params for non-token content' do
      content_uri = 'data:,Hello World!'

      params = TokenParamsExtractor.extract(content_uri)

      expect(params).to eq(['', '', '', 0, 0, 0])
    end

    it 'returns default params for invalid JSON' do
      content_uri = 'data:,{invalid json'

      params = TokenParamsExtractor.extract(content_uri)

      expect(params).to eq(['', '', '', 0, 0, 0])
    end

    it 'handles unknown operations with protocol/tick' do
      content_uri = 'data:,{"p":"new-proto","op":"custom","tick":"test"}'

      params = TokenParamsExtractor.extract(content_uri)

      expect(params).to eq(["", "", "", 0, 0, 0])
    end
  end
end

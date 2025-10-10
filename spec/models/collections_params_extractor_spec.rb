require 'rails_helper'

RSpec.describe CollectionsParamsExtractor do
  describe '#extract' do
    let(:default_params) { [''.b, ''.b, ''.b] }

    describe 'validation rules' do
      # @generic-compatible
      it 'requires data:, prefix' do
        json = '{"p":"collections","op":"lock_collection","collection_id":"0x' + 'a' * 64 + '"}'
        result = described_class.extract(json)
        expect(result).to eq(default_params)
      end

      # @generic-compatible
      it 'requires valid JSON' do
        result = described_class.extract('data:,{invalid json}')
        expect(result).to eq(default_params)
      end

      it 'requires p:collections' do
        json = 'data:,{"p":"other","op":"lock_collection","collection_id":"0x' + 'a' * 64 + '"}'
        result = described_class.extract(json)
        expect(result).to eq(default_params)
      end

      it 'requires known operation' do
        json = 'data:,{"p":"collections","op":"unknown_op","collection_id":"0x' + 'a' * 64 + '"}'
        result = described_class.extract(json)
        expect(result).to eq(default_params)
      end

      # @generic-compatible
      it 'enforces exact key order with p and op first' do
        # Wrong order - op before p
        json1 = 'data:,{"op":"lock_collection","p":"collections","collection_id":"0x' + 'a' * 64 + '"}'
        expect(described_class.extract(json1)).to eq(default_params)

        # Wrong order - collection_id before op
        json2 = 'data:,{"p":"collections","collection_id":"0x' + 'a' * 64 + '","op":"lock_collection"}'
        expect(described_class.extract(json2)).to eq(default_params)

        # Correct order
        json3 = 'data:,{"p":"collections","op":"lock_collection","collection_id":"0x' + 'a' * 64 + '"}'
        result = described_class.extract(json3)
        expect(result[0]).to eq('collections'.b)
        expect(result[1]).to eq('lock_collection'.b)
      end

      # @generic-compatible
      it 'rejects extra keys' do
        json = 'data:,{"p":"collections","op":"lock_collection","collection_id":"0x' + 'a' * 64 + '","extra":"field"}'
        result = described_class.extract(json)
        expect(result).to eq(default_params)
      end

      # @generic-compatible
      it 'validates uint256 format - no leading zeros' do
        # Valid
        valid_json = 'data:,{"p":"collections","op":"create_collection","name":"Test","symbol":"TEST","total_supply":"1000","description":"","logo_image_uri":"","banner_image_uri":"","background_color":"","website_link":"","twitter_link":"","discord_link":""}'
        result = described_class.extract(valid_json)
        expect(result[0]).to eq('collections'.b)

        # Invalid - leading zero
        invalid_json = 'data:,{"p":"collections","op":"create_collection","name":"Test","symbol":"TEST","total_supply":"01000","description":"","logo_image_uri":"","banner_image_uri":"","background_color":"","website_link":"","twitter_link":"","discord_link":""}'
        result = described_class.extract(invalid_json)
        expect(result).to eq(default_params)
      end

      # @generic-compatible
      it 'validates bytes32 format - lowercase hex only' do
        # Valid lowercase
        valid_json = 'data:,{"p":"collections","op":"lock_collection","collection_id":"0x' + 'a' * 64 + '"}'
        result = described_class.extract(valid_json)
        expect(result[0]).to eq('collections'.b)

        # Invalid - uppercase
        invalid_json = 'data:,{"p":"collections","op":"lock_collection","collection_id":"0x' + 'A' * 64 + '"}'
        result = described_class.extract(invalid_json)
        expect(result).to eq(default_params)

        # Invalid - wrong length
        invalid_json2 = 'data:,{"p":"collections","op":"lock_collection","collection_id":"0x' + 'a' * 63 + '"}'
        result = described_class.extract(invalid_json2)
        expect(result).to eq(default_params)

        # Invalid - no 0x prefix
        invalid_json3 = 'data:,{"p":"collections","op":"lock_collection","collection_id":"' + 'a' * 64 + '"}'
        result = described_class.extract(invalid_json3)
        expect(result).to eq(default_params)
      end
    end

    describe 'create_collection operation' do
      let(:valid_create_json) do
        'data:,{"p":"collections","op":"create_collection","name":"My Collection","symbol":"MYC","total_supply":"10000","description":"A test collection","logo_image_uri":"esc://logo","banner_image_uri":"esc://banner","background_color":"#FF5733","website_link":"https://example.com","twitter_link":"https://twitter.com/test","discord_link":"https://discord.gg/test"}'
      end

      it 'encodes create_collection correctly' do
        result = described_class.extract(valid_create_json)

        expect(result[0]).to eq('collections'.b)
        expect(result[1]).to eq('create_collection'.b)

        # Decode and verify
        decoded = Eth::Abi.decode(
          ['(string,string,uint256,string,string,string,string,string,string,string)'],
          result[2]
        )[0]

        expect(decoded[0]).to eq("My Collection")
        expect(decoded[1]).to eq("MYC")
        expect(decoded[2]).to eq(10000)
        expect(decoded[3]).to eq("A test collection")
        expect(decoded[4]).to eq("esc://logo")
        expect(decoded[5]).to eq("esc://banner")
        expect(decoded[6]).to eq("#FF5733")
        expect(decoded[7]).to eq("https://example.com")
        expect(decoded[8]).to eq("https://twitter.com/test")
        expect(decoded[9]).to eq("https://discord.gg/test")
      end

      it 'handles empty optional fields' do
        json = 'data:,{"p":"collections","op":"create_collection","name":"Test","symbol":"TST","total_supply":"100","description":"","logo_image_uri":"","banner_image_uri":"","background_color":"","website_link":"","twitter_link":"","discord_link":""}'
        result = described_class.extract(json)

        expect(result[0]).to eq('collections'.b)
        expect(result[1]).to eq('create_collection'.b)

        decoded = Eth::Abi.decode(
          ['(string,string,uint256,string,string,string,string,string,string,string)'],
          result[2]
        )[0]

        expect(decoded[0]).to eq("Test")
        expect(decoded[1]).to eq("TST")
        expect(decoded[2]).to eq(100)
        expect(decoded[3]).to eq("")
      end

      it 'rejects uint256 values that exceed maximum' do
        # Value that exceeds uint256 max
        too_large = (2**256).to_s  # One more than max

        json = 'data:,{"p":"collections","op":"create_collection","name":"Test","symbol":"TST","total_supply":"' + too_large + '","description":"","logo_image_uri":"","banner_image_uri":"","background_color":"","website_link":"","twitter_link":"","discord_link":""}'
        result = described_class.extract(json)

        # Should return default params due to validation failure
        expect(result).to eq(described_class::DEFAULT_PARAMS)
      end

      it 'accepts maximum valid uint256 value' do
        # Maximum valid uint256
        max_uint256 = (2**256 - 1).to_s

        json = 'data:,{"p":"collections","op":"create_collection","name":"Test","symbol":"TST","total_supply":"' + max_uint256 + '","description":"","logo_image_uri":"","banner_image_uri":"","background_color":"","website_link":"","twitter_link":"","discord_link":""}'
        result = described_class.extract(json)

        # Should succeed with max value
        expect(result[0]).to eq('collections'.b)
        expect(result[1]).to eq('create_collection'.b)

        decoded = Eth::Abi.decode(
          ['(string,string,uint256,string,string,string,string,string,string,string)'],
          result[2]
        )[0]

        expect(decoded[2]).to eq(2**256 - 1)
      end
    end

    describe 'add_items_batch operation' do
      let(:valid_add_items_json) do
        'data:,{"p":"collections","op":"add_items_batch","collection_id":"0x' + '1' * 64 + '","items":[{"item_index":"0","name":"Item 1","ethscription_id":"0x' + '2' * 64 + '","background_color":"#FF0000","description":"First item","attributes":[{"trait_type":"Rarity","value":"Common"},{"trait_type":"Level","value":"1"}]}]}'
      end

      it 'encodes add_items_batch correctly' do
        result = described_class.extract(valid_add_items_json)

        expect(result[0]).to eq('collections'.b)
        expect(result[1]).to eq('add_items_batch'.b)

        # Decode and verify
        decoded = Eth::Abi.decode(
          ['(bytes32,(uint256,string,bytes32,string,string,(string,string)[])[])'],
          result[2]
        )[0]

        expect(decoded[0].unpack1('H*')).to eq('1' * 64)

        item = decoded[1][0]
        expect(item[0]).to eq(0) # item_index
        expect(item[1]).to eq("Item 1")
        expect(item[2].unpack1('H*')).to eq('2' * 64)
        expect(item[3]).to eq("#FF0000")
        expect(item[4]).to eq("First item")
        expect(item[5]).to eq([["Rarity", "Common"], ["Level", "1"]])
      end

      it 'validates item key order' do
        # Wrong key order in item
        json = 'data:,{"p":"collections","op":"add_items_batch","collection_id":"0x' + '1' * 64 + '","items":[{"name":"Item 1","item_index":"0","ethscription_id":"0x' + '2' * 64 + '","background_color":"#FF0000","description":"First item","attributes":[]}]}'
        result = described_class.extract(json)
        expect(result).to eq(default_params)
      end

      it 'validates attribute key order' do
        # Wrong key order in attributes (value before trait_type)
        json = 'data:,{"p":"collections","op":"add_items_batch","collection_id":"0x' + '1' * 64 + '","items":[{"item_index":"0","name":"Item 1","ethscription_id":"0x' + '2' * 64 + '","background_color":"#FF0000","description":"First item","attributes":[{"value":"Common","trait_type":"Rarity"}]}]}'
        result = described_class.extract(json)
        expect(result).to eq(default_params)
      end

      it 'handles empty attributes array' do
        json = 'data:,{"p":"collections","op":"add_items_batch","collection_id":"0x' + '1' * 64 + '","items":[{"item_index":"0","name":"Item 1","ethscription_id":"0x' + '2' * 64 + '","background_color":"","description":"","attributes":[]}]}'
        result = described_class.extract(json)

        expect(result[0]).to eq('collections'.b)

        decoded = Eth::Abi.decode(
          ['(bytes32,(uint256,string,bytes32,string,string,(string,string)[])[])'],
          result[2]
        )[0]

        item = decoded[1][0]
        expect(item[5]).to eq([]) # Empty attributes
      end

      it 'handles multiple items' do
        json = 'data:,{"p":"collections","op":"add_items_batch","collection_id":"0x' + '1' * 64 + '","items":[' +
          '{"item_index":"0","name":"Item 1","ethscription_id":"0x' + '2' * 64 + '","background_color":"","description":"","attributes":[]},' +
          '{"item_index":"1","name":"Item 2","ethscription_id":"0x' + '3' * 64 + '","background_color":"","description":"","attributes":[]}' +
          ']}'
        result = described_class.extract(json)

        expect(result[0]).to eq('collections'.b)

        decoded = Eth::Abi.decode(
          ['(bytes32,(uint256,string,bytes32,string,string,(string,string)[])[])'],
          result[2]
        )[0]

        expect(decoded[1].length).to eq(2)
        expect(decoded[1][0][0]).to eq(0) # First item index
        expect(decoded[1][1][0]).to eq(1) # Second item index
      end
    end

    describe 'remove_items operation' do
      it 'encodes remove_items correctly' do
        json = 'data:,{"p":"collections","op":"remove_items","collection_id":"0x' + '1' * 64 + '","ethscription_ids":["0x' + '2' * 64 + '","0x' + '3' * 64 + '"]}'
        result = described_class.extract(json)

        expect(result[0]).to eq('collections'.b)
        expect(result[1]).to eq('remove_items'.b)

        decoded = Eth::Abi.decode(['(bytes32,bytes32[])'], result[2])[0]

        expect(decoded[0].unpack1('H*')).to eq('1' * 64)
        expect(decoded[1][0].unpack1('H*')).to eq('2' * 64)
        expect(decoded[1][1].unpack1('H*')).to eq('3' * 64)
      end
    end

    describe 'edit_collection operation' do
      it 'encodes edit_collection correctly' do
        json = 'data:,{"p":"collections","op":"edit_collection","collection_id":"0x' + '1' * 64 + '","description":"Updated","logo_image_uri":"new_logo","banner_image_uri":"","background_color":"#00FF00","website_link":"https://new.com","twitter_link":"","discord_link":""}'
        result = described_class.extract(json)

        expect(result[0]).to eq('collections'.b)
        expect(result[1]).to eq('edit_collection'.b)

        decoded = Eth::Abi.decode(
          ['(bytes32,string,string,string,string,string,string,string)'],
          result[2]
        )[0]

        expect(decoded[0].unpack1('H*')).to eq('1' * 64)
        expect(decoded[1]).to eq("Updated")
        expect(decoded[2]).to eq("new_logo")
        expect(decoded[3]).to eq("")
        expect(decoded[4]).to eq("#00FF00")
        expect(decoded[5]).to eq("https://new.com")
      end
    end

    describe 'edit_collection_item operation' do
      it 'encodes edit_collection_item correctly' do
        json = 'data:,{"p":"collections","op":"edit_collection_item","collection_id":"0x' + '1' * 64 + '","item_index":"5","name":"Updated Name","background_color":"#0000FF","description":"Updated desc","attributes":[{"trait_type":"New","value":"Value"}]}'
        result = described_class.extract(json)

        expect(result[0]).to eq('collections'.b)
        expect(result[1]).to eq('edit_collection_item'.b)

        decoded = Eth::Abi.decode(
          ['(bytes32,uint256,string,string,string,(string,string)[])'],
          result[2]
        )[0]

        expect(decoded[0].unpack1('H*')).to eq('1' * 64)
        expect(decoded[1]).to eq(5)
        expect(decoded[2]).to eq("Updated Name")
        expect(decoded[3]).to eq("#0000FF")
        expect(decoded[4]).to eq("Updated desc")
        expect(decoded[5]).to eq([["New", "Value"]])
      end
    end

    describe 'lock_collection operation' do
      it 'encodes lock_collection as single bytes32' do
        json = 'data:,{"p":"collections","op":"lock_collection","collection_id":"0x' + '1' * 64 + '"}'
        result = described_class.extract(json)

        expect(result[0]).to eq('collections'.b)
        expect(result[1]).to eq('lock_collection'.b)

        # Single bytes32, not a tuple
        decoded = Eth::Abi.decode(['bytes32'], result[2])[0]
        expect(decoded.unpack1('H*')).to eq('1' * 64)
      end
    end

    describe 'sync_ownership operation' do
      it 'encodes sync_ownership correctly' do
        json = 'data:,{"p":"collections","op":"sync_ownership","collection_id":"0x' + '1' * 64 + '","ethscription_ids":["0x' + '2' * 64 + '"]}'
        result = described_class.extract(json)

        expect(result[0]).to eq('collections'.b)
        expect(result[1]).to eq('sync_ownership'.b)

        decoded = Eth::Abi.decode(['(bytes32,bytes32[])'], result[2])[0]

        expect(decoded[0].unpack1('H*')).to eq('1' * 64)
        expect(decoded[1][0].unpack1('H*')).to eq('2' * 64)
      end
    end

    describe 'round-trip tests' do
      # @generic-compatible
      it 'preserves all data through encode/decode cycle' do
        test_cases = [
          {
            json: 'data:,{"p":"collections","op":"create_collection","name":"Test","symbol":"TST","total_supply":"100","description":"Desc","logo_image_uri":"logo","banner_image_uri":"banner","background_color":"#FFF","website_link":"http://test","twitter_link":"@test","discord_link":"discord"}',
            abi_type: '(string,string,uint256,string,string,string,string,string,string,string)',
            expected: ["Test", "TST", 100, "Desc", "logo", "banner", "#FFF", "http://test", "@test", "discord"]
          },
          {
            json: 'data:,{"p":"collections","op":"lock_collection","collection_id":"0x' + 'a' * 64 + '"}',
            abi_type: 'bytes32',
            expected: ['a' * 64].pack('H*')
          }
        ]

        test_cases.each do |test_case|
          result = described_class.extract(test_case[:json])
          expect(result[0]).not_to eq(''.b)

          decoded = Eth::Abi.decode([test_case[:abi_type]], result[2])

          if test_case[:abi_type].start_with?('(')
            # Tuple
            expect(decoded[0]).to eq(test_case[:expected])
          else
            # Single value
            expect(decoded[0]).to eq(test_case[:expected])
          end
        end
      end
    end

    describe 'error cases' do
      it 'returns default params for malformed JSON' do
        test_cases = [
          'data:,{broken json',
          'data:,',
          'data:,null',
          'data:,[]',
          'data:,"string"'
        ]

        test_cases.each do |json|
          result = described_class.extract(json)
          expect(result).to eq(default_params)
        end
      end

      it 'rejects null values in string fields (no silent coercion)' do
        # Test null in create_collection string fields
        json_with_null = 'data:,{"p":"collections","op":"create_collection","name":null,"symbol":"TEST","total_supply":"100","description":"","logo_image_uri":"","banner_image_uri":"","background_color":"","website_link":"","twitter_link":"","discord_link":""}'
        result = described_class.extract(json_with_null)
        expect(result).to eq(default_params)

        # Test null in description field
        json_with_null_desc = 'data:,{"p":"collections","op":"create_collection","name":"Test","symbol":"TEST","total_supply":"100","description":null,"logo_image_uri":"","banner_image_uri":"","background_color":"","website_link":"","twitter_link":"","discord_link":""}'
        result = described_class.extract(json_with_null_desc)
        expect(result).to eq(default_params)

        # Test null in item fields
        json_with_null_item = 'data:,{"p":"collections","op":"add_items_batch","collection_id":"0x' + '1' * 64 + '","items":[{"item_index":"0","name":null,"ethscription_id":"0x' + '2' * 64 + '","background_color":"","description":"","attributes":[]}]}'
        result = described_class.extract(json_with_null_item)
        expect(result).to eq(default_params)

        # Test null in attribute fields
        json_with_null_attr = 'data:,{"p":"collections","op":"add_items_batch","collection_id":"0x' + '1' * 64 + '","items":[{"item_index":"0","name":"Item","ethscription_id":"0x' + '2' * 64 + '","background_color":"","description":"","attributes":[{"trait_type":null,"value":"test"}]}]}'
        result = described_class.extract(json_with_null_attr)
        expect(result).to eq(default_params)
      end

      it 'returns default params for missing required fields' do
        # Missing collection_id
        json = 'data:,{"p":"collections","op":"lock_collection"}'
        result = described_class.extract(json)
        expect(result).to eq(default_params)
      end
    end
  end
end
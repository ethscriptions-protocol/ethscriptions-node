require 'rails_helper'

RSpec.describe GenericProtocolExtractor, 'type hints' do
  describe 'with type hint arrays' do
    it 'handles empty array with type hint' do
      json = {
        "p" => "collections",
        "op" => "edit_item",
        "collectionId" => "0x1234",
        "itemIndex" => 42,
        "name" => "Updated Item",
        "attributes" => ["(string,string)[]", []]  # Type hint for empty attributes!
      }

      content_uri = "data:," + json.to_json
      result = described_class.extract(content_uri)

      expect(result[0]).to eq('collections'.b)
      expect(result[1]).to eq('edit_item'.b)

      # Decode the ABI data - now as tuple
      types = ['(bytes32,uint256,string,(string,string)[])']
      decoded_tuple = Eth::Abi.decode(types, result[2])
      decoded = decoded_tuple[0]

      expect(decoded[3]).to eq([])  # Empty attributes array!
    end

    it 'handles non-empty array with type hint' do
      json = {
        "p" => "collections",
        "op" => "edit_item",
        "attributes" => ["(string,string)[]", [
          {"trait_type" => "Color", "value" => "Red"},
          {"trait_type" => "Size", "value" => "Large"}
        ]]
      }

      content_uri = "data:," + json.to_json
      result = described_class.extract(content_uri)

      types = ['((string,string)[])']
      decoded_tuple = Eth::Abi.decode(types, result[2])
      decoded = decoded_tuple[0]

      expect(decoded[0]).to eq([
        ["Color", "Red"],
        ["Size", "Large"]
      ])
    end

    it 'handles uint256 array with type hint' do
      json = {
        "p" => "test",
        "op" => "numbers",
        "values" => ["uint256[]", [1, 2, 3, 4, 5]]
      }

      content_uri = "data:," + json.to_json
      result = described_class.extract(content_uri)

      types = ['(uint256[])']
      decoded_tuple = Eth::Abi.decode(types, result[2])
      decoded = decoded_tuple[0]

      expect(decoded[0]).to eq([1, 2, 3, 4, 5])
    end

    it 'handles empty uint256 array with type hint' do
      json = {
        "p" => "test",
        "op" => "empty_numbers",
        "values" => ["uint256[]", []]
      }

      content_uri = "data:," + json.to_json
      result = described_class.extract(content_uri)

      types = ['(uint256[])']
      decoded_tuple = Eth::Abi.decode(types, result[2])
      decoded = decoded_tuple[0]

      expect(decoded[0]).to eq([])
    end

    it 'handles address array with type hint' do
      json = {
        "p" => "test",
        "op" => "addresses",
        "recipients" => ["address[]", [
          "0x1234567890123456789012345678901234567890",
          "0xabcdefABCDEF1234567890123456789012345678"
        ]]
      }

      content_uri = "data:," + json.to_json
      result = described_class.extract(content_uri)
      
      types = ['(address[])']
      decoded_tuple = Eth::Abi.decode(types, result[2])
      decoded = decoded_tuple[0]

      expect(decoded[0]).to eq([
        "0x1234567890123456789012345678901234567890",
        "0xabcdefabcdef1234567890123456789012345678"  # Lowercase
      ])
    end

    it 'still works without type hints (backward compatible)' do
      json = {
        "p" => "collections",
        "op" => "edit_item",
        "name" => "Test",
        "attributes" => [
          {"trait_type" => "Color", "value" => "Blue"}
        ]
      }

      content_uri = "data:," + json.to_json
      result = described_class.extract(content_uri)

      types = ['(string,(string,string)[])']
      decoded_tuple = Eth::Abi.decode(types, result[2])
      decoded = decoded_tuple[0]

      expect(decoded[0]).to eq("Test")
      expect(decoded[1]).to eq([["Color", "Blue"]])
    end

    it 'rejects invalid type hints' do
      json = {
        "p" => "test",
        "op" => "bad",
        "data" => ["not_a_real_type", []]
      }

      content_uri = "data:," + json.to_json
      result = described_class.extract(content_uri)

      # Should treat as normal array, not type hint
      expect(result).to eq([''.b, ''.b, ''.b])
    end

    it 'validates type hint content' do
      json = {
        "p" => "test",
        "op" => "bad_uint",
        "values" => ["uint256[]", ["not a number"]]
      }

      content_uri = "data:," + json.to_json
      result = described_class.extract(content_uri)

      # Should fail validation and return default
      expect(result).to eq([''.b, ''.b, ''.b])
    end
  end

  describe 'mixed usage' do
    it 'handles mix of type hints and regular values' do
      json = {
        "p" => "complex",
        "op" => "mixed",
        "name" => "Regular String",  # No hint needed
        "count" => 42,                # No hint needed
        "tags" => ["string[]", ["tag1", "tag2"]],  # With hint
        "attributes" => ["(string,string)[]", []],  # Empty with hint
        "active" => true  # No hint needed
      }

      content_uri = "data:," + json.to_json
      result = described_class.extract(content_uri)

      types = ['(string,uint256,string[],(string,string)[],bool)']
      decoded_tuple = Eth::Abi.decode(types, result[2])
      decoded = decoded_tuple[0]

      expect(decoded[0]).to eq("Regular String")
      expect(decoded[1]).to eq(42)
      expect(decoded[2]).to eq(["tag1", "tag2"])
      expect(decoded[3]).to eq([])
      expect(decoded[4]).to eq(true)
    end
  end
end
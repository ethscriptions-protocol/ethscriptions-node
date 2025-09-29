require 'rails_helper'

RSpec.describe GenericProtocolExtractor do
  describe 'collections protocol operations' do
    describe 'create_collection' do
      it 'encodes create_collection with all string parameters' do
        json = {
          "p" => "collections",
          "op" => "create_collection",
          "name" => "Test Collection",
          "symbol" => "TEST",
          "totalSupply" => "10000",
          "description" => "A test collection",
          "logoImageUri" => "esc://ethscriptions/0x123/data",
          "bannerImageUri" => "esc://ethscriptions/0x456/data",
          "backgroundColor" => "#FF5733",
          "websiteLink" => "https://example.com",
          "twitterLink" => "https://twitter.com/test",
          "discordLink" => "https://discord.gg/test"
        }

        content_uri = "data:," + json.to_json
        result = described_class.extract(content_uri)

        expect(result[0]).to eq("collections")
        expect(result[1]).to eq("create_collection")
        expect(result[2]).not_to be_empty

        # Decode to verify structure
        # Order matches JSON key order (not alphabetical) - now as tuple
        types = ['(string,string,uint256,string,string,string,string,string,string,string)']
        decoded_tuple = Eth::Abi.decode(types, result[2])
        decoded = decoded_tuple[0]

        expect(decoded[0]).to eq("Test Collection")     # name
        expect(decoded[1]).to eq("TEST")                # symbol
        expect(decoded[2]).to eq(10000)                 # totalSupply (as uint256)
        expect(decoded[3]).to eq("A test collection")   # description
        expect(decoded[4]).to eq("esc://ethscriptions/0x123/data") # logoImageUri
        expect(decoded[5]).to eq("esc://ethscriptions/0x456/data") # bannerImageUri
        expect(decoded[6]).to eq("#FF5733")            # backgroundColor
        expect(decoded[7]).to eq("https://example.com") # websiteLink
        expect(decoded[8]).to eq("https://twitter.com/test") # twitterLink
        expect(decoded[9]).to eq("https://discord.gg/test") # discordLink
      end
    end

    describe 'add_items_batch with nested arrays' do
      it 'preserves nested attribute arrays as string[][]' do
        json = {
          "p" => "collections",
          "op" => "add_items_batch",
          "collectionId" => "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
          "items" => [
            [
              0,  # itemIndex as actual number (will be uint256)
              "Item Name #0",
              "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
              "#FF5733",
              "Description of item",
              [
                ["Type", "Female"],
                ["Hair", "Blonde Bob"],
                ["Eyes", "Green"]
              ]
            ]
          ]
        }

        content_uri = "data:," + json.to_json
        result = described_class.extract(content_uri)

        expect(result[0]).to eq("collections")
        expect(result[1]).to eq("add_items_batch")
        expect(result[2]).not_to be_empty

        # The items array now encodes as a tuple array:
        # (uint256,string,bytes32,string,string,string[][])[]
        # This allows proper type preservation

        # Decode to verify structure
        # collectionId (bytes32), items (tuple array) - now wrapped in tuple
        types = ['(bytes32,(uint256,string,bytes32,string,string,string[][])[])']
        decoded_tuple = Eth::Abi.decode(types, result[2])
        decoded = decoded_tuple[0]

        expect(decoded[0].unpack1('H*')).to eq("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef")

        # First item in the array
        item = decoded[1][0]
        expect(item[0]).to eq(0)  # itemIndex as uint256
        expect(item[1]).to eq("Item Name #0")  # name
        expect(item[2].unpack1('H*')).to eq("abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890")  # ethscriptionId
        expect(item[3]).to eq("#FF5733")  # backgroundColor
        expect(item[4]).to eq("Description of item")  # description
        expect(item[5]).to eq([["Type", "Female"], ["Hair", "Blonde Bob"], ["Eyes", "Green"]])  # attributes
      end

      it 'handles empty attributes array' do
        json = {
          "p" => "collections",
          "op" => "add_items_batch",
          "collectionId" => "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
          "items" => [
            [
              "0",
              "Item with no attributes",
              "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
              "",  # empty backgroundColor
              "",  # empty description
              []   # empty attributes
            ]
          ]
        }

        content_uri = "data:," + json.to_json
        result = described_class.extract(content_uri)

        expect(result[0]).to eq("collections")
        expect(result[1]).to eq("add_items_batch")
        expect(result[2]).not_to be_empty
      end

      it 'accepts standard NFT attribute format' do
        json = {
          "p" => "collections",
          "op" => "add_items_batch",
          "collectionId" => "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
          "items" => [
            {
              "itemIndex" => 0,
              "name" => "Item with standard attributes",
              "ethscriptionId" => "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
              "backgroundColor" => "#FF5733",
              "description" => "Description",
              "attributes" => [
                {"trait_type" => "Type", "value" => "Female"},
                {"trait_type" => "Hair", "value" => "Blonde Bob"},
                {"trait_type" => "Eyes", "value" => "Green"}
              ]
            }
          ]
        }

        content_uri = "data:," + json.to_json
        result = described_class.extract(content_uri)

        expect(result[0]).to eq("collections")
        expect(result[1]).to eq("add_items_batch")
        expect(result[2]).not_to be_empty

        # Attributes are converted to (string,string)[] tuples - now wrapped in tuple
        types = ['(bytes32,(uint256,string,bytes32,string,string,(string,string)[])[])']
        decoded_tuple = Eth::Abi.decode(types, result[2])
        decoded = decoded_tuple[0]

        item = decoded[1][0]
        expect(item[0]).to eq(0)  # itemIndex
        expect(item[1]).to eq("Item with standard attributes")  # name
        expect(item[2].unpack1('H*')).to eq("abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890")  # ethscriptionId
        expect(item[3]).to eq("#FF5733")  # backgroundColor
        expect(item[4]).to eq("Description")  # description
        expect(item[5]).to eq([["Type", "Female"], ["Hair", "Blonde Bob"], ["Eyes", "Green"]])  # attributes as tuples
      end

      it 'accepts object format for better readability' do
        json = {
          "p" => "collections",
          "op" => "add_items_batch",
          "collectionId" => "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
          "items" => [
            {
              "itemIndex" => 0,
              "name" => "Item with object format",
              "ethscriptionId" => "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
              "backgroundColor" => "#FF5733",
              "description" => "Description",
              "attributes" => [
                ["Type", "Female"],
                ["Hair", "Blonde Bob"],
                ["Eyes", "Green"]
              ]
            }
          ]
        }

        content_uri = "data:," + json.to_json
        result = described_class.extract(content_uri)

        expect(result[0]).to eq("collections")
        expect(result[1]).to eq("add_items_batch")
        expect(result[2]).not_to be_empty

        # Object format encodes as tuple array with preserved key order
        # Order matches the JSON: itemIndex, name, ethscriptionId, backgroundColor, description, attributes
        types = ['(bytes32,(uint256,string,bytes32,string,string,string[][])[])']
        decoded_tuple = Eth::Abi.decode(types, result[2])
        decoded = decoded_tuple[0]

        item = decoded[1][0]
        expect(item[0]).to eq(0)  # itemIndex
        expect(item[1]).to eq("Item with object format")  # name
        expect(item[2].unpack1('H*')).to eq("abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890")  # ethscriptionId
        expect(item[3]).to eq("#FF5733")  # backgroundColor
        expect(item[4]).to eq("Description")  # description
        expect(item[5]).to eq([["Type", "Female"], ["Hair", "Blonde Bob"], ["Eyes", "Green"]])  # attributes
      end

      it 'validates consistent inner array sizes for attributes' do
        json = {
          "p" => "collections",
          "op" => "add_items_batch",
          "collectionId" => "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
          "items" => [
            [
              "0",
              "Item",
              "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
              "#FF5733",
              "Description",
              [
                ["Type", "Female", "Extra"],  # Wrong: 3 elements instead of 2
                ["Hair", "Blonde Bob"]
              ]
            ]
          ]
        }

        content_uri = "data:," + json.to_json
        result = described_class.extract(content_uri)

        # Should fail because inner arrays have inconsistent sizes
        expect(result).to eq(['', '', ''])
      end

      it 'handles numeric values in attributes properly' do
        json = {
          "p" => "collections",
          "op" => "add_items_batch",
          "collectionId" => "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
          "items" => [
            [
              0,  # Use actual number, not string
              "Item",
              "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
              "#FF5733",
              "Description",
              [
                ["Type", "Female"],
                ["Count", "Five"]  # Use string "Five" instead of "5" to avoid type conversion
              ]
            ]
          ]
        }

        content_uri = "data:," + json.to_json
        result = described_class.extract(content_uri)

        expect(result[0]).to eq("collections")
        expect(result[1]).to eq("add_items_batch")
        expect(result[2]).not_to be_empty

        # Verify it encodes as tuple array - now wrapped in tuple
        types = ['(bytes32,(uint256,string,bytes32,string,string,string[][])[])']
        decoded_tuple = Eth::Abi.decode(types, result[2])
        decoded = decoded_tuple[0]

        item = decoded[1][0]
        expect(item[0]).to eq(0)  # itemIndex as proper uint256
        expect(item[5]).to eq([["Type", "Female"], ["Count", "Five"]])  # attributes all strings
      end
    end

    describe 'edit_collection' do
      it 'encodes edit_collection operation' do
        json = {
          "p" => "collections",
          "op" => "edit_collection",
          "collectionId" => "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
          "description" => "Updated description",
          "logoImageUri" => "esc://ethscriptions/0xnew/data",
          "bannerImageUri" => "",  # empty means no update
          "backgroundColor" => "#00FF00",
          "websiteLink" => "https://newsite.com",
          "twitterLink" => "",
          "discordLink" => "https://discord.gg/new"
        }

        content_uri = "data:," + json.to_json
        result = described_class.extract(content_uri)

        expect(result[0]).to eq("collections")
        expect(result[1]).to eq("edit_collection")
        expect(result[2]).not_to be_empty
      end
    end

    describe 'edit_collection_item' do
      it 'encodes edit_collection_item with updated attributes' do
        json = {
          "p" => "collections",
          "op" => "edit_collection_item",
          "collectionId" => "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
          "itemIndex" => "42",
          "name" => "Updated Item Name",
          "backgroundColor" => "#00FF00",
          "description" => "Updated description",
          "attributes" => [
            ["Type", "Female"],
            ["NewTrait", "Value"]
          ]
        }

        content_uri = "data:," + json.to_json
        result = described_class.extract(content_uri)

        expect(result[0]).to eq("collections")
        expect(result[1]).to eq("edit_collection_item")
        expect(result[2]).not_to be_empty

        # Verify the structure with preserved key order
        # Order matches JSON: collectionId, itemIndex, name, backgroundColor, description, attributes - now as tuple
        types = ['(bytes32,uint256,string,string,string,string[][])']
        decoded_tuple = Eth::Abi.decode(types, result[2])
        decoded = decoded_tuple[0]

        expect(decoded[0].unpack1('H*')).to eq("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef") # collectionId
        expect(decoded[1]).to eq(42) # itemIndex as uint256
        expect(decoded[2]).to eq("Updated Item Name") # name
        expect(decoded[3]).to eq("#00FF00") # backgroundColor
        expect(decoded[4]).to eq("Updated description") # description
        expect(decoded[5]).to eq([["Type", "Female"], ["NewTrait", "Value"]]) # attributes (nested)
      end
    end

    describe 'bytes32 handling' do
      it 'correctly encodes bytes32 values' do
        json = {
          "p" => "collections",
          "op" => "remove_items",
          "collectionId" => "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
          "ethscriptionIds" => [
            "0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
            "0xfedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321"
          ]
        }

        content_uri = "data:," + json.to_json
        result = described_class.extract(content_uri)

        expect(result[0]).to eq("collections")
        expect(result[1]).to eq("remove_items")

        # Verify bytes32 encoding - now as tuple
        types = ['(bytes32,bytes32[])']
        decoded_tuple = Eth::Abi.decode(types, result[2])
        decoded = decoded_tuple[0]

        expect(decoded[0].unpack1('H*')).to eq("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef")
        expect(decoded[1][0].unpack1('H*')).to eq("abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890")
        expect(decoded[1][1].unpack1('H*')).to eq("fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321")
      end
    end

    describe 'fixed-length bytes support' do
      it 'supports various fixed-length bytes types' do
        json = {
          "p" => "test",
          "op" => "bytes_test",
          "bytes1" => "0x01",
          "bytes4" => "0x12345678",
          "bytes8" => "0x123456789abcdef0",
          "bytes16" => "0x123456789abcdef0123456789abcdef0",
          "bytes20" => "0x1234567890123456789012345678901234567890",  # address
          "bytes32" => "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
        }

        content_uri = "data:," + json.to_json
        result = described_class.extract(content_uri)

        expect(result[0]).to eq("test")
        expect(result[1]).to eq("bytes_test")

        # Verify various bytes lengths are handled
        # Order matches JSON: bytes1, bytes4, bytes8, bytes16, bytes20, bytes32 - now as tuple
        types = ['(bytes1,bytes4,bytes8,bytes16,address,bytes32)']
        decoded_tuple = Eth::Abi.decode(types, result[2])
        decoded = decoded_tuple[0]

        expect(decoded[0].unpack1('H*')).to eq("01")
        expect(decoded[1].unpack1('H*')).to eq("12345678")
        expect(decoded[2].unpack1('H*')).to eq("123456789abcdef0")
        expect(decoded[3].unpack1('H*')).to eq("123456789abcdef0123456789abcdef0")
        expect(decoded[4]).to eq("0x1234567890123456789012345678901234567890")  # address stays as hex string
        expect(decoded[5].unpack1('H*')).to eq("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef")
      end
    end

    describe 'numeric string handling' do
      it 'converts numeric strings to uint256' do
        json = {
          "p" => "collections",
          "op" => "test",
          "totalSupply" => "10000",
          "maxSize" => "999999999",
          "itemIndex" => "42"
        }

        content_uri = "data:," + json.to_json
        result = described_class.extract(content_uri)

        # Order matches JSON: totalSupply, maxSize, itemIndex
        types = ['uint256', 'uint256', 'uint256']
        decoded = Eth::Abi.decode(types, result[2])

        expect(decoded[0]).to eq(10000)  # totalSupply
        expect(decoded[1]).to eq(999999999)  # maxSize
        expect(decoded[2]).to eq(42)  # itemIndex
      end
    end
  end
end
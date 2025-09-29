// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./TestSetup.sol";
import "../src/CollectionsManager.sol";
import "../src/protocols/EthscriptionERC721.sol";
import {LibString} from "solady/utils/LibString.sol";

contract CollectionsManagerTest is TestSetup {
    using LibString for *;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);
    address charlie = address(0xc0ffee);

    bytes32 constant COLLECTION_TX_HASH = bytes32(uint256(0x1234));
    bytes32 constant ITEM1_TX_HASH = bytes32(uint256(0x5678));
    bytes32 constant ITEM2_TX_HASH = bytes32(uint256(0x9ABC));
    bytes32 constant ITEM3_TX_HASH = bytes32(uint256(0xDEF0));

    function setUp() public override {
        super.setUp();
    }

    function testCreateCollection() public {
        // Create a collection as Alice
        vm.prank(alice);

        string memory collectionContent = 'data:,{"p":"collections","op":"create_collection","name":"Test Collection","symbol":"TEST","total_supply":"100"}';

        CollectionsManager.CollectionMetadata memory metadata = CollectionsManager.CollectionMetadata({
            name: "Test Collection",
            symbol: "TEST",
            totalSupply: 100,
            description: "A test collection for unit tests",
            logoImageUri: "esc://ethscriptions/0x123/data",
            bannerImageUri: "esc://ethscriptions/0x456/data",
            backgroundColor: "#FF5733",
            websiteLink: "https://example.com",
            twitterLink: "https://twitter.com/test",
            discordLink: "https://discord.gg/test"
        });

        Ethscriptions.CreateEthscriptionParams memory params = Ethscriptions.CreateEthscriptionParams({
            transactionHash: COLLECTION_TX_HASH,
            contentUriHash: sha256(bytes(collectionContent)),
            initialOwner: alice,
            content: bytes(collectionContent),
            mimetype: "application/json",
            mediaType: "application",
            mimeSubtype: "json",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "create_collection",
                data: abi.encode(metadata)
            })
        });

        ethscriptions.createEthscription(params);

        // Verify collection was created
        address collectionAddress = collectionsManager.getCollectionAddress(COLLECTION_TX_HASH);
        assertTrue(collectionAddress != address(0));

        EthscriptionERC721 collection = EthscriptionERC721(collectionAddress);
        assertEq(collection.name(), "Test Collection");
        assertEq(collection.symbol(), "TEST");
        // Collection owner is tracked through the original ethscription ownership

        // Verify metadata was stored
        CollectionsManager.CollectionMetadata memory storedMetadata = collectionsManager.getCollectionMetadata(COLLECTION_TX_HASH);
        assertEq(storedMetadata.name, "Test Collection");
        assertEq(storedMetadata.symbol, "TEST");
        assertEq(storedMetadata.totalSupply, 100);
        assertEq(storedMetadata.description, "A test collection for unit tests");
        assertEq(storedMetadata.backgroundColor, "#FF5733");
    }

    function testAddToCollection() public {
        // First create a collection
        testCreateCollection();

        address collectionAddress = collectionsManager.getCollectionAddress(COLLECTION_TX_HASH);
        EthscriptionERC721 collection = EthscriptionERC721(collectionAddress);

        // Create an ethscription to add to the collection
        vm.prank(alice);

        string memory itemContent = 'data:,{"p":"collections","op":"add","collection":"0x1234","item":"artwork1"}';

        bytes32[] memory items = new bytes32[](1);
        items[0] = ITEM1_TX_HASH;

        // Create item data with attributes
        CollectionsManager.ItemData[] memory itemsData = new CollectionsManager.ItemData[](1);

        CollectionsManager.Attribute[] memory attributes = new CollectionsManager.Attribute[](3);
        attributes[0] = CollectionsManager.Attribute({
            traitType: "Type",
            value: "Artwork"
        });
        attributes[1] = CollectionsManager.Attribute({
            traitType: "Rarity",
            value: "Common"
        });
        attributes[2] = CollectionsManager.Attribute({
            traitType: "Color",
            value: "Blue"
        });

        itemsData[0] = CollectionsManager.ItemData({
            itemIndex: 0,
            name: "Test Item #0",
            ethscriptionId: ITEM1_TX_HASH,
            backgroundColor: "#0000FF",
            description: "First test item",
            attributes: attributes
        });

        CollectionsManager.AddItemsBatchOperation memory addOp = CollectionsManager.AddItemsBatchOperation({
            collectionId: COLLECTION_TX_HASH,
            items: itemsData
        });

        Ethscriptions.CreateEthscriptionParams memory itemParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: ITEM1_TX_HASH,
            contentUriHash: sha256(bytes(itemContent)),
            initialOwner: alice,
            content: bytes(itemContent),
            mimetype: "application/json",
            mediaType: "application",
            mimeSubtype: "json",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "add_items_batch",
                data: abi.encode(addOp)
            })
        });

        vm.prank(alice);
        ethscriptions.createEthscription(itemParams);

        // Verify item was added with metadata
        CollectionsManager.CollectionItem memory item = collectionsManager.getCollectionItem(COLLECTION_TX_HASH, 0);
        assertEq(item.name, "Test Item #0");
        assertEq(item.ethscriptionId, ITEM1_TX_HASH);
        assertEq(item.backgroundColor, "#0000FF");
        assertEq(item.description, "First test item");
        assertEq(item.attributes.length, 3);
        assertEq(item.attributes[0].traitType, "Type");
        assertEq(item.attributes[0].value, "Artwork");
        assertEq(item.attributes[1].traitType, "Rarity");
        assertEq(item.attributes[1].value, "Common");
        assertEq(item.attributes[2].traitType, "Color");
        assertEq(item.attributes[2].value, "Blue");

        // Verify item was added to collection
        // Token ID is the item index (0 for the first item)
        uint256 tokenId = 0;
        assertEq(collection.ownerOf(tokenId), alice);
        // Verify item is in collection via CollectionsManager
        CollectionsManager.CollectionItem memory item2 = collectionsManager.getCollectionItem(COLLECTION_TX_HASH, tokenId);
        assertEq(item2.ethscriptionId, ITEM1_TX_HASH);
    }

    function testTransferCollectionItem() public {
        // Setup: Create collection and add item
        testAddToCollection();

        address collectionAddress = collectionsManager.getCollectionAddress(COLLECTION_TX_HASH);
        EthscriptionERC721 collection = EthscriptionERC721(collectionAddress);

        // Transfer the ethscription NFT
        vm.prank(alice);
        ethscriptions.transferEthscription(bob, ITEM1_TX_HASH);

        // Verify ownership synced in collection
        // Token ID is the item index (0 for the first item)
        uint256 tokenId = 0;
        assertEq(collection.ownerOf(tokenId), bob);
    }

    function testBurnCollectionItem() public {
        // Setup: Create collection and add item
        testAddToCollection();

        address collectionAddress = collectionsManager.getCollectionAddress(COLLECTION_TX_HASH);
        EthscriptionERC721 collection = EthscriptionERC721(collectionAddress);

        // Burn the ethscription (transfer to address(0))
        vm.prank(alice);
        ethscriptions.transferEthscription(address(0), ITEM1_TX_HASH);

        // Verify item is still in collection but owned by address(0)
        // Token ID is the item index (0 for the first item)
        uint256 tokenId = 0;
        assertEq(collection.ownerOf(tokenId), address(0));
    }

    function testRemoveFromCollection() public {
        // Setup: Create collection and add item
        testAddToCollection();

        address collectionAddress = collectionsManager.getCollectionAddress(COLLECTION_TX_HASH);
        EthscriptionERC721 collection = EthscriptionERC721(collectionAddress);

        // Remove item from collection (only collection owner can do this)
        vm.prank(alice);

        string memory removeContent = 'data:,{"p":"collections","op":"remove","collection":"0x1234","item":"0x5678"}';

        bytes32[] memory itemsToRemove = new bytes32[](1);
        itemsToRemove[0] = ITEM1_TX_HASH;

        CollectionsManager.RemoveItemsOperation memory removeOp = CollectionsManager.RemoveItemsOperation({
            collectionId: COLLECTION_TX_HASH,
            ethscriptionIds: itemsToRemove
        });

        Ethscriptions.CreateEthscriptionParams memory removeParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0xFEED)),
            contentUriHash: sha256(bytes(removeContent)),
            initialOwner: alice,
            content: bytes(removeContent),
            mimetype: "application/json",
            mediaType: "application",
            mimeSubtype: "json",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "remove_items",
                data: abi.encode(removeOp)
            })
        });

        vm.prank(alice);
        ethscriptions.createEthscription(removeParams);

        // Verify item was removed - token should no longer exist
        uint256 tokenId = 0;
        vm.expectRevert("Token does not exist");
        collection.ownerOf(tokenId);
    }

    function testOnlyOwnerCanRemove() public {
        // Setup: Create collection and add item
        testAddToCollection();

        address collectionAddress = collectionsManager.getCollectionAddress(COLLECTION_TX_HASH);
        EthscriptionERC721 collection = EthscriptionERC721(collectionAddress);

        // Try to remove item as non-owner (should fail silently)
        vm.prank(bob);

        bytes32[] memory itemsToRemove = new bytes32[](1);
        itemsToRemove[0] = ITEM1_TX_HASH;

        CollectionsManager.RemoveItemsOperation memory removeOp = CollectionsManager.RemoveItemsOperation({
            collectionId: COLLECTION_TX_HASH,
            ethscriptionIds: itemsToRemove
        });

        Ethscriptions.CreateEthscriptionParams memory removeParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0xBAD)),
            contentUriHash: sha256(bytes("data:,remove")),
            initialOwner: bob,
            content: bytes("remove"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "remove_items",
                data: abi.encode(removeOp)
            })
        });

        vm.prank(bob);
        ethscriptions.createEthscription(removeParams);

        // Verify item is still in collection (remove failed)
        // Token ID is the item index (0 for the first item)
        uint256 tokenId = 0;
        assertEq(collection.ownerOf(tokenId), alice);
    }

    function testMultipleItemsInCollection() public {
        // Create collection
        testCreateCollection();

        address collectionAddress = collectionsManager.getCollectionAddress(COLLECTION_TX_HASH);
        EthscriptionERC721 collection = EthscriptionERC721(collectionAddress);

        // Add multiple items
        bytes32[3] memory itemHashes = [ITEM1_TX_HASH, ITEM2_TX_HASH, ITEM3_TX_HASH];
        address[3] memory owners = [alice, bob, charlie];

        for (uint i = 0; i < 3; i++) {
            vm.prank(alice);

            // Create item data for the batch add
            CollectionsManager.ItemData[] memory itemsData = new CollectionsManager.ItemData[](1);

            CollectionsManager.Attribute[] memory attributes = new CollectionsManager.Attribute[](1);
            attributes[0] = CollectionsManager.Attribute({
                traitType: "Type",
                value: "Test"
            });

            string memory itemName = i == 0 ? "Item #0" : i == 1 ? "Item #1" : "Item #2";

            itemsData[0] = CollectionsManager.ItemData({
                itemIndex: uint256(i),
                name: itemName,
                ethscriptionId: itemHashes[i],
                backgroundColor: "#000000",
                description: "Test item",
                attributes: attributes
            });

            CollectionsManager.AddItemsBatchOperation memory addOp = CollectionsManager.AddItemsBatchOperation({
                collectionId: COLLECTION_TX_HASH,
                items: itemsData
            });

            Ethscriptions.CreateEthscriptionParams memory itemParams = Ethscriptions.CreateEthscriptionParams({
                transactionHash: itemHashes[i],
                contentUriHash: sha256(abi.encodePacked("item", i)),
                initialOwner: owners[i],
                content: abi.encodePacked("item", i),
                mimetype: "text/plain",
                mediaType: "text",
                mimeSubtype: "plain",
                esip6: false,
                protocolParams: Ethscriptions.ProtocolParams({
                    protocol: "collections",
                    operation: "add_items_batch",
                    data: abi.encode(addOp)
                })
            });

            vm.prank(alice);
            ethscriptions.createEthscription(itemParams);
        }

        // Verify all items are in collection with correct owners
        for (uint i = 0; i < 3; i++) {
            uint256 tokenId = uint256(i); // Token ID matches the item index
            assertEq(collection.ownerOf(tokenId), owners[i]);
        }

        // Collection has 3 items
    }

    function testTokenURIGeneration() public {
        // First create a collection with metadata
        testCreateCollection();

        address collectionAddress = collectionsManager.getCollectionAddress(COLLECTION_TX_HASH);
        EthscriptionERC721 collection = EthscriptionERC721(collectionAddress);

        // Create an ethscription with image content to add
        vm.prank(alice);

        string memory imageContent = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

        // Create item data with attributes
        CollectionsManager.ItemData[] memory itemsData = new CollectionsManager.ItemData[](1);

        CollectionsManager.Attribute[] memory attributes = new CollectionsManager.Attribute[](4);
        attributes[0] = CollectionsManager.Attribute({
            traitType: "Type",
            value: "Female"
        });
        attributes[1] = CollectionsManager.Attribute({
            traitType: "Hair",
            value: "Blonde Bob"
        });
        attributes[2] = CollectionsManager.Attribute({
            traitType: "Eyes",
            value: "Green Eye Shadow"
        });
        attributes[3] = CollectionsManager.Attribute({
            traitType: "Rarity",
            value: "Rare"
        });

        itemsData[0] = CollectionsManager.ItemData({
            itemIndex: 0,
            name: "Ittybit #0000",
            ethscriptionId: ITEM1_TX_HASH,
            backgroundColor: "#648595",
            description: "A rare ittybit with green eye shadow",
            attributes: attributes
        });

        CollectionsManager.AddItemsBatchOperation memory addOp = CollectionsManager.AddItemsBatchOperation({
            collectionId: COLLECTION_TX_HASH,
            items: itemsData
        });

        // Create the ethscription with image content
        Ethscriptions.CreateEthscriptionParams memory itemParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: ITEM1_TX_HASH,
            contentUriHash: sha256(bytes(imageContent)),
            initialOwner: alice,
            content: bytes(imageContent),
            mimetype: "image/png",
            mediaType: "image",
            mimeSubtype: "png",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "add_items_batch",
                data: abi.encode(addOp)
            })
        });

        vm.prank(alice);
        ethscriptions.createEthscription(itemParams);

        // Get the token URI and verify it contains the expected data
        // Get tokenId from CollectionsManager (it should be 0)
        uint256 tokenId = 0;
        string memory tokenUri = collection.tokenURI(tokenId);

        // The URI should be a base64-encoded JSON data URI
        assertTrue(bytes(tokenUri).length > 0);
        // Should start with data:application/json;base64,
        assertTrue(LibString.startsWith(tokenUri, "data:application/json;base64,"));

        // Verify the item metadata was stored correctly
        CollectionsManager.CollectionItem memory item = collectionsManager.getCollectionItem(COLLECTION_TX_HASH, 0);
        assertEq(item.name, "Ittybit #0000");
        assertEq(item.backgroundColor, "#648595");
        assertEq(item.attributes.length, 4);
        assertEq(item.attributes[1].traitType, "Hair");
        assertEq(item.attributes[1].value, "Blonde Bob");
    }

    function testCollectionAddressIsPredictable() public {
        // Predict the collection address before deployment
        address predictedAddress = collectionsManager.predictCollectionAddress(COLLECTION_TX_HASH);

        // Create the collection
        testCreateCollection();

        // Verify the actual address matches prediction
        address actualAddress = collectionsManager.getCollectionAddress(COLLECTION_TX_HASH);
        assertEq(actualAddress, predictedAddress);
    }

    function testEditCollectionItem() public {
        // Setup: Create collection and add item
        testAddToCollection();

        // Edit item 0 - update name, description, and attributes
        vm.prank(alice);

        CollectionsManager.Attribute[] memory newAttributes = new CollectionsManager.Attribute[](3);
        newAttributes[0] = CollectionsManager.Attribute({traitType: "Color", value: "Blue"});
        newAttributes[1] = CollectionsManager.Attribute({traitType: "Size", value: "Large"});
        newAttributes[2] = CollectionsManager.Attribute({traitType: "Rarity", value: "Epic"});

        CollectionsManager.EditCollectionItemOperation memory editOp = CollectionsManager.EditCollectionItemOperation({
            collectionId: COLLECTION_TX_HASH,
            itemIndex: 0,
            name: "Updated Item Name",
            backgroundColor: "#0000FF",
            description: "This item has been updated",
            attributes: newAttributes
        });

        Ethscriptions.CreateEthscriptionParams memory editParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0xED171)),
            contentUriHash: sha256(bytes("edit")),
            initialOwner: alice,
            content: bytes("edit"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "edit_collection_item",
                data: abi.encode(editOp)
            })
        });

        vm.prank(alice);
        ethscriptions.createEthscription(editParams);

        // Verify item was updated
        CollectionsManager.CollectionItem memory item = collectionsManager.getCollectionItem(COLLECTION_TX_HASH, 0);
        assertEq(item.name, "Updated Item Name");
        assertEq(item.backgroundColor, "#0000FF");
        assertEq(item.description, "This item has been updated");
        assertEq(item.attributes.length, 3);
        assertEq(item.attributes[0].traitType, "Color");
        assertEq(item.attributes[0].value, "Blue");
        assertEq(item.attributes[1].traitType, "Size");
        assertEq(item.attributes[1].value, "Large");
        assertEq(item.attributes[2].traitType, "Rarity");
        assertEq(item.attributes[2].value, "Epic");
    }

    function testEditCollectionItemPartialUpdate() public {
        // Setup: Create collection and add item with attributes
        testCreateCollection();

        // First create the ethscription that we'll add to the collection
        vm.prank(alice);
        Ethscriptions.CreateEthscriptionParams memory itemCreationParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: ITEM1_TX_HASH,
            contentUriHash: sha256(bytes("item content")),
            initialOwner: alice,
            content: bytes("item content"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "",
                operation: "",
                data: ""
            })
        });
        ethscriptions.createEthscription(itemCreationParams);

        // Now add item with attributes
        vm.prank(alice);
        CollectionsManager.Attribute[] memory attributes = new CollectionsManager.Attribute[](2);
        attributes[0] = CollectionsManager.Attribute({traitType: "Hair Color", value: "Brown"});
        attributes[1] = CollectionsManager.Attribute({traitType: "Hair", value: "Blonde Bob"});

        CollectionsManager.ItemData[] memory items = new CollectionsManager.ItemData[](1);
        items[0] = CollectionsManager.ItemData({
            itemIndex: 0,
            name: "Test Item #0",
            ethscriptionId: ITEM1_TX_HASH,
            backgroundColor: "#FF5733",
            description: "First item description",
            attributes: attributes
        });

        CollectionsManager.AddItemsBatchOperation memory addOp = CollectionsManager.AddItemsBatchOperation({
            collectionId: COLLECTION_TX_HASH,
            items: items
        });

        Ethscriptions.CreateEthscriptionParams memory addParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0xADD1733)),
            contentUriHash: sha256(bytes("add")),
            initialOwner: alice,
            content: bytes("add"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "add_items_batch",
                data: abi.encode(addOp)
            })
        });

        vm.prank(alice);
        ethscriptions.createEthscription(addParams);

        // Edit item 0 - only update name and description, keep existing attributes
        vm.prank(alice);

        CollectionsManager.EditCollectionItemOperation memory editOp = CollectionsManager.EditCollectionItemOperation({
            collectionId: COLLECTION_TX_HASH,
            itemIndex: 0,
            name: "Partially Updated",
            backgroundColor: "", // Empty string - don't update
            description: "Only name and description changed",
            attributes: new CollectionsManager.Attribute[](0) // Empty array - keep existing
        });

        Ethscriptions.CreateEthscriptionParams memory editParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0xED172)),
            contentUriHash: sha256(bytes("partial-edit")),
            initialOwner: alice,
            content: bytes("partial-edit"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "edit_collection_item",
                data: abi.encode(editOp)
            })
        });

        vm.prank(alice);
        ethscriptions.createEthscription(editParams);

        // Verify partial update
        CollectionsManager.CollectionItem memory item = collectionsManager.getCollectionItem(COLLECTION_TX_HASH, 0);
        assertEq(item.name, "Partially Updated");
        assertEq(item.description, "Only name and description changed");
        assertEq(item.backgroundColor, "#FF5733"); // Original value preserved
        assertEq(item.attributes.length, 2); // Original attributes preserved
        assertEq(item.attributes[0].traitType, "Hair Color");
        assertEq(item.attributes[0].value, "Brown");
    }

    function testOnlyOwnerCanEditItem() public {
        // Setup: Create collection and add item
        testAddToCollection();

        // Try to edit item as non-owner (should revert)
        vm.prank(bob);

        CollectionsManager.EditCollectionItemOperation memory editOp = CollectionsManager.EditCollectionItemOperation({
            collectionId: COLLECTION_TX_HASH,
            itemIndex: 0,
            name: "Unauthorized Edit",
            backgroundColor: "#000000",
            description: "This should not work",
            attributes: new CollectionsManager.Attribute[](0)
        });

        Ethscriptions.CreateEthscriptionParams memory editParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0xBADED17)),
            contentUriHash: sha256(bytes("bad-edit")),
            initialOwner: bob,
            content: bytes("bad-edit"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "edit_collection_item",
                data: abi.encode(editOp)
            })
        });

        vm.prank(bob);
        ethscriptions.createEthscription(editParams);

        // Verify item was not changed
        CollectionsManager.CollectionItem memory item = collectionsManager.getCollectionItem(COLLECTION_TX_HASH, 0);
        assertEq(item.name, "Test Item #0"); // Original name preserved
    }

    function testEditNonExistentItem() public {
        // Setup: Create collection
        testCreateCollection();

        // Try to edit non-existent item (should revert)
        vm.prank(alice);

        CollectionsManager.EditCollectionItemOperation memory editOp = CollectionsManager.EditCollectionItemOperation({
            collectionId: COLLECTION_TX_HASH,
            itemIndex: 999, // Non-existent index
            name: "Should Fail",
            backgroundColor: "#000000",
            description: "This item doesn't exist",
            attributes: new CollectionsManager.Attribute[](0)
        });

        Ethscriptions.CreateEthscriptionParams memory editParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0x901743)),
            contentUriHash: sha256(bytes("no-item")),
            initialOwner: alice,
            content: bytes("no-item"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "edit_collection_item",
                data: abi.encode(editOp)
            })
        });

        vm.prank(alice);
        ethscriptions.createEthscription(editParams);

        // The operation should fail silently (no revert in createEthscription)
        // Verify by checking that getting the item returns default values
        CollectionsManager.CollectionItem memory item = collectionsManager.getCollectionItem(COLLECTION_TX_HASH, 999);
        assertEq(item.ethscriptionId, bytes32(0)); // Default value for non-existent item
    }

    function testSyncOwnership() public {
        // Setup: Create collection and add items
        testAddToCollection();

        // Get the collection contract
        address collectionAddress = collectionsManager.getCollectionAddress(COLLECTION_TX_HASH);
        EthscriptionERC721 collection = EthscriptionERC721(collectionAddress);

        // Initially Alice owns the token
        assertEq(collection.ownerOf(0), alice);

        // Now transfer the underlying ethscription to Bob (simulating a transfer outside the ERC721)
        // We need to mock this transfer in the Ethscriptions contract
        vm.prank(alice);
        ethscriptions.transferEthscription(bob, ITEM1_TX_HASH);

        // Verify the ethscription is now owned by Bob
        // Note: ERC721's ownerOf always returns the current ethscription owner
        assertEq(ethscriptions.ownerOf(ITEM1_TX_HASH), bob);
        assertEq(collection.ownerOf(0), bob); // Immediately reflects the new owner

        // Now sync the ownership
        vm.prank(charlie); // Anyone can trigger sync
        bytes32[] memory ethscriptionIds = new bytes32[](1);
        ethscriptionIds[0] = ITEM1_TX_HASH;

        Ethscriptions.CreateEthscriptionParams memory syncParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0x5914C)),
            contentUriHash: sha256(bytes("sync")),
            initialOwner: charlie,
            content: bytes("sync"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "sync_ownership",
                data: abi.encode(COLLECTION_TX_HASH, ethscriptionIds)
            })
        });

        vm.prank(charlie);
        ethscriptions.createEthscription(syncParams);

        // Verify the ERC721 ownership is now synced
        assertEq(collection.ownerOf(0), bob);
    }

    function testSyncOwnershipMultipleItems() public {
        // Setup: Create collection with multiple items
        testMultipleItemsInCollection();

        address collectionAddress = collectionsManager.getCollectionAddress(COLLECTION_TX_HASH);
        EthscriptionERC721 collection = EthscriptionERC721(collectionAddress);

        // Transfer multiple ethscriptions to different owners
        vm.prank(alice);
        ethscriptions.transferEthscription(charlie, ITEM1_TX_HASH);

        vm.prank(bob);
        ethscriptions.transferEthscription(alice, ITEM2_TX_HASH);

        // Verify ethscriptions have new owners
        // Note: ERC721's ownerOf always returns the current ethscription owner
        assertEq(ethscriptions.ownerOf(ITEM1_TX_HASH), charlie);
        assertEq(ethscriptions.ownerOf(ITEM2_TX_HASH), alice);
        assertEq(collection.ownerOf(0), charlie); // Immediately reflects new owner
        assertEq(collection.ownerOf(1), alice);   // Immediately reflects new owner

        // Sync multiple items at once
        bytes32[] memory ethscriptionIds = new bytes32[](2);
        ethscriptionIds[0] = ITEM1_TX_HASH;
        ethscriptionIds[1] = ITEM2_TX_HASH;

        Ethscriptions.CreateEthscriptionParams memory syncParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0x5914CD)),
            contentUriHash: sha256(bytes("sync-multi")),
            initialOwner: alice,
            content: bytes("sync-multi"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "sync_ownership",
                data: abi.encode(COLLECTION_TX_HASH, ethscriptionIds)
            })
        });

        vm.prank(alice);
        ethscriptions.createEthscription(syncParams);

        // Verify all ownerships are now synced
        assertEq(collection.ownerOf(0), charlie);
        assertEq(collection.ownerOf(1), alice);
    }

    function testSyncOwnershipNonExistentItem() public {
        // Setup: Create collection
        testCreateCollection();

        // Try to sync an ethscription that's not in the collection
        bytes32[] memory ethscriptionIds = new bytes32[](1);
        ethscriptionIds[0] = bytes32(uint256(0x999999)); // Non-existent in collection

        Ethscriptions.CreateEthscriptionParams memory syncParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0x5914CE)),
            contentUriHash: sha256(bytes("sync-nonexistent")),
            initialOwner: alice,
            content: bytes("sync-nonexistent"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "sync_ownership",
                data: abi.encode(COLLECTION_TX_HASH, ethscriptionIds)
            })
        });

        vm.prank(alice);
        ethscriptions.createEthscription(syncParams);

        // Should complete without error (non-existent items are skipped)
        // No assertion needed - just verifying no revert
    }

    function testSyncOwnershipNonExistentCollection() public {
        bytes32 fakeCollectionId = bytes32(uint256(0xFABE));
        bytes32[] memory ethscriptionIds = new bytes32[](1);
        ethscriptionIds[0] = ITEM1_TX_HASH;

        Ethscriptions.CreateEthscriptionParams memory syncParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0x5914CF)),
            contentUriHash: sha256(bytes("sync-fake")),
            initialOwner: alice,
            content: bytes("sync-fake"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "sync_ownership",
                data: abi.encode(fakeCollectionId, ethscriptionIds)
            })
        });

        vm.prank(alice);
        ethscriptions.createEthscription(syncParams);

        // The operation should fail silently (protocol handler catches the require)
        // No assertion needed - just verifying completion
    }

    function testEditLockedCollection() public {
        // Setup: Create collection and add item
        testAddToCollection();

        // Lock the collection
        vm.prank(alice);

        Ethscriptions.CreateEthscriptionParams memory lockParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0x10CCC)),
            contentUriHash: sha256(bytes("lock")),
            initialOwner: alice,
            content: bytes("lock"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "lock_collection",
                data: abi.encode(COLLECTION_TX_HASH)
            })
        });

        vm.prank(alice);
        ethscriptions.createEthscription(lockParams);

        // Try to edit item in locked collection (should fail)
        vm.prank(alice);

        CollectionsManager.EditCollectionItemOperation memory editOp = CollectionsManager.EditCollectionItemOperation({
            collectionId: COLLECTION_TX_HASH,
            itemIndex: 0,
            name: "Should not update",
            backgroundColor: "#000000",
            description: "Collection is locked",
            attributes: new CollectionsManager.Attribute[](0)
        });

        Ethscriptions.CreateEthscriptionParams memory editParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0x10C3ED)),
            contentUriHash: sha256(bytes("locked-edit")),
            initialOwner: alice,
            content: bytes("locked-edit"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "collections",
                operation: "edit_collection_item",
                data: abi.encode(editOp)
            })
        });

        vm.prank(alice);
        ethscriptions.createEthscription(editParams);

        // Verify item was not changed
        CollectionsManager.CollectionItem memory item = collectionsManager.getCollectionItem(COLLECTION_TX_HASH, 0);
        assertEq(item.name, "Test Item #0"); // Original name preserved
    }
}
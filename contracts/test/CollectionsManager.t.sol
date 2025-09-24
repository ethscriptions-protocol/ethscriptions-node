// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./TestSetup.sol";
import "../src/CollectionsManager.sol";
import "../src/protocols/EthscriptionERC721.sol";

contract CollectionsManagerTest is TestSetup {
    address alice = address(0x1);
    address bob = address(0x2);
    address charlie = address(0x3);

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

        string memory collectionContent = 'data:,{"p":"collections","op":"create_collection","name":"Test Collection","symbol":"TEST","max_supply":"100"}';

        CollectionsManager.CreateCollectionOperation memory createOp = CollectionsManager.CreateCollectionOperation({
            name: "Test Collection",
            symbol: "TEST",
            maxSize: 100,
            baseUri: "https://example.com/metadata/"
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
                data: abi.encode(createOp)
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

        CollectionsManager.AddItemsOperation memory addOp = CollectionsManager.AddItemsOperation({
            collectionId: COLLECTION_TX_HASH,
            ethscriptionIds: items
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
                operation: "add_items",
                data: abi.encode(addOp)
            })
        });

        ethscriptions.createEthscription(itemParams);

        // Verify item was added to collection
        uint256 tokenId = collection.ethscriptionToToken(ITEM1_TX_HASH);
        assertTrue(tokenId != 0);
        assertEq(collection.ownerOf(tokenId), alice);
        assertEq(collection.tokenToEthscription(tokenId), ITEM1_TX_HASH);
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
        uint256 tokenId = collection.ethscriptionToToken(ITEM1_TX_HASH);
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
        uint256 tokenId = collection.ethscriptionToToken(ITEM1_TX_HASH);
        assertTrue(tokenId != 0); // Still has a token ID
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

        ethscriptions.createEthscription(removeParams);

        // Verify item was removed from collection
        uint256 tokenId = collection.ethscriptionToToken(ITEM1_TX_HASH);
        assertEq(tokenId, 0);
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

        ethscriptions.createEthscription(removeParams);

        // Verify item is still in collection (remove failed)
        uint256 tokenId = collection.ethscriptionToToken(ITEM1_TX_HASH);
        assertTrue(tokenId != 0);
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

            bytes32[] memory items = new bytes32[](1);
            items[0] = itemHashes[i];

            CollectionsManager.AddItemsOperation memory addOp = CollectionsManager.AddItemsOperation({
                collectionId: COLLECTION_TX_HASH,
                ethscriptionIds: items
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
                    operation: "add",
                    data: abi.encode(addOp)
                })
            });

            ethscriptions.createEthscription(itemParams);
        }

        // Verify all items are in collection with correct owners
        for (uint i = 0; i < 3; i++) {
            uint256 tokenId = collection.ethscriptionToToken(itemHashes[i]);
            assertTrue(tokenId != 0);
            assertEq(collection.ownerOf(tokenId), owners[i]);
        }

        // Collection has 3 items
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
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";
import {LibString} from "solady/utils/LibString.sol";
import "./EthscriptionERC721.sol";
import "./Ethscriptions.sol";
import "./libraries/Predeploys.sol";
import "./interfaces/IProtocolHandler.sol";

contract CollectionsManager is IProtocolHandler {
    using Clones for address;
    using LibString for string;

    // Standard NFT attribute structure
    struct Attribute {
        string traitType;
        string value;
    }


    // Core collection metadata fields (reused across create/edit/storage)
    struct CollectionMetadata {
        string name;
        string symbol;
        uint256 totalSupply;
        string description;
        string logoImageUri;
        string bannerImageUri;
        string backgroundColor;
        string websiteLink;
        string twitterLink;
        string discordLink;
    }

    // Runtime state for a collection (separate from metadata)
    struct CollectionState {
        address collectionContract;
        bytes32 createTxHash;
        uint256 currentSize;
        bool locked;
    }

    struct CollectionItem {
        uint256 itemIndex;
        string name;
        bytes32 ethscriptionId;
        string backgroundColor;
        string description;
        Attribute[] attributes;   // Standard NFT attribute format
    }

    // Removed CollectionItem struct - now using nested mapping for multi-collection support

    // Protocol operation structs - reuse CollectionMetadata
    // For create, we just decode directly into CollectionMetadata

    struct AddItemsBatchOperation {
        bytes32 collectionId;
        ItemData[] items;
    }

    struct ItemData {
        uint256 itemIndex;       // Proper uint256, no parsing needed
        string name;
        bytes32 ethscriptionId;
        string backgroundColor;
        string description;
        Attribute[] attributes;  // Standard NFT attribute format
    }

    struct RemoveItemsOperation {
        bytes32 collectionId;
        bytes32[] ethscriptionIds;
    }

    struct EditCollectionOperation {
        bytes32 collectionId;
        // Flattened metadata fields (totalSupply excluded as it's not editable)
        string description;
        string logoImageUri;
        string bannerImageUri;
        string backgroundColor;
        string websiteLink;
        string twitterLink;
        string discordLink;
    }

    struct EditCollectionItemOperation {
        bytes32 collectionId;
        uint256 itemIndex;       // Index of the item to edit
        string name;
        string backgroundColor;
        string description;
        Attribute[] attributes;   // If non-empty, replaces all attributes. If empty, keeps existing.
        // Note: Similar to ItemData but without ethscriptionId (can't change)
    }

    address public constant erc721Template = Predeploys.ERC721_TEMPLATE_IMPLEMENTATION;
    address public constant ethscriptions = Predeploys.ETHSCRIPTIONS;

    // Track deployed collections by ID
    mapping(bytes32 => CollectionState) public collectionState;  // Runtime state (contract address, size, locked)

    // Metadata storage
    mapping(bytes32 => CollectionMetadata) public collectionMetadata;  // Descriptive metadata
    mapping(bytes32 => mapping(uint256 => CollectionItem)) public collectionItems;
    // Maps ethscription to index+1 (so 0 means not in collection, 1 means index 0, etc)
    mapping(bytes32 => mapping(bytes32 => uint256)) public ethscriptionToIndexPlusOne;

    // Array of all collection IDs for enumeration
    bytes32[] public collectionIds;

    event CollectionCreated(
        bytes32 indexed collectionId,
        address indexed collectionContract,
        string name,
        string symbol,
        uint256 maxSize
    );

    event ItemsAdded(
        bytes32 indexed collectionId,
        uint256 count,
        bytes32 updateTxHash
    );

    event ItemsRemoved(
        bytes32 indexed collectionId,
        uint256 count,
        bytes32 updateTxHash
    );

    event CollectionEdited(bytes32 indexed collectionId);
    event CollectionLocked(bytes32 indexed collectionId);

    // Mirror success signaling so indexers can detect success without relying on router
    event ProtocolHandlerSuccess(bytes32 indexed transactionHash, string protocol);

    modifier onlyEthscriptions() {
        require(msg.sender == ethscriptions, "Only Ethscriptions contract");
        _;
    }

    /// @notice Handle create_collection operation
    function op_create_collection(bytes32 txHash, bytes calldata data) external onlyEthscriptions {
        // Decode the operation data directly into CollectionMetadata
        CollectionMetadata memory metadata = abi.decode(data, (CollectionMetadata));

        // Use the ethscription hash as the collection ID
        bytes32 collectionId = txHash;

        // Check if collection already exists
        require(collectionState[collectionId].collectionContract == address(0), "Collection already exists");

        // Get totalSupply from metadata
        uint256 totalSupply = metadata.totalSupply;

        // Deploy ERC721 clone with CREATE2 using collectionId as salt for deterministic address
        address collectionContract = erc721Template.cloneDeterministic(collectionId);

        // Initialize the clone with basic info
        EthscriptionERC721(collectionContract).initialize(
            metadata.name,
            metadata.symbol,
            collectionId
        );

        // Store collection state
        collectionState[collectionId] = CollectionState({
            collectionContract: collectionContract,
            createTxHash: txHash,
            currentSize: 0,
            locked: false
        });

        // Store metadata (already decoded)
        collectionMetadata[collectionId] = metadata;

        collectionIds.push(collectionId);

        emit CollectionCreated(collectionId, collectionContract, metadata.name, metadata.symbol, totalSupply);
        emit ProtocolHandlerSuccess(txHash, protocolName());
    }

    /// @notice Handle add_items_batch operation with full metadata
    function op_add_items_batch(bytes32 txHash, bytes calldata data) external onlyEthscriptions {
        // Get who is trying to add items
        Ethscriptions ethscriptionsContract = Ethscriptions(ethscriptions);
        Ethscriptions.Ethscription memory ethscription = ethscriptionsContract.getEthscription(txHash);
        address sender = ethscription.creator;

        AddItemsBatchOperation memory addOp = abi.decode(data, (AddItemsBatchOperation));

        CollectionState storage collection = collectionState[addOp.collectionId];
        CollectionMetadata storage metadata = collectionMetadata[addOp.collectionId];

        require(collection.collectionContract != address(0), "Collection does not exist");
        require(!collection.locked, "Collection is locked");

        // Only current owner of the collection ethscription can add items
        address currentOwner = ethscriptionsContract.ownerOf(addOp.collectionId);
        require(currentOwner == sender, "Only collection owner can add items");

        // Check max size if set
        if (metadata.totalSupply > 0) {
            require(
                collection.currentSize + addOp.items.length <= metadata.totalSupply,
                "Exceeds total supply"
            );
        }

        // Add each item with full metadata
        EthscriptionERC721 collectionContract = EthscriptionERC721(collection.collectionContract);

        for (uint256 i = 0; i < addOp.items.length; i++) {
            ItemData memory itemData = addOp.items[i];
            uint256 itemIndex = itemData.itemIndex;  // Already uint256

            // Check that this item slot isn't already taken
            require(collectionItems[addOp.collectionId][itemIndex].ethscriptionId == bytes32(0), "Item slot already taken");

            // Check that this ethscription isn't already in ANY slot
            require(ethscriptionToIndexPlusOne[addOp.collectionId][itemData.ethscriptionId] == 0, "Ethscription already in collection");

            // No validation needed - Attribute struct ensures proper structure

            // Store the full item data
            CollectionItem storage newItem = collectionItems[addOp.collectionId][itemIndex];
            newItem.itemIndex = itemIndex;
            newItem.name = itemData.name;
            newItem.ethscriptionId = itemData.ethscriptionId;
            newItem.backgroundColor = itemData.backgroundColor;
            newItem.description = itemData.description;

            // Copy attributes element by element
            for (uint256 j = 0; j < itemData.attributes.length; j++) {
                newItem.attributes.push(itemData.attributes[j]);
            }

            // Map ethscription to its index+1 for lookups (0 means not in collection)
            ethscriptionToIndexPlusOne[addOp.collectionId][itemData.ethscriptionId] = itemIndex + 1;

            // Add to ERC721 collection with the specified token ID
            collectionContract.addMember(itemData.ethscriptionId, itemIndex);

            collection.currentSize++;
        }

        emit ItemsAdded(addOp.collectionId, addOp.items.length, txHash);
        emit ProtocolHandlerSuccess(txHash, protocolName());
    }

    /// @notice Handle remove_items operation
    function op_remove_items(bytes32 txHash, bytes calldata data) external onlyEthscriptions {
        // Get who is trying to remove items
        Ethscriptions ethscriptionsContract = Ethscriptions(ethscriptions);
        Ethscriptions.Ethscription memory ethscription = ethscriptionsContract.getEthscription(txHash);
        address sender = ethscription.creator;

        // Decode the operation data
        RemoveItemsOperation memory removeOp = abi.decode(data, (RemoveItemsOperation));

        CollectionState storage collection = collectionState[removeOp.collectionId];
        require(collection.collectionContract != address(0), "Collection does not exist");
        require(!collection.locked, "Collection is locked");

        // Only current owner of the collection ethscription can remove items
        // The collectionId IS the transaction hash of the collection ethscription
        address currentOwner = ethscriptionsContract.ownerOf(removeOp.collectionId);
        require(currentOwner == sender, "Only collection owner can remove items");

        // Remove each ethscription from the collection
        EthscriptionERC721 collectionContract = EthscriptionERC721(collection.collectionContract);
        for (uint256 i = 0; i < removeOp.ethscriptionIds.length; i++) {
            bytes32 ethscriptionId = removeOp.ethscriptionIds[i];

            // Get the token ID for this ethscription
            uint256 tokenIdPlusOne = ethscriptionToIndexPlusOne[removeOp.collectionId][ethscriptionId];
            require(tokenIdPlusOne != 0, "Not in this collection");
            uint256 tokenId = tokenIdPlusOne - 1;

            // Clear the item data
            delete collectionItems[removeOp.collectionId][tokenId];
            delete ethscriptionToIndexPlusOne[removeOp.collectionId][ethscriptionId];

            // Remove from ERC721 collection
            collectionContract.removeMember(ethscriptionId, tokenId);
            collection.currentSize--;
        }

        emit ItemsRemoved(removeOp.collectionId, removeOp.ethscriptionIds.length, txHash);
        emit ProtocolHandlerSuccess(txHash, protocolName());
    }

    /// @notice Handle edit_collection operation
    function op_edit_collection(bytes32 txHash, bytes calldata data) external onlyEthscriptions {
        Ethscriptions ethscriptionsContract = Ethscriptions(ethscriptions);
        Ethscriptions.Ethscription memory ethscription = ethscriptionsContract.getEthscription(txHash);
        address sender = ethscription.creator;

        EditCollectionOperation memory editOp = abi.decode(data, (EditCollectionOperation));

        CollectionMetadata storage metadata = collectionMetadata[editOp.collectionId];
        CollectionState storage collection = collectionState[editOp.collectionId];
        require(collection.collectionContract != address(0), "Collection does not exist");
        require(!collection.locked, "Collection is locked");

        address currentOwner = ethscriptionsContract.ownerOf(editOp.collectionId);
        require(currentOwner == sender, "Only collection owner can edit");

        // Update metadata fields (only non-empty values update)
        if (bytes(editOp.description).length > 0) metadata.description = editOp.description;
        if (bytes(editOp.logoImageUri).length > 0) metadata.logoImageUri = editOp.logoImageUri;
        if (bytes(editOp.bannerImageUri).length > 0) metadata.bannerImageUri = editOp.bannerImageUri;
        if (bytes(editOp.backgroundColor).length > 0) metadata.backgroundColor = editOp.backgroundColor;
        if (bytes(editOp.websiteLink).length > 0) metadata.websiteLink = editOp.websiteLink;
        if (bytes(editOp.twitterLink).length > 0) metadata.twitterLink = editOp.twitterLink;
        if (bytes(editOp.discordLink).length > 0) metadata.discordLink = editOp.discordLink;

        emit CollectionEdited(editOp.collectionId);
        emit ProtocolHandlerSuccess(txHash, protocolName());
    }

    /// @notice Handle edit_collection_item operation
    function op_edit_collection_item(bytes32 txHash, bytes calldata data) external onlyEthscriptions {
        Ethscriptions ethscriptionsContract = Ethscriptions(ethscriptions);
        Ethscriptions.Ethscription memory ethscription = ethscriptionsContract.getEthscription(txHash);
        address sender = ethscription.creator;

        EditCollectionItemOperation memory editOp = abi.decode(data, (EditCollectionItemOperation));
        uint256 itemIndex = editOp.itemIndex;  // Already uint256

        CollectionState storage collection = collectionState[editOp.collectionId];
        require(collection.collectionContract != address(0), "Collection does not exist");
        require(!collection.locked, "Collection is locked");

        address currentOwner = ethscriptionsContract.ownerOf(editOp.collectionId);
        require(currentOwner == sender, "Only collection owner can edit items");

        CollectionItem storage item = collectionItems[editOp.collectionId][itemIndex];
        require(item.ethscriptionId != bytes32(0), "Item does not exist");

        // Update item fields (only non-empty values update)
        if (bytes(editOp.name).length > 0) item.name = editOp.name;
        if (bytes(editOp.backgroundColor).length > 0) item.backgroundColor = editOp.backgroundColor;
        if (bytes(editOp.description).length > 0) item.description = editOp.description;
        if (editOp.attributes.length > 0) {
            // Clear existing attributes and copy new ones element by element
            delete item.attributes;
            for (uint256 i = 0; i < editOp.attributes.length; i++) {
                item.attributes.push(editOp.attributes[i]);
            }
        }
        emit ProtocolHandlerSuccess(txHash, protocolName());
    }

    /// @notice Handle lock_collection operation
    function op_lock_collection(bytes32 txHash, bytes calldata data) external onlyEthscriptions {
        // Get the ethscription details from the Ethscriptions contract
        Ethscriptions ethscriptionsContract = Ethscriptions(ethscriptions);
        Ethscriptions.Ethscription memory ethscription = ethscriptionsContract.getEthscription(txHash);
        address sender = ethscription.creator; // Who sent this lock operation

        // Decode just the collection ID
        bytes32 collectionId = abi.decode(data, (bytes32));

        CollectionState storage collection = collectionState[collectionId];
        require(collection.collectionContract != address(0), "Collection does not exist");

        // Only current owner of the collection ethscription can lock
        // The collectionId IS the transaction hash of the collection ethscription
        address currentOwner = ethscriptionsContract.ownerOf(collectionId);
        require(currentOwner == sender, "Only collection owner can lock");

        collection.locked = true;
        EthscriptionERC721(collection.collectionContract).lockCollection();
        emit CollectionLocked(collectionId);
        emit ProtocolHandlerSuccess(txHash, protocolName());
    }

    /// @notice Handle sync_ownership operation to sync ERC721 ownership with Ethscription ownership
    /// @dev Requires specifying the collection ID to sync for, to avoid iterating over unbounded user data
    function op_sync_ownership(bytes32 txHash, bytes calldata data) external onlyEthscriptions {
        // User must specify which collection to sync for
        // Decode the operation: collection ID + ethscription IDs to sync
        (bytes32 collectionId, bytes32[] memory ethscriptionIds) = abi.decode(data, (bytes32, bytes32[]));

        CollectionState memory collection = collectionState[collectionId];
        require(collection.collectionContract != address(0), "Collection does not exist");

        EthscriptionERC721 collectionContract = EthscriptionERC721(collection.collectionContract);

        // Sync ownership for specified ethscriptions in this collection
        for (uint256 i = 0; i < ethscriptionIds.length; i++) {
            bytes32 ethscriptionId = ethscriptionIds[i];
            uint256 tokenIdPlusOne = ethscriptionToIndexPlusOne[collectionId][ethscriptionId];

            if (tokenIdPlusOne != 0) {
                // This ethscription is in the collection, sync its ownership
                uint256 tokenId = tokenIdPlusOne - 1;
                collectionContract.syncOwnership(tokenId, ethscriptionId);
            }
        }
        emit ProtocolHandlerSuccess(txHash, protocolName());
    }

    /// @notice Handle transfer notification from Ethscriptions contract
    /// @dev When an ethscription that's part of a collection is transferred, sync the ERC721
    function onTransfer(
        bytes32 txHash,
        address from,
        address to
    ) external override onlyEthscriptions {
        // CollectionItem memory item = collectionItems[txHash];

        // // If this ethscription is part of a collection, sync ownership
        // if (item.collectionId != bytes32(0)) {
        //     CollectionState memory collection = collectionState[item.collectionId];
        //     if (collection.collectionContract != address(0)) {
        //         // Sync the ownership in the ERC721 contract
        //         EthscriptionERC721(collection.collectionContract).syncOwnership(item.tokenId);
        //     }
        // }
    }

    // View functions

    function getCollectionAddress(bytes32 collectionId) external view returns (address) {
        return collectionState[collectionId].collectionContract;
    }

    function getCollectionState(bytes32 collectionId) external view returns (CollectionState memory) {
        return collectionState[collectionId];
    }

    function getCollectionItem(bytes32 collectionId, uint256 itemIndex) external view returns (CollectionItem memory) {
        return collectionItems[collectionId][itemIndex];
    }

    function getCollectionMetadata(bytes32 collectionId) external view returns (CollectionMetadata memory) {
        return collectionMetadata[collectionId];
    }

    function isInCollection(bytes32 ethscriptionId, bytes32 collectionId) external view returns (bool) {
        return ethscriptionToIndexPlusOne[collectionId][ethscriptionId] != 0;
    }

    function getEthscriptionTokenId(bytes32 ethscriptionId, bytes32 collectionId) external view returns (uint256) {
        uint256 tokenIdPlusOne = ethscriptionToIndexPlusOne[collectionId][ethscriptionId];
        require(tokenIdPlusOne != 0, "Not in collection");
        return tokenIdPlusOne - 1;
    }

    function predictCollectionAddress(bytes32 collectionId) external view returns (address) {
        // Check if already deployed
        if (collectionState[collectionId].collectionContract != address(0)) {
            return collectionState[collectionId].collectionContract;
        }

        // Predict using CREATE2
        return Clones.predictDeterministicAddress(erc721Template, collectionId, address(this));
    }

    function getAllCollections() external view returns (bytes32[] memory) {
        return collectionIds;
    }

    /// @notice Returns human-readable protocol name
    /// @return The protocol name
    function protocolName() public pure override returns (string memory) {
        return "collections";
    }
}

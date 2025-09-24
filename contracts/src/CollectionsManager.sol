// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";
import {LibString} from "solady/utils/LibString.sol";
import "./protocols/EthscriptionERC721.sol";
import "./Ethscriptions.sol";
import "./libraries/Predeploys.sol";
import "./protocols/IProtocolHandler.sol";

contract CollectionsManager is IProtocolHandler {
    using Clones for address;
    using LibString for string;

    struct CollectionInfo {
        address collectionContract;
        bytes32 createTxHash;       // The ethscription that created this collection
        string name;
        string symbol;
        uint256 maxSize;            // Max number of items (0 = unlimited)
        uint256 currentSize;        // Current number of items
        bool locked;                // Whether collection is frozen
    }

    // Removed CollectionItem struct - now using nested mapping for multi-collection support

    // Protocol operation structs for cleaner decoding
    struct CreateCollectionOperation {
        string name;
        string symbol;
        uint256 maxSize;
        string baseUri;
    }

    struct AddItemsOperation {
        bytes32 collectionId;
        bytes32[] ethscriptionIds;
    }

    struct RemoveItemsOperation {
        bytes32 collectionId;
        bytes32[] ethscriptionIds;
    }

    address public constant erc721Template = Predeploys.ERC721_TEMPLATE;
    address public constant ethscriptions = Predeploys.ETHSCRIPTIONS;

    // Track deployed collections by ID
    mapping(bytes32 => CollectionInfo) public collections;
    mapping(bytes32 => bytes32) public createToCollection;  // createTxHash => collectionId

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

    modifier onlyEthscriptions() {
        require(msg.sender == ethscriptions, "Only Ethscriptions contract");
        _;
    }

    /// @notice Handle create_collection operation
    function op_create_collection(bytes32 txHash, bytes calldata data) external onlyEthscriptions {

        // Decode the operation data
        CreateCollectionOperation memory createOp = abi.decode(data, (CreateCollectionOperation));

        // Use the ethscription hash as the collection ID
        bytes32 collectionId = txHash;

        // Check if collection already exists
        require(collections[collectionId].collectionContract == address(0), "Collection already exists");

        // Deploy ERC721 clone with CREATE2 using collectionId as salt for deterministic address
        address collectionContract = erc721Template.cloneDeterministic(collectionId);

        // Initialize the clone
        EthscriptionERC721(collectionContract).initialize(
            createOp.name,
            createOp.symbol,
            collectionId,
            ethscriptions,
            txHash,  // Use creation tx as metadata inscription ID
            createOp.baseUri
        );

        // Store collection info
        collections[collectionId] = CollectionInfo({
            collectionContract: collectionContract,
            createTxHash: txHash,
            name: createOp.name,
            symbol: createOp.symbol,
            maxSize: createOp.maxSize,
            currentSize: 0,
            locked: false
        });

        createToCollection[txHash] = collectionId;
        collectionIds.push(collectionId);

        emit CollectionCreated(collectionId, collectionContract, createOp.name, createOp.symbol, createOp.maxSize);
    }

    /// @notice Handle add_items operation
    function op_add_items(bytes32 txHash, bytes calldata data) external onlyEthscriptions {
        // Get who is trying to add items
        Ethscriptions ethscriptionsContract = Ethscriptions(ethscriptions);
        Ethscriptions.Ethscription memory ethscription = ethscriptionsContract.getEthscription(txHash);
        address sender = ethscription.creator;

        AddItemsOperation memory addOp = abi.decode(data, (AddItemsOperation));

        CollectionInfo storage collection = collections[addOp.collectionId];
        require(collection.collectionContract != address(0), "Collection does not exist");
        require(!collection.locked, "Collection is locked");

        // Only current owner of the collection ethscription can add items
        // The collectionId IS the transaction hash of the collection ethscription
        address currentOwner = ethscriptionsContract.ownerOf(addOp.collectionId);
        require(currentOwner == sender, "Only collection owner can add items");

        // Check max size if set
        if (collection.maxSize > 0) {
            require(
                collection.currentSize + addOp.ethscriptionIds.length <= collection.maxSize,
                "Exceeds max size"
            );
        }

        // Add each ethscription to the collection
        EthscriptionERC721 collectionContract = EthscriptionERC721(collection.collectionContract);
        for (uint256 i = 0; i < addOp.ethscriptionIds.length; i++) {
            bytes32 ethscriptionId = addOp.ethscriptionIds[i];

            // Check that this ethscription isn't already in THIS collection
            // The collection contract itself tracks membership
            require(collectionContract.ethscriptionToToken(ethscriptionId) == 0, "Already in this collection");

            // Add to collection
            collectionContract.addMember(ethscriptionId);

            collection.currentSize++;
        }

        emit ItemsAdded(addOp.collectionId, addOp.ethscriptionIds.length, txHash);
    }

    /// @notice Handle remove_items operation
    function op_remove_items(bytes32 txHash, bytes calldata data) external onlyEthscriptions {
        // Get who is trying to remove items
        Ethscriptions ethscriptionsContract = Ethscriptions(ethscriptions);
        Ethscriptions.Ethscription memory ethscription = ethscriptionsContract.getEthscription(txHash);
        address sender = ethscription.creator;

        // Decode the operation data
        RemoveItemsOperation memory removeOp = abi.decode(data, (RemoveItemsOperation));

        CollectionInfo storage collection = collections[removeOp.collectionId];
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

            // Check that this ethscription is in this collection
            // The collection contract itself tracks membership
            require(
                collectionContract.ethscriptionToToken(ethscriptionId) != 0,
                "Not in this collection"
            );

            // Remove from collection
            collectionContract.removeMember(ethscriptionId);
            collection.currentSize--;
        }

        emit ItemsRemoved(removeOp.collectionId, removeOp.ethscriptionIds.length, txHash);
    }

    /// @notice Handle lock_collection operation
    function op_lock_collection(bytes32 txHash, bytes calldata data) external onlyEthscriptions {
        // Get the ethscription details from the Ethscriptions contract
        Ethscriptions ethscriptionsContract = Ethscriptions(ethscriptions);
        Ethscriptions.Ethscription memory ethscription = ethscriptionsContract.getEthscription(txHash);
        address sender = ethscription.creator; // Who sent this lock operation

        // Decode just the collection ID
        bytes32 collectionId = abi.decode(data, (bytes32));

        CollectionInfo storage collection = collections[collectionId];
        require(collection.collectionContract != address(0), "Collection does not exist");

        // Only current owner of the collection ethscription can lock
        // The collectionId IS the transaction hash of the collection ethscription
        address currentOwner = ethscriptionsContract.ownerOf(collectionId);
        require(currentOwner == sender, "Only collection owner can lock");

        collection.locked = true;
        EthscriptionERC721(collection.collectionContract).lockCollection();
    }

    /// @notice Handle sync_ownership operation to sync ERC721 ownership with Ethscription ownership
    /// @dev Requires specifying the collection ID to sync for, to avoid iterating over unbounded user data
    function op_sync_ownership(bytes32, bytes calldata data) external onlyEthscriptions {

        // User must specify which collection to sync for
        // Decode the operation: collection ID + ethscription IDs to sync
        (bytes32 collectionId, bytes32[] memory ethscriptionIds) = abi.decode(data, (bytes32, bytes32[]));

        CollectionInfo memory collection = collections[collectionId];
        require(collection.collectionContract != address(0), "Collection does not exist");

        EthscriptionERC721 collectionContract = EthscriptionERC721(collection.collectionContract);

        // Sync ownership for specified ethscriptions in this collection
        for (uint256 i = 0; i < ethscriptionIds.length; i++) {
            bytes32 ethscriptionId = ethscriptionIds[i];
            uint256 tokenId = collectionContract.ethscriptionToToken(ethscriptionId);

            if (tokenId != 0) {
                // This ethscription is in the collection, sync its ownership
                collectionContract.syncOwnership(tokenId);
            }
        }
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
        //     CollectionInfo memory collection = collections[item.collectionId];
        //     if (collection.collectionContract != address(0)) {
        //         // Sync the ownership in the ERC721 contract
        //         EthscriptionERC721(collection.collectionContract).syncOwnership(item.tokenId);
        //     }
        // }
    }

    // View functions

    function getCollectionAddress(bytes32 collectionId) external view returns (address) {
        return collections[collectionId].collectionContract;
    }

    function getCollectionInfo(bytes32 collectionId) external view returns (CollectionInfo memory) {
        return collections[collectionId];
    }

    // Removed getCollectionItem - use getEthscriptionCollections instead

    function isInCollection(bytes32 ethscriptionId, bytes32 collectionId) external view returns (bool) {
        CollectionInfo memory collection = collections[collectionId];
        if (collection.collectionContract == address(0)) return false;

        EthscriptionERC721 collectionContract = EthscriptionERC721(collection.collectionContract);
        return collectionContract.ethscriptionToToken(ethscriptionId) != 0;
    }

    function predictCollectionAddress(bytes32 collectionId) external view returns (address) {
        // Check if already deployed
        if (collections[collectionId].collectionContract != address(0)) {
            return collections[collectionId].collectionContract;
        }

        // Predict using CREATE2
        return Clones.predictDeterministicAddress(erc721Template, collectionId, address(this));
    }

    function getAllCollections() external view returns (bytes32[] memory) {
        return collectionIds;
    }

    // IProtocolHandler implementation

    /// @notice Generic sync entrypoint for protocol-specific operations
    /// @dev Not used for collections protocol
    function sync(bytes calldata) external pure override {
        revert("Not implemented");
    }

    /// @notice Returns human-readable protocol name
    /// @return The protocol name
    function protocolName() public pure override returns (string memory) {
        return "collections";
    }
}
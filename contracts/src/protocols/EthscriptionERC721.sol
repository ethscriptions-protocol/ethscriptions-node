// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "../ERC721EthscriptionsUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../Ethscriptions.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Base64} from "solady/utils/Base64.sol";
import "../CollectionsManager.sol";

/// @title EthscriptionERC721
/// @notice ERC-721 contract for an Ethscription collection
/// @dev Maintains internal state but overrides ownerOf to delegate to Ethscriptions contract
contract EthscriptionERC721 is ERC721EthscriptionsUpgradeable {
    using LibString for *;

    /// @notice The main Ethscriptions contract
    Ethscriptions public constant ethscriptions = Ethscriptions(Predeploys.ETHSCRIPTIONS);

    /// @notice The collection factory that created this contract
    address public factory;

    /// @notice The collection ID (Ethscription hash)
    bytes32 public collectionId;
    
    bool public locked;

    // Events
    event MemberAdded(bytes32 indexed ethscriptionId, uint256 indexed tokenId);
    event MemberRemoved(bytes32 indexed ethscriptionId, uint256 indexed tokenId);
    event CollectionLocked();

    // Errors
    error NotFactory();
    error CollectionIsLocked();
    error TransferNotAllowed();
    error AlreadyMember();
    error NotMember();

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier notLocked() {
        if (locked) revert CollectionIsLocked();
        _;
    }

    /// @notice Initialize the collection (called once after cloning)
    function initialize(
        string memory _name,
        string memory _symbol,
        bytes32 _collectionId
    ) external initializer {
        // Initialize parent contracts
        __ERC721_init(_name, _symbol);

        // Set collection-specific values
        collectionId = _collectionId;
        factory = msg.sender;
    }

    /// @notice Add a member to the collection with specific token ID
    /// @param ethscriptionId The Ethscription to add
    /// @param tokenId The token ID to mint (same as item index)
    function addMember(bytes32 ethscriptionId, uint256 tokenId) external onlyFactory notLocked {
        // Get current owner from Ethscriptions contract
        address owner = ethscriptions.ownerOf(ethscriptionId);

        // Mint using the specified token ID
        _mint(owner, tokenId);

        emit MemberAdded(ethscriptionId, tokenId);
    }

    /// @notice Remove a member from the collection
    /// @param ethscriptionId The Ethscription to remove
    /// @param tokenId The token ID to remove
    function removeMember(bytes32 ethscriptionId, uint256 tokenId) external onlyFactory notLocked {
        // Get current owner before removal (for the Transfer event)
        address currentOwner = _ownerOf(tokenId);

        // Mark token as non-existent in the base contract
        _setTokenExists(tokenId, false);

        // Emit Transfer to address(0) for indexers to track removal
        emit Transfer(currentOwner, address(0), tokenId);
        emit MemberRemoved(ethscriptionId, tokenId);
    }

    /// @notice Sync ownership for a specific token
    /// @param tokenId The token to sync
    /// @param ethscriptionId The ethscription ID for this token
    function syncOwnership(uint256 tokenId, bytes32 ethscriptionId) external {
        // Check if token still exists in collection
        require(_tokenExists(tokenId), "Token does not exist");

        // Get actual owner from Ethscriptions contract
        address actualOwner = ethscriptions.ownerOf(ethscriptionId);

        // Get recorded owner from our state
        address recordedOwner = _ownerOf(tokenId);

        // If they differ, update our state
        if (actualOwner != recordedOwner) {
            // Use internal _transfer to update state and emit event
            _transfer(recordedOwner, actualOwner, tokenId);
        }
    }

    /// @notice Batch sync ownership for multiple tokens
    /// @param tokenIds Array of token IDs to sync
    /// @param ethscriptionIds Array of corresponding ethscription IDs
    function syncOwnershipBatch(uint256[] calldata tokenIds, bytes32[] calldata ethscriptionIds) external {
        require(tokenIds.length == ethscriptionIds.length, "Array length mismatch");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            bytes32 ethscriptionId = ethscriptionIds[i];

            // Skip non-existent tokens
            if (!_tokenExists(tokenId)) continue;

            address actualOwner = ethscriptions.ownerOf(ethscriptionId);
            address recordedOwner = _ownerOf(tokenId);

            if (actualOwner != recordedOwner) {
                _transfer(recordedOwner, actualOwner, tokenId);
            }
        }
    }

    /// @notice Lock the collection (freeze it)
    function lockCollection() external onlyFactory {
        locked = true;
        emit CollectionLocked();
    }

    // Override ownerOf to delegate to Ethscriptions contract
    function ownerOf(uint256 tokenId) public view override returns (address) {
        // Check if token exists in collection
        if (!_tokenExists(tokenId)) {
            revert("Token does not exist");
        }

        // Get ethscription ID from manager
        CollectionsManager manager = CollectionsManager(factory);
        CollectionsManager.CollectionItem memory item = manager.getCollectionItem(collectionId, tokenId);

        if (item.ethscriptionId == bytes32(0)) {
            revert("Token not in collection");
        }

        // Always return the actual owner from Ethscriptions contract
        return ethscriptions.ownerOf(item.ethscriptionId);
    }

    // Override tokenURI to generate full metadata JSON
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_tokenExists(tokenId)) {
            revert("Token does not exist");
        }

        // Get collection metadata and item data from CollectionsManager
        CollectionsManager manager = CollectionsManager(factory);
        CollectionsManager.CollectionItem memory item = manager.getCollectionItem(collectionId, tokenId);

        if (item.ethscriptionId == bytes32(0)) {
            revert("Token not in collection");
        }

        // Get media URI from Ethscriptions contract
        (string memory mediaType, string memory mediaUri) = ethscriptions.getMediaUri(item.ethscriptionId);

        // Build JSON components
        string memory jsonStart = string.concat(
            '{"name":"',
            item.name.escapeJSON(),
            '"'
        );

        // Add description if present
        if (bytes(item.description).length > 0) {
            jsonStart = string.concat(
                jsonStart,
                ',"description":"',
                item.description.escapeJSON(),
                '"'
            );
        }

        // Add media field (image or animation_url)
        string memory mediaField = string.concat(
            ',"',
            mediaType,
            '":"',
            mediaUri.escapeJSON(),
            '"'
        );

        // Add background color if present
        string memory bgColor = "";
        if (bytes(item.backgroundColor).length > 0) {
            bgColor = string.concat(
                ',"background_color":"',
                item.backgroundColor.escapeJSON(),
                '"'
            );
        }

        // Build attributes array from Attribute structs
        string memory attributesJson = ',"attributes":[';
        for (uint i = 0; i < item.attributes.length; i++) {
            if (i > 0) attributesJson = string.concat(attributesJson, ',');
            attributesJson = string.concat(
                attributesJson,
                '{"trait_type":"',
                item.attributes[i].traitType.escapeJSON(),
                '","value":"',
                item.attributes[i].value.escapeJSON(),
                '"}'
            );
        }
        attributesJson = string.concat(attributesJson, ']');

        // Combine all parts
        string memory json = string.concat(
            jsonStart,
            mediaField,
            bgColor,
            attributesJson,
            '}'
        );

        // Return as base64-encoded data URI
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    // Block external transfers - only internal _transfer is allowed for syncing
    function transferFrom(address, address, uint256) public pure override {
        revert TransferNotAllowed();
    }

    function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
        revert TransferNotAllowed();
    }

    // Block approvals - not needed for non-transferable tokens
    function approve(address, uint256) public pure override {
        revert TransferNotAllowed();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert TransferNotAllowed();
    }
}

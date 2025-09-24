// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "../ERC721EthscriptionsUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
// import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../Ethscriptions.sol";

/// @title EthscriptionERC721
/// @notice ERC-721 contract for an Ethscription collection
/// @dev Maintains internal state but overrides ownerOf to delegate to Ethscriptions contract
contract EthscriptionERC721 is ERC721EthscriptionsUpgradeable {

    /// @notice The main Ethscriptions contract
    Ethscriptions public ethscriptions;

    /// @notice The collection factory that created this contract
    address public factory;

    /// @notice The collection ID (Ethscription hash)
    bytes32 public collectionId;

    /// @notice Metadata inscription ID for the collection
    bytes32 public metadataInscriptionId;

    /// @notice Base URI for token metadata
    string public baseTokenURI;

    /// @notice Mapping from token ID to Ethscription ID
    mapping(uint256 => bytes32) public tokenToEthscription;

    /// @notice Mapping from Ethscription ID to token ID
    mapping(bytes32 => uint256) public ethscriptionToToken;

    /// @notice Counter for token IDs
    uint256 private nextTokenId = 1;

    /// @notice Collection is locked/frozen
    bool public locked;

    // Events
    event MemberAdded(bytes32 indexed ethscriptionId, uint256 indexed tokenId);
    event MemberRemoved(bytes32 indexed ethscriptionId, uint256 indexed tokenId);
    event CollectionLocked();
    event MetadataUpdated(bytes32 indexed metadataInscriptionId, string baseURI);

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
        bytes32 _collectionId,
        address _ethscriptions,
        bytes32 _metadataInscriptionId,
        string memory _baseTokenURI
    ) external initializer {
        // Initialize parent contracts
        __ERC721_init(_name, _symbol);

        // Set collection-specific values
        collectionId = _collectionId;
        ethscriptions = Ethscriptions(_ethscriptions);
        factory = msg.sender;  // The CollectionsManager that deployed this
        metadataInscriptionId = _metadataInscriptionId;
        baseTokenURI = _baseTokenURI;
    }

    /// @notice Add a member to the collection
    /// @param ethscriptionId The Ethscription to add
    function addMember(bytes32 ethscriptionId) external onlyFactory notLocked {
        if (ethscriptionToToken[ethscriptionId] != 0) revert AlreadyMember();

        uint256 tokenId = nextTokenId++;
        tokenToEthscription[tokenId] = ethscriptionId;
        ethscriptionToToken[ethscriptionId] = tokenId;

        // Get current owner from Ethscriptions contract
        address owner = ethscriptions.ownerOf(ethscriptionId);

        // Mint using internal state
        _mint(owner, tokenId);

        emit MemberAdded(ethscriptionId, tokenId);
    }

    /// @notice Remove a member from the collection
    /// @param ethscriptionId The Ethscription to remove
    function removeMember(bytes32 ethscriptionId) external onlyFactory notLocked {
        uint256 tokenId = ethscriptionToToken[ethscriptionId];
        if (tokenId == 0) revert NotMember();

        // Get current owner before removal (for the Transfer event)
        address currentOwner = _ownerOf(tokenId);

        // Mark token as non-existent in the base contract
        _setTokenExists(tokenId, false);

        // Clear our tracking mappings
        delete tokenToEthscription[tokenId];
        delete ethscriptionToToken[ethscriptionId];

        // Emit Transfer to address(0) for indexers to track removal
        emit Transfer(currentOwner, address(0), tokenId);
        emit MemberRemoved(ethscriptionId, tokenId);
    }

    /// @notice Sync ownership for a specific token
    /// @param tokenId The token to sync
    function syncOwnership(uint256 tokenId) external {
        // Check if token still exists in collection
        require(_tokenExists(tokenId), "Token does not exist");

        bytes32 ethscriptionId = tokenToEthscription[tokenId];
        require(ethscriptionId != bytes32(0), "Token not in collection");

        // Get actual owner from Ethscriptions contract
        address actualOwner = ethscriptions.ownerOf(ethscriptionId);

        // Get recorded owner from our state
        address recordedOwner = _ownerOf(tokenId);

        // If they differ, update our state
        if (actualOwner != recordedOwner) {
            // Use internal _transfer to update state and emit event
            // This bypasses the transfer restrictions in transferFrom
            // Works for any owner including address(0)
            _transfer(recordedOwner, actualOwner, tokenId);
        }
    }

    /// @notice Batch sync ownership for multiple tokens
    /// @param tokenIds Array of token IDs to sync
    function syncOwnershipBatch(uint256[] calldata tokenIds) external {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];

            // Skip non-existent tokens
            if (!_tokenExists(tokenId)) continue;

            bytes32 ethscriptionId = tokenToEthscription[tokenId];

            if (ethscriptionId != bytes32(0)) {
                address actualOwner = ethscriptions.ownerOf(ethscriptionId);
                address recordedOwner = _ownerOf(tokenId);

                if (actualOwner != recordedOwner) {
                    // Transfer to actual owner (including address(0))
                    _transfer(recordedOwner, actualOwner, tokenId);
                }
            }
        }
    }

    /// @notice Update collection metadata
    /// @param _metadataInscriptionId New metadata inscription ID
    /// @param _baseTokenURI New base URI
    function updateMetadata(
        bytes32 _metadataInscriptionId,
        string calldata _baseTokenURI
    ) external onlyFactory notLocked {
        metadataInscriptionId = _metadataInscriptionId;
        baseTokenURI = _baseTokenURI;
        emit MetadataUpdated(_metadataInscriptionId, _baseTokenURI);
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

        bytes32 ethscriptionId = tokenToEthscription[tokenId];
        if (ethscriptionId == bytes32(0)) {
            revert("Token not in collection");
        }

        // Always return the actual owner from Ethscriptions contract
        return ethscriptions.ownerOf(ethscriptionId);
    }

    // Override tokenURI
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (tokenToEthscription[tokenId] == bytes32(0)) {
            revert("Token does not exist");
        }

        return '';
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

    // Required overrides for multiple inheritance
    // function _update(address to, uint256 tokenId, address auth)
    //     internal
    //     override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    //     returns (address)
    // {
    //     return super._update(to, tokenId, auth);
    // }

    // function _increaseBalance(address account, uint128 value)
    //     internal
    //     override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    // {
    //     super._increaseBalance(account, value);
    // }

    // function supportsInterface(bytes4 interfaceId)
    //     public
    //     view
    //     override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    //     returns (bool)
    // {
    //     return super.supportsInterface(interfaceId);
    // }
}

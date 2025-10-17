// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ERC721EthscriptionsUpgradeable.sol";
import {LibString} from "solady/utils/LibString.sol";
import "./libraries/SSTORE2ChunkedStorageLib.sol";
import "./libraries/EthscriptionsRendererLib.sol";
import "./EthscriptionsProver.sol";
import "./libraries/Predeploys.sol";
import "./L2/L1Block.sol";
import "./interfaces/IProtocolHandler.sol";
import "./libraries/Constants.sol";

/// @title Ethscriptions ERC-721 Contract
/// @notice Mints Ethscriptions as ERC-721 tokens based on L1 transaction data
/// @dev Uses ethscription number as token ID and name, while transaction hash remains the primary identifier for function calls
contract Ethscriptions is ERC721EthscriptionsUpgradeable {
    using LibString for *;
    using SSTORE2ChunkedStorageLib for address[];
    using EthscriptionsRendererLib for Ethscription;

    // =============================================================
    //                          STRUCTS
    // =============================================================

    struct ContentInfo {
        bytes32 contentUriHash;  // SHA256 of raw content URI string (for protocol uniqueness)
        bytes32 contentSha;      // SHA256 of decoded raw bytes (for storage reference)
        string mimetype;         // Full MIME type (e.g., "text/plain")
        string mediaType;        // e.g., "text", "image"
        string mimeSubtype;      // e.g., "plain", "png"
        bool esip6;
    }

    struct Ethscription {
        ContentInfo content;
        address creator;
        address initialOwner;
        address previousOwner;
        uint256 ethscriptionNumber;
        uint256 createdAt;       // Timestamp when created
        uint64 l1BlockNumber;    // L1 block number when created
        uint64 l2BlockNumber;    // L2 block number when created
        bytes32 l1BlockHash;     // L1 block hash when created
    }

    struct ProtocolParams {
        string protocolName;  // Protocol identifier (e.g., "erc-20", "collections", etc.)
        string operation;     // Operation to perform (e.g., "mint", "deploy", "create_collection", etc.)
        bytes data;          // ABI-encoded parameters specific to the protocol/operation
    }

    struct CreateEthscriptionParams {
        bytes32 transactionHash;
        bytes32 contentUriHash;  // SHA256 of raw content URI (for protocol uniqueness)
        address initialOwner;
        bytes content;           // Raw decoded bytes (not Base64)
        string mimetype;
        string mediaType;
        string mimeSubtype;
        bool esip6;
        ProtocolParams protocolParams;  // Protocol operation data (optional)
    }

    // =============================================================
    //                     CONSTANTS & IMMUTABLES
    // =============================================================

    /// @dev L1Block predeploy for getting L1 block info
    L1Block constant l1Block = L1Block(Predeploys.L1_BLOCK_ATTRIBUTES);

    /// @dev Ethscriptions Prover contract (pre-deployed at known address)
    EthscriptionsProver public constant prover = EthscriptionsProver(Predeploys.ETHSCRIPTIONS_PROVER);

    // =============================================================
    //                      STATE VARIABLES
    // =============================================================

    /// @dev Transaction hash => Ethscription data
    mapping(bytes32 => Ethscription) internal ethscriptions;

    /// @dev Content SHA => SSTORE2 pointers array
    mapping(bytes32 => address[]) public contentPointersBySha;

    /// @dev Content URI hash => first ethscription tx hash that used it (for protocol uniqueness check)
    /// @dev bytes32(0) means unused, non-zero means the content URI has been used
    mapping(bytes32 => bytes32) public firstEthscriptionByContentUri;

    /// @dev Mapping from ethscription number (token ID) to transaction hash
    mapping(uint256 => bytes32) public tokenIdToTransactionHash;

    /// @dev Protocol registry - maps protocol names to handler addresses
    mapping(string => address) public protocolHandlers;

    /// @dev Track which protocol an ethscription uses
    mapping(bytes32 => string) public protocolOf;

    /// @dev Array of genesis ethscription transaction hashes that need events emitted
    /// @notice This array is populated during genesis and cleared (by popping) when events are emitted
    bytes32[] internal pendingGenesisEvents;

    // =============================================================
    //                      CUSTOM ERRORS
    // =============================================================

    error DuplicateContentUri();
    error InvalidCreator();
    error EthscriptionAlreadyExists();
    error EthscriptionDoesNotExist();
    error OnlyDepositor();
    error InvalidHandler();
    error ProtocolAlreadyRegistered();
    error PreviousOwnerMismatch();
    error NoSuccessfulTransfers();
    error TokenDoesNotExist();

    // =============================================================
    //                          EVENTS
    // =============================================================

    /// @notice Emitted when a new ethscription is created
    event EthscriptionCreated(
        bytes32 indexed transactionHash,
        address indexed creator,
        address indexed initialOwner,
        bytes32 contentUriHash,
        bytes32 contentSha,
        uint256 ethscriptionNumber
    );

    /// @notice Emitted when an ethscription is transferred (Ethscriptions protocol semantics)
    /// @dev This event matches the Ethscriptions protocol transfer semantics where 'from' is the initiator
    /// For creations, this shows transfer from creator to initial owner (not from address(0))
    event EthscriptionTransferred(
        bytes32 indexed transactionHash,
        address indexed from,
        address indexed to,
        uint256 ethscriptionNumber
    );

    /// @notice Emitted when a protocol handler is registered
    event ProtocolRegistered(string indexed protocol, address indexed handler);

    /// @notice Emitted when a protocol handler operation fails but ethscription continues
    event ProtocolHandlerFailed(
        bytes32 indexed transactionHash,
        string protocol,
        bytes revertData
    );

    /// @notice Emitted when a protocol handler operation succeeds
    event ProtocolHandlerSuccess(
        bytes32 indexed transactionHash,
        string protocol,
        bytes returnData
    );

    // =============================================================
    //                         MODIFIERS
    // =============================================================

    /// @notice Modifier to emit pending genesis events on first real creation
    modifier emitGenesisEvents() {
        _emitPendingGenesisEvents();
        _;
    }

    /// @notice Modifier to require that an ethscription exists
    /// @param transactionHash The transaction hash to check
    modifier requireExists(bytes32 transactionHash) {
        if (!_ethscriptionExists(transactionHash)) revert EthscriptionDoesNotExist();
        _;
    }

    // =============================================================
    //                    ADMIN/SETUP FUNCTIONS
    // =============================================================

    /// @notice Register a protocol handler
    /// @param protocol The protocol identifier (e.g., "erc-20", "collections")
    /// @param handler The address of the handler contract
    /// @dev Only callable by the depositor address (used during genesis setup)
    function registerProtocol(string calldata protocol, address handler) external {
        if (msg.sender != Predeploys.DEPOSITOR_ACCOUNT) revert OnlyDepositor();
        if (handler == address(0)) revert InvalidHandler();
        if (protocolHandlers[protocol] != address(0)) revert ProtocolAlreadyRegistered();

        protocolHandlers[protocol] = handler;
        emit ProtocolRegistered(protocol, handler);
    }

    // =============================================================
    //                    CORE EXTERNAL FUNCTIONS
    // =============================================================

    /// @notice Create (mint) a new ethscription token
    /// @dev Called via system transaction with msg.sender spoofed as the actual creator
    /// @param params Struct containing all ethscription creation parameters
    function createEthscription(
        CreateEthscriptionParams calldata params
    ) external emitGenesisEvents returns (uint256 tokenId) {
        address creator = msg.sender;

        if (creator == address(0)) revert InvalidCreator();
        if (_ethscriptionExists(params.transactionHash)) revert EthscriptionAlreadyExists();
        
        bool contentUriAlreadySeen = firstEthscriptionByContentUri[params.contentUriHash] != bytes32(0);

        if (contentUriAlreadySeen) {
            if (!params.esip6) revert DuplicateContentUri();
        } else {
            firstEthscriptionByContentUri[params.contentUriHash] = params.transactionHash;
        }

        // Store content and get content SHA (of raw bytes)
        bytes32 contentSha = _storeContent(params.content);

        ethscriptions[params.transactionHash] = Ethscription({
            content: ContentInfo({
                contentUriHash: params.contentUriHash,
                contentSha: contentSha,
                mimetype: params.mimetype,
                mediaType: params.mediaType,
                mimeSubtype: params.mimeSubtype,
                esip6: params.esip6
            }),
            creator: creator,
            initialOwner: params.initialOwner,
            previousOwner: creator, // Initially same as creator
            ethscriptionNumber: totalSupply(),
            createdAt: block.timestamp,
            l1BlockNumber: l1Block.number(),
            l2BlockNumber: uint64(block.number),
            l1BlockHash: l1Block.hash()
        });

        // Use ethscription number as token ID
        tokenId = totalSupply();

        // Store the mapping from token ID to transaction hash
        tokenIdToTransactionHash[tokenId] = params.transactionHash;

        // Mint to initial owner (if address(0), mint to creator then transfer)
        if (params.initialOwner == address(0)) {
            _mint(creator, tokenId);
            _transfer(creator, address(0), tokenId);
        } else {
            _mint(params.initialOwner, tokenId);
        }

        emit EthscriptionCreated(
            params.transactionHash,
            creator,
            params.initialOwner,
            params.contentUriHash,
            contentSha,
            tokenId
        );

        // Handle protocol operations (if any)
        _callProtocolOperation(params.transactionHash, params.protocolParams);
    }

    /// @notice Transfer an ethscription
    /// @dev Called via system transaction with msg.sender spoofed as 'from'
    /// @param to The recipient address (can be address(0) for burning)
    /// @param transactionHash The ethscription to transfer (used to find token ID)
    function transferEthscription(
        address to,
        bytes32 transactionHash
    ) external requireExists(transactionHash) {
        // Get the ethscription number to use as token ID
        Ethscription memory etsc = ethscriptions[transactionHash];
        uint256 tokenId = etsc.ethscriptionNumber;
        // Standard ERC721 transfer will handle authorization
        transferFrom(msg.sender, to, tokenId);
    }

    /// @notice Transfer an ethscription with previous owner validation (ESIP-2)
    /// @dev Called via system transaction with msg.sender spoofed as 'from'
    /// @param to The recipient address (can be address(0) for burning)
    /// @param transactionHash The ethscription to transfer
    /// @param previousOwner The required previous owner for validation
    function transferEthscriptionForPreviousOwner(
        address to,
        bytes32 transactionHash,
        address previousOwner
    ) external requireExists(transactionHash) {
        // Verify the previous owner matches
        if (ethscriptions[transactionHash].previousOwner != previousOwner) {
            revert PreviousOwnerMismatch();
        }

        // Get the ethscription number to use as token ID
        Ethscription memory etsc = ethscriptions[transactionHash];
        uint256 tokenId = etsc.ethscriptionNumber;
        // Use transferFrom which now handles burns when to == address(0)
        transferFrom(msg.sender, to, tokenId);
    }

    /// @notice Transfer multiple ethscriptions to a single recipient
    /// @dev Continues transferring even if individual transfers fail due to wrong ownership
    /// @param transactionHashes Array of ethscription hashes to transfer
    /// @param to The recipient address (can be address(0) for burning)
    /// @return successCount Number of successful transfers
    function transferMultipleEthscriptions(
        bytes32[] calldata transactionHashes,
        address to
    ) external returns (uint256 successCount) {
        for (uint256 i = 0; i < transactionHashes.length; i++) {
            // Get the ethscription to find its token ID
            if (!_ethscriptionExists(transactionHashes[i])) continue; // Skip non-existent ethscriptions
            Ethscription memory etsc = ethscriptions[transactionHashes[i]];

            uint256 tokenId = etsc.ethscriptionNumber;

            // Check if sender owns this token before attempting transfer
            // This prevents reverts and allows us to continue
            if (_ownerOf(tokenId) == msg.sender) {
                // Perform the transfer directly using internal _update
                _update(to, tokenId, msg.sender);
                successCount++;
            }
            // If sender doesn't own the token, just continue to next one
        }

        if (successCount == 0) revert NoSuccessfulTransfers();
    }

    // =============================================================
    //                      VIEW FUNCTIONS
    // =============================================================

    // ---------------------- Token Metadata ----------------------

    function name() public pure override returns (string memory) {
        return "Ethscriptions";
    }
    
    function symbol() public pure override returns (string memory) {
        return "ETHSCRIPTIONS";
    }

    // ---------------------- Token URI & Media ----------------------

    /// @notice Returns the full data URI for a token
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // Find the transaction hash for this token ID (ethscription number)
        bytes32 txHash = tokenIdToTransactionHash[tokenId];
        if (!_ethscriptionExists(txHash)) revert TokenDoesNotExist();
        Ethscription storage etsc = ethscriptions[txHash];

        // Get content
        bytes memory content = getEthscriptionContent(txHash);

        // Build complete token URI using the library - it handles everything internally
        return EthscriptionsRendererLib.buildTokenURI(etsc, txHash, content);
    }

    /// @notice Get the media URI for an ethscription (image or animation_url)
    /// @param txHash The transaction hash of the ethscription
    /// @return mediaType Either "image" or "animation_url"
    /// @return mediaUri The data URI for the media
    function getMediaUri(bytes32 txHash) external view requireExists(txHash) returns (string memory mediaType, string memory mediaUri) {
        Ethscription storage etsc = ethscriptions[txHash];
        bytes memory content = getEthscriptionContent(txHash);
        return etsc.getMediaUri(content);
    }

    // -------------------- Data Retrieval --------------------

    /// @notice Get ethscription details (returns struct to avoid stack too deep)
    function getEthscription(bytes32 transactionHash) external view requireExists(transactionHash) returns (Ethscription memory) {
        return ethscriptions[transactionHash];
    }

    /// @notice Get content for an ethscription
    function getEthscriptionContent(bytes32 txHash) public view requireExists(txHash) returns (bytes memory) {
        Ethscription storage etsc = ethscriptions[txHash];
        address[] storage pointers = contentPointersBySha[etsc.content.contentSha];
        // Empty content is valid - returns "" for empty pointers array
        return pointers.read();
    }

    /// @notice Get ethscription details and content in a single call
    /// @param txHash The transaction hash to look up
    /// @return ethscription The ethscription struct
    /// @return content The content bytes
    function getEthscriptionWithContent(bytes32 txHash) external view requireExists(txHash) returns (Ethscription memory ethscription, bytes memory content) {
        ethscription = ethscriptions[txHash];
        address[] storage pointers = contentPointersBySha[ethscription.content.contentSha];
        // Empty content is valid - returns "" for empty pointers array
        content = pointers.read();
    }

    // ---------------- Ownership & Existence Checks ----------------

    /// @notice Check if an ethscription exists
    /// @param transactionHash The transaction hash to check
    /// @return true if the ethscription exists
    function exists(bytes32 transactionHash) external view returns (bool) {
        return _ethscriptionExists(transactionHash);
    }
    
    function exists(uint256 tokenId) external view returns (bool) {
        return _ethscriptionExists(tokenIdToTransactionHash[tokenId]);
    }

    /// @notice Get owner of an ethscription by transaction hash
    /// @dev Overload of ownerOf that accepts transaction hash instead of token ID
    function ownerOf(bytes32 transactionHash) external view requireExists(transactionHash) returns (address) {
        Ethscription storage etsc = ethscriptions[transactionHash];
        uint256 tokenId = etsc.ethscriptionNumber;

        return ownerOf(tokenId);
    }

    /// @notice Get the token ID (ethscription number) for a given transaction hash
    /// @param transactionHash The transaction hash to look up
    /// @return The token ID (ethscription number)
    function getTokenId(bytes32 transactionHash) external view requireExists(transactionHash) returns (uint256) {
        return ethscriptions[transactionHash].ethscriptionNumber;
    }

    // =============================================================
    //                   INTERNAL FUNCTIONS
    // =============================================================

    /// @dev Override _update to track previous owner and handle token transfers
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address from) {
        // Find the transaction hash for this token ID (ethscription number)
        bytes32 txHash = tokenIdToTransactionHash[tokenId];
        Ethscription storage etsc = ethscriptions[txHash];

        // Call parent implementation first to handle the actual update
        from = super._update(to, tokenId, auth);

        if (from == address(0)) {
            // Mint: emit once when minted directly to initial owner
            if (to == etsc.initialOwner) {
                emit EthscriptionTransferred(txHash, etsc.creator, to, tokenId);
            }
            // no previousOwner update or tokenManager call on mint
        } else {
            // Transfers (including creator -> address(0))
            emit EthscriptionTransferred(txHash, from, to, tokenId);
            etsc.previousOwner = from;

            // Notify protocol handler about the transfer if this ethscription has a protocol
            _notifyProtocolTransfer(txHash, from, to);
        }

        // Queue ethscription for batch proving at block boundary once proving is live
        _queueForProving(txHash);
    }

    /// @notice Check if an ethscription exists
    /// @dev An ethscription exists if it has been created (has a creator set)
    /// @param transactionHash The transaction hash to check
    /// @return True if the ethscription exists
    function _ethscriptionExists(bytes32 transactionHash) internal view returns (bool) {
        // Check if this ethscription has been created
        // We can't use _tokenExists here because we need the tokenId first
        // Instead, check if creator is set (ethscriptions are never created with zero creator)
        return ethscriptions[transactionHash].creator != address(0);
    }

    /// @notice Internal helper to store content and return its SHA
    /// @param content The raw content bytes to store
    /// @return contentSha The SHA256 hash of the content
    function _storeContent(bytes calldata content) internal returns (bytes32 contentSha) {
        // Compute SHA256 hash of content first
        contentSha = sha256(content);

        // Check if content already exists
        address[] storage existingPointers = contentPointersBySha[contentSha];

        // Check if content was already stored (pointers array will be non-empty for stored content)
        if (existingPointers.length > 0) {
            // Content already stored, just return the SHA
            return contentSha;
        }

        // Content doesn't exist, store it using SSTORE2
        address[] memory pointers = SSTORE2ChunkedStorageLib.store(content);

        // Only store non-empty pointer arrays (empty content doesn't need deduplication)
        if (pointers.length > 0) {
            contentPointersBySha[contentSha] = pointers;
        }

        return contentSha;
    }

    function _queueForProving(bytes32 txHash) internal {
        if (block.timestamp >= Constants.historicalBackfillApproxDoneAt) {
            prover.queueEthscription(txHash);
        }
    }

    /// @notice Call a protocol handler operation during ethscription creation
    /// @param txHash The ethscription transaction hash
    /// @param protocolParams The protocol parameters struct
    function _callProtocolOperation(
        bytes32 txHash,
        ProtocolParams calldata protocolParams
    ) internal {
        // Skip if no protocol specified
        if (bytes(protocolParams.protocolName).length == 0) {
            return;
        }

        // Track which protocol this ethscription uses
        protocolOf[txHash] = protocolParams.protocolName;

        address handler = protocolHandlers[protocolParams.protocolName];

        // Skip if no handler is registered
        if (handler == address(0)) {
            return;
        }

        // Encode the function call with operation name
        bytes memory callData = abi.encodeWithSignature(
            string.concat("op_", protocolParams.operation, "(bytes32,bytes)"),
            txHash,
            protocolParams.data
        );

        // Call the handler - failures don't revert ethscription creation
        (bool success, bytes memory returnData) = handler.call(callData);

        if (!success) {
            emit ProtocolHandlerFailed(txHash, protocolParams.protocolName, returnData);
        } else {
            emit ProtocolHandlerSuccess(txHash, protocolParams.protocolName, returnData);
        }
    }

    /// @notice Notify protocol handler about an ethscription transfer
    /// @param txHash The ethscription transaction hash
    /// @param from The address transferring from
    /// @param to The address transferring to
    function _notifyProtocolTransfer(
        bytes32 txHash,
        address from,
        address to
    ) internal {
        string memory protocol = protocolOf[txHash];

        // Skip if no protocol assigned
        if (bytes(protocol).length == 0) {
            return;
        }

        address handler = protocolHandlers[protocol];

        // Skip if no handler is registered
        if (handler == address(0)) {
            return;
        }

        // Use try/catch for cleaner error handling
        try IProtocolHandler(handler).onTransfer(txHash, from, to) {
            // onTransfer doesn't return data, so pass empty bytes
            emit ProtocolHandlerSuccess(txHash, protocol, "");
        } catch (bytes memory revertData) {
            emit ProtocolHandlerFailed(txHash, protocol, revertData);
        }
    }

    // =============================================================
    //                    PRIVATE FUNCTIONS
    // =============================================================

    /// @notice Emit all pending genesis events
    /// @dev Emits events in chronological order then clears the array
    function _emitPendingGenesisEvents() private {
        // Store the length before we start popping
        uint256 count = pendingGenesisEvents.length;

        // Emit events in the order they were created (FIFO)
        for (uint256 i = 0; i < count; i++) {
            bytes32 txHash = pendingGenesisEvents[i];

            // Get the ethscription data
            Ethscription storage etsc = ethscriptions[txHash];
            uint256 tokenId = etsc.ethscriptionNumber;

            // Emit events in the same order as live mints:
            // 1. Transfer (mint), 2. EthscriptionTransferred, 3. EthscriptionCreated

            if (etsc.initialOwner == address(0)) {
                // Token was minted to creator then burned
                // First emit mint to creator
                emit Transfer(address(0), etsc.creator, tokenId);
                // Then emit burn from creator to null address
                emit Transfer(etsc.creator, address(0), tokenId);
                // Emit Ethscriptions transfer event for the burn
                emit EthscriptionTransferred(
                    txHash,
                    etsc.creator,
                    address(0),
                    etsc.ethscriptionNumber
                );
            } else {
                // Token was minted directly to initial owner
                emit Transfer(address(0), etsc.initialOwner, tokenId);
                // Emit Ethscriptions transfer event
                emit EthscriptionTransferred(
                    txHash,
                    etsc.creator,
                    etsc.initialOwner,
                    etsc.ethscriptionNumber
                );
            }

            // Finally emit the creation event (matching the order of live mints)
            emit EthscriptionCreated(
                txHash,
                etsc.creator,
                etsc.initialOwner,
                etsc.content.contentUriHash,
                etsc.content.contentSha,
                etsc.ethscriptionNumber
            );
        }

        // Pop the array until it's empty
        while (pendingGenesisEvents.length > 0) {
            pendingGenesisEvents.pop();
        }
    }
}

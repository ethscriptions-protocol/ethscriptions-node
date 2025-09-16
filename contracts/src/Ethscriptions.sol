// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ERC721EthscriptionsUpgradeable.sol";
import {SSTORE2} from "solady/utils/SSTORE2.sol";
import {LibZip} from "solady/utils/LibZip.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import "./TokenManager.sol";
import "./EthscriptionsProver.sol";
import "./libraries/Predeploys.sol";
import "./L2/L1Block.sol";

/// @title Ethscriptions ERC-721 Contract
/// @notice Mints Ethscriptions as ERC-721 tokens based on L1 transaction data
/// @dev Uses ethscription number as token ID and name, while transaction hash remains the primary identifier for function calls
contract Ethscriptions is ERC721EthscriptionsUpgradeable {
    using LibString for *;
    
    /// @dev Maximum chunk size for SSTORE2 (24KB - 1 byte for STOP opcode)
    uint256 private constant CHUNK_SIZE = 24575;
    
    /// @dev L1Block predeploy for getting L1 block info
    L1Block constant L1_BLOCK = L1Block(Predeploys.L1_BLOCK_ATTRIBUTES);
    
    struct Ethscription {
        bytes32 contentSha;
        address creator;
        address initialOwner;
        address previousOwner;
        uint256 ethscriptionNumber;
        string mimetype;
        string mediaType;
        string mimeSubtype;
        bool esip6;
        bool isCompressed;  // True if content is FastLZ compressed
        // New fields for block tracking
        uint256 createdAt;      // Timestamp when created
        uint64 l1BlockNumber;   // L1 block number when created
        uint64 l2BlockNumber;   // L2 block number when created  
        bytes32 l1BlockHash;    // L1 block hash when created
    }
    
    struct TokenParams {
        string op;        // "deploy" or "mint"
        string protocol;  
        string tick;
        uint256 max;      // max supply for deploy
        uint256 lim;      // mint limit for deploy
        uint256 amt;      // amount for mint
    }
    
    struct CreateEthscriptionParams {
        bytes32 transactionHash;
        address initialOwner;
        bytes contentUri;  // Changed from string to bytes for efficient slicing
        string mimetype;
        string mediaType;
        string mimeSubtype;
        bool esip6;
        bool isCompressed;  // True if contentUri is FastLZ compressed
        TokenParams tokenParams;  // Token operation data (optional)
    }

    /// @dev Transaction hash => Ethscription data
    mapping(bytes32 => Ethscription) public ethscriptions;
    
    // TODO: add full URI to ethscriptions  struct return value
    // TODO: show something for text
    
    /// @dev Content SHA => SSTORE2 content pointers (single source of truth)
    /// If array is non-empty, content exists. For ESIP6, we reuse existing pointers.
    mapping(bytes32 => address[]) internal _contentBySha;
    
    /// @dev Total number of ethscriptions created
    uint256 public totalSupply;

    /// @dev Mapping from ethscription number (token ID) to transaction hash
    mapping(uint256 => bytes32) public tokenIdToTransactionHash;

    /// @dev Token Manager contract (pre-deployed at known address)
    TokenManager public constant tokenManager = TokenManager(Predeploys.TOKEN_MANAGER);
    
    /// @dev Ethscriptions Prover contract (pre-deployed at known address)
    EthscriptionsProver public constant prover = EthscriptionsProver(Predeploys.ETHSCRIPTIONS_PROVER);
    
    /// @notice Emitted when a new ethscription is created
    event EthscriptionCreated(
        bytes32 indexed transactionHash,
        address indexed creator,
        address indexed initialOwner,
        bytes32 contentSha,
        uint256 ethscriptionNumber,
        uint256 pointerCount
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

    error DuplicateContent();
    error InvalidCreator();
    error EmptyContentUri();
    error EthscriptionAlreadyExists();
    error EthscriptionDoesNotExist();

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

    /// @notice Modifier to require that an ethscription exists
    /// @param transactionHash The transaction hash to check
    modifier requireExists(bytes32 transactionHash) {
        if (!_ethscriptionExists(transactionHash)) revert EthscriptionDoesNotExist();
        _;
    }

    
    function name() public pure override returns (string memory) {
        return "Ethscriptions";
    }
    
    function symbol() public pure override returns (string memory) {
        return "ETHSCRIPTIONS";
    }

    /// @notice Create (mint) a new ethscription token
    /// @dev Called via system transaction with msg.sender spoofed as the actual creator
    /// @param params Struct containing all ethscription creation parameters
    function createEthscription(
        CreateEthscriptionParams calldata params
    ) external returns (uint256 tokenId) {
        address creator = msg.sender;
        
        if (creator == address(0)) revert InvalidCreator();
        // Allow address(0) as initial owner for burned ethscriptions
        if (params.contentUri.length == 0) revert EmptyContentUri();
        if (_ethscriptionExists(params.transactionHash)) revert EthscriptionAlreadyExists();

        // Store content and get content SHA
        bytes32 contentSha = _storeContent(params.contentUri, params.isCompressed, params.esip6);

        ethscriptions[params.transactionHash] = Ethscription({
            contentSha: contentSha,
            creator: creator,
            initialOwner: params.initialOwner,
            previousOwner: creator, // Initially same as creator
            ethscriptionNumber: totalSupply,
            mimetype: params.mimetype,
            mediaType: params.mediaType,
            mimeSubtype: params.mimeSubtype,
            esip6: params.esip6,
            isCompressed: params.isCompressed,
            createdAt: block.timestamp,
            l1BlockNumber: L1_BLOCK.number(),
            l2BlockNumber: uint64(block.number),
            l1BlockHash: L1_BLOCK.hash()
        });

        // Use ethscription number as token ID
        tokenId = totalSupply;

        // Store the mapping from token ID to transaction hash
        tokenIdToTransactionHash[tokenId] = params.transactionHash;

        totalSupply++;

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
            contentSha,
            tokenId,
            _contentBySha[contentSha].length
        );

        // Handle token operations - delegate all logic to TokenManager
        // No need to check if it's a token operation, handleTokenOperation will check the op
        tokenManager.handleTokenOperation(
            params.transactionHash,
            params.initialOwner,
            params.tokenParams
        );
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

    // transferFrom is inherited from base and already supports transfers to address(0)

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
        require(
            ethscriptions[transactionHash].previousOwner == previousOwner,
            "Previous owner mismatch"
        );

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

        require(successCount > 0, "No successful transfers");
    }

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
            tokenManager.handleTokenTransfer(txHash, from, to);
        }

        prover.proveEthscriptionData(txHash);
    }

    /// @notice Get ethscription details (returns struct to avoid stack too deep)
    function getEthscription(bytes32 transactionHash) external view requireExists(transactionHash) returns (Ethscription memory) {
        return ethscriptions[transactionHash];
    }
    
    function ownerOf(bytes32 transactionHash) external view requireExists(transactionHash) returns (address) {
        Ethscription memory etsc = ethscriptions[transactionHash];
        uint256 tokenId = etsc.ethscriptionNumber;
        // This will revert if the token is burned (has no owner)
        return ownerOf(tokenId);
    }

    /// @notice Returns the full data URI for a token
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // Find the transaction hash for this token ID (ethscription number)
        bytes32 txHash = tokenIdToTransactionHash[tokenId];
        require(_ethscriptionExists(txHash), "Token does not exist");
        Ethscription storage etsc = ethscriptions[txHash];

        // Build the JSON metadata
        string memory json = string.concat(
            '{"name":"Ethscription #',
            tokenId.toString(),
            '","description":"Ethscription #',
            tokenId.toString(),
            ' created by ',
            etsc.creator.toHexString(),
            '","image":"',
            _getContentDataURI(tokenIdToTransactionHash[tokenId]).escapeJSON(),
            '","attributes":',
            _getAttributes(etsc),
            '}'
        );

        // Return as base64-encoded data URI
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    /// @dev Helper function to build attributes JSON array
    function _getAttributes(Ethscription storage etsc) internal view returns (string memory) {
        // Build in chunks to avoid stack too deep
        string memory part1 = string.concat(
            '[{"trait_type":"Ethscription Number","display_type":"number","value":',
            etsc.ethscriptionNumber.toString(),
            '},{"trait_type":"Creator","value":"',
            etsc.creator.toHexString(),
            '"},{"trait_type":"Initial Owner","value":"',
            etsc.initialOwner.toHexString(),
            '"},{"trait_type":"Content SHA","value":"',
            uint256(etsc.contentSha).toHexString()
        );

        string memory part2 = string.concat(
            '"},{"trait_type":"MIME Type","value":"',
            etsc.mimetype.escapeJSON(),
            '"},{"trait_type":"Media Type","value":"',
            etsc.mediaType.escapeJSON(),
            '"},{"trait_type":"MIME Subtype","value":"',
            etsc.mimeSubtype.escapeJSON(),
            '"},{"trait_type":"ESIP-6","value":"',
            etsc.esip6 ? "true" : "false"
        );

        string memory part3 = string.concat(
            '"},{"trait_type":"Compressed","value":"',
            etsc.isCompressed ? "true" : "false",
            '"},{"trait_type":"L1 Block Number","display_type":"number","value":',
            uint256(etsc.l1BlockNumber).toString(),
            '},{"trait_type":"L2 Block Number","display_type":"number","value":',
            uint256(etsc.l2BlockNumber).toString(),
            '},{"trait_type":"Created At","display_type":"date","value":',
            etsc.createdAt.toString(),
            '}]'
        );

        return string.concat(part1, part2, part3);
    }

    /// @dev Helper function to get content as data URI
    function _getContentDataURI(bytes32 txHash) internal view returns (string memory) {
        Ethscription memory etsc = ethscriptions[txHash];
        address[] memory pointers = _contentBySha[etsc.contentSha];
        require(pointers.length > 0, "No content stored");

        bytes memory content;

        if (pointers.length == 1) {
            // Single pointer - simple read
            content = SSTORE2.read(pointers[0]);
        } else {
            // Multiple pointers - efficient assembly concatenation
            assembly {
                // Calculate total size needed
                let totalSize := 0
                let pointersLength := mload(pointers)
                let dataOffset := 0x01 // SSTORE2 data starts after STOP opcode (0x00)

                for { let i := 0 } lt(i, pointersLength) { i := add(i, 1) } {
                    let pointer := mload(add(pointers, add(0x20, mul(i, 0x20))))
                    let codeSize := extcodesize(pointer)
                    totalSize := add(totalSize, sub(codeSize, dataOffset))
                }

                // Allocate result buffer
                content := mload(0x40)
                let contentPtr := add(content, 0x20)

                // Copy data from each pointer
                let currentOffset := 0
                for { let i := 0 } lt(i, pointersLength) { i := add(i, 1) } {
                    let pointer := mload(add(pointers, add(0x20, mul(i, 0x20))))
                    let codeSize := extcodesize(pointer)
                    let chunkSize := sub(codeSize, dataOffset)
                    extcodecopy(pointer, add(contentPtr, currentOffset), dataOffset, chunkSize)
                    currentOffset := add(currentOffset, chunkSize)
                }

                // Update length and free memory pointer with proper alignment
                mstore(content, totalSize)
                mstore(0x40, and(add(add(contentPtr, totalSize), 0x1f), not(0x1f)))
            }
        }

        // Decompress if needed
        if (etsc.isCompressed) {
            content = LibZip.flzDecompress(content);
        }

        return string(content);
    }

    /// @notice Get current owner of an ethscription
    /// @dev Returns the actual owner, which may be address(0) for null-owned tokens or unminted tokens
    function currentOwner(bytes32 transactionHash) external view requireExists(transactionHash) returns (address) {
        Ethscription memory etsc = ethscriptions[transactionHash];
        uint256 tokenId = etsc.ethscriptionNumber;
        // Use _ownerOf which returns address(0) for non-existent tokens
        return ownerOf(tokenId);
    }

    /// @notice Get the token ID (ethscription number) for a given transaction hash
    /// @param transactionHash The transaction hash to look up
    /// @return The token ID (ethscription number)
    function getTokenId(bytes32 transactionHash) external view requireExists(transactionHash) returns (uint256) {
        return ethscriptions[transactionHash].ethscriptionNumber;
    }

    /// @notice Get the number of content pointers for an ethscription
    function getContentPointerCount(bytes32 transactionHash) external view requireExists(transactionHash) returns (uint256) {
        Ethscription memory etsc = ethscriptions[transactionHash];
        return _contentBySha[etsc.contentSha].length;
    }
    
    /// @notice Get all content pointers for an ethscription
    function getContentPointers(bytes32 transactionHash) external view requireExists(transactionHash) returns (address[] memory) {
        Ethscription memory etsc = ethscriptions[transactionHash];
        return _contentBySha[etsc.contentSha];
    }
    
    /// @notice Read a specific chunk of content
    /// @param transactionHash The ethscription transaction hash
    /// @param index The chunk index to read
    /// @return The chunk data
    function readChunk(bytes32 transactionHash, uint256 index) external view requireExists(transactionHash) returns (bytes memory) {
        Ethscription memory etsc = ethscriptions[transactionHash];
        address[] memory pointers = _contentBySha[etsc.contentSha];
        require(index < pointers.length, "Chunk index out of bounds");
        return SSTORE2.read(pointers[index]);
    }
    
    /// @notice Internal helper to store content and return its SHA
    /// @param contentUri The content to store
    /// @param isCompressed Whether the content is compressed
    /// @param esip6 Whether this is an ESIP6 ethscription
    /// @return contentSha The SHA256 hash of the content
    function _storeContent(
        bytes calldata contentUri,
        bool isCompressed,
        bool esip6
    ) internal returns (bytes32 contentSha) {
        // If compressed, decompress to compute SHA of original content
        bytes memory actualContent = isCompressed 
            ? LibZip.flzDecompress(contentUri)
            : contentUri;
        
        // Compute SHA of original (decompressed) content
        contentSha = sha256(actualContent);
        
        // Check if content already exists
        address[] storage pointers = _contentBySha[contentSha];
        uint256 existingLength = pointers.length;
        
        if (existingLength > 0 && !esip6) {
            revert DuplicateContent();
        }
        
        if (existingLength == 0) {
            // New content: chunk and store via SSTORE2
            uint256 contentLength = contentUri.length;
            uint256 numChunks = (contentLength + CHUNK_SIZE - 1) / CHUNK_SIZE;
            
            for (uint256 i = 0; i < numChunks; i++) {
                uint256 start = i * CHUNK_SIZE;
                uint256 end = start + CHUNK_SIZE;
                if (end > contentLength) {
                    end = contentLength;
                }
                
                // Calldata slicing avoids copying to memory here, but SSTORE2.write will copy the chunk to memory before storing.
                bytes calldata chunk = contentUri[start:end];
                
                // Store chunk via SSTORE2
                address pointer = SSTORE2.write(chunk);
                pointers.push(pointer);
            }
        }
        // For ESIP6 with existing content, pointers already contains the addresses
    }
}

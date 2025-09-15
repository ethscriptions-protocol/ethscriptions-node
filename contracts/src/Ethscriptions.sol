// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
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
/// @dev Uses transaction hash as token ID to maintain consistency with existing system
contract Ethscriptions is ERC721Upgradeable {
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
    
    /// @dev Content SHA => SSTORE2 content pointers (single source of truth)
    /// If array is non-empty, content exists. For ESIP6, we reuse existing pointers.
    mapping(bytes32 => address[]) internal _contentBySha;
    
    /// @dev Total number of ethscriptions created
    uint256 public totalEthscriptions;
    
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
        if (ethscriptions[params.transactionHash].creator != address(0)) revert EthscriptionAlreadyExists();

        // Store content and get content SHA
        bytes32 contentSha = _storeContent(params.contentUri, params.isCompressed, params.esip6);

        ethscriptions[params.transactionHash] = Ethscription({
            contentSha: contentSha,
            creator: creator,
            initialOwner: params.initialOwner,
            previousOwner: creator, // Initially same as creator
            ethscriptionNumber: totalEthscriptions,
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

        tokenId = uint256(params.transactionHash);
        
        totalEthscriptions++;

        // If initial owner is zero (burned), mint to creator then burn
        if (params.initialOwner == address(0)) {
            _mint(creator, tokenId);
            _burn(tokenId);
        } else {
            _mint(params.initialOwner, tokenId);
        }

        emit EthscriptionCreated(
            params.transactionHash,
            creator,
            params.initialOwner,
            contentSha,
            totalEthscriptions - 1,
            _contentBySha[contentSha].length
        );

        // Emit Ethscriptions protocol transfer event (from creator to initial owner)
        emit EthscriptionTransferred(
            params.transactionHash,
            creator,
            params.initialOwner,
            totalEthscriptions - 1
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
    /// @param transactionHash The ethscription to transfer
    function transferEthscription(
        address to,
        bytes32 transactionHash
    ) external {
        uint256 tokenId = uint256(transactionHash);
        // Standard ERC721 transfer will handle authorization
        transferFrom(msg.sender, to, tokenId);
    }
    
    /// @notice Override transferFrom to allow burns when transferring to address(0)
    /// @dev Removes the address(0) check to allow burns through transfers
    function transferFrom(address from, address to, uint256 tokenId) public virtual override {
        // Removed the check for to == address(0) to allow burns
        // Setting an "auth" arguments enables the `_isAuthorized` check which verifies that the token exists
        // (from != 0). Therefore, it is not needed to verify that the return value is not 0 here.
        address previousOwner = _update(to, tokenId, _msgSender());
        if (previousOwner != from) {
            revert ERC721IncorrectOwner(from, tokenId, previousOwner);
        }
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
    ) external {
        // Verify the previous owner matches
        require(
            ethscriptions[transactionHash].previousOwner == previousOwner,
            "Previous owner mismatch"
        );

        uint256 tokenId = uint256(transactionHash);
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
            uint256 tokenId = uint256(transactionHashes[i]);

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
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);
        bytes32 txHash = bytes32(tokenId);

        // Update previous owner if this is a transfer (not mint)
        if (from != address(0)) {
            ethscriptions[txHash].previousOwner = from;

            // Emit Ethscriptions protocol transfer event
            // This preserves the protocol semantics where 'from' is the initiator
            emit EthscriptionTransferred(
                txHash,
                from,
                to,
                ethscriptions[txHash].ethscriptionNumber
            );

            // Let TokenManager handle any token transfers
            tokenManager.handleTokenTransfer(txHash, from, to);
        }

        prover.proveEthscriptionData(txHash);

        // Call parent implementation
        return super._update(to, tokenId, auth);
    }

    /// @notice Get ethscription details (returns struct to avoid stack too deep)
    function getEthscription(bytes32 transactionHash) external view returns (Ethscription memory) {
        Ethscription memory etsc = ethscriptions[transactionHash];
        if (etsc.creator == address(0)) revert EthscriptionDoesNotExist();
        return etsc;
    }

    /// @notice Returns the full data URI for a token
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        bytes32 txHash = bytes32(tokenId);
        Ethscription memory etsc = ethscriptions[txHash];
        require(etsc.creator != address(0), "Token does not exist");

        // Get the content data URI
        string memory imageDataURI = _getContentDataURI(txHash);

        // Build attributes array
        string memory attributes = string.concat(
            '[{"trait_type":"Ethscription Number","display_type":"number","value":',
            etsc.ethscriptionNumber.toString(),
            '},{"trait_type":"Creator","value":"',
            etsc.creator.toHexString(),
            '"},{"trait_type":"Initial Owner","value":"',
            etsc.initialOwner.toHexString(),
            '"},{"trait_type":"Content SHA","value":"',
            uint256(etsc.contentSha).toHexString(),
            '"},{"trait_type":"MIME Type","value":"',
            etsc.mimetype,
            '"},{"trait_type":"Media Type","value":"',
            etsc.mediaType,
            '"},{"trait_type":"MIME Subtype","value":"',
            etsc.mimeSubtype,
            '"},{"trait_type":"ESIP-6","value":"',
            etsc.esip6 ? "true" : "false",
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

        // Build the JSON metadata
        string memory json = string.concat(
            '{"name":"Ethscription #',
            etsc.ethscriptionNumber.toString(),
            '","description":"Ethscription #',
            etsc.ethscriptionNumber.toString(),
            ' created by ',
            etsc.creator.toHexString(),
            '","image":"',
            imageDataURI,
            '","attributes":',
            attributes,
            '}'
        );

        // Return as base64-encoded data URI
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
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
    function currentOwner(bytes32 transactionHash) external view returns (address) {
        Ethscription memory etsc = ethscriptions[transactionHash];
        if (etsc.creator == address(0)) revert EthscriptionDoesNotExist();
        uint256 tokenId = uint256(transactionHash);
        return _ownerOf(tokenId);
    }

    /// @notice Get the number of content pointers for an ethscription
    function getContentPointerCount(bytes32 transactionHash) external view returns (uint256) {
        Ethscription memory etsc = ethscriptions[transactionHash];
        if (etsc.creator == address(0)) revert EthscriptionDoesNotExist();
        return _contentBySha[etsc.contentSha].length;
    }
    
    /// @notice Get all content pointers for an ethscription
    function getContentPointers(bytes32 transactionHash) external view returns (address[] memory) {
        Ethscription memory etsc = ethscriptions[transactionHash];
        if (etsc.creator == address(0)) revert EthscriptionDoesNotExist();
        return _contentBySha[etsc.contentSha];
    }
    
    /// @notice Read a specific chunk of content
    /// @param transactionHash The ethscription transaction hash
    /// @param index The chunk index to read
    /// @return The chunk data
    function readChunk(bytes32 transactionHash, uint256 index) external view returns (bytes memory) {
        Ethscription memory etsc = ethscriptions[transactionHash];
        if (etsc.creator == address(0)) revert EthscriptionDoesNotExist();
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

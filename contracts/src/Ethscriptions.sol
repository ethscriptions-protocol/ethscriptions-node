// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {SSTORE2} from "solady/utils/SSTORE2.sol";
import {LibZip} from "solady/utils/LibZip.sol";
import "./TokenManager.sol";
import "./EthscriptionsProver.sol";
import "./libraries/Predeploys.sol";
import "./L2/L1Block.sol";

/// @title Ethscriptions ERC-721 Contract
/// @notice Mints Ethscriptions as ERC-721 tokens based on L1 transaction data
/// @dev Uses transaction hash as token ID to maintain consistency with existing system
contract Ethscriptions is ERC721Upgradeable {
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

        // Get L1 block info from L1Block predeploy
        (uint64 l1BlockNum, bytes32 l1BlockHash) = L1_BLOCK.getL1BlockInfo(block.number);

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
            l1BlockNumber: l1BlockNum,
            l2BlockNumber: uint64(block.number),
            l1BlockHash: l1BlockHash
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
    /// @param to The recipient address
    /// @param transactionHash The ethscription to transfer
    function transferEthscription(
        address to,
        bytes32 transactionHash
    ) external {
        uint256 tokenId = uint256(transactionHash);
        // Standard ERC721 transfer will handle authorization
        transferFrom(msg.sender, to, tokenId);
    }
    
    /// @notice Transfer an ethscription with previous owner validation (ESIP-2)
    /// @dev Called via system transaction with msg.sender spoofed as 'from'
    /// @param to The recipient address
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
        // Standard ERC721 transfer will handle current owner authorization
        transferFrom(msg.sender, to, tokenId);
    }

    /// @dev Override _update to track previous owner and handle token transfers
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);
        bytes32 txHash = bytes32(tokenId);
        
        // Update previous owner if this is a transfer (not mint)
        if (from != address(0)) {
            ethscriptions[txHash].previousOwner = from;
            
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
        
        address[] memory pointers = _contentBySha[etsc.contentSha];
        require(pointers.length > 0, "No content stored");
        
        if (pointers.length == 1) {
            // Single pointer - simple read
            bytes memory content = SSTORE2.read(pointers[0]);
            // Decompress if needed
            if (etsc.isCompressed) {
                content = LibZip.flzDecompress(content);
            }
            return string(content);
        }
        
        // Multiple pointers - efficient assembly concatenation
        bytes memory result;
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
            result := mload(0x40)
            let resultPtr := add(result, 0x20)
            
            // Copy data from each pointer
            let currentOffset := 0
            for { let i := 0 } lt(i, pointersLength) { i := add(i, 1) } {
                let pointer := mload(add(pointers, add(0x20, mul(i, 0x20))))
                let codeSize := extcodesize(pointer)
                let chunkSize := sub(codeSize, dataOffset)
                extcodecopy(pointer, add(resultPtr, currentOffset), dataOffset, chunkSize)
                currentOffset := add(currentOffset, chunkSize)
            }
            
            // Update length and free memory pointer with proper alignment
            mstore(result, totalSize)
            mstore(0x40, and(add(add(resultPtr, totalSize), 0x1f), not(0x1f)))
        }
        
        // Decompress if needed
        if (etsc.isCompressed) {
            result = LibZip.flzDecompress(result);
        }
        return string(result);
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

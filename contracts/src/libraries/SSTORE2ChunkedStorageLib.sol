// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SSTORE2} from "solady/utils/SSTORE2.sol";

/// @title SSTORE2ChunkedStorageLib
/// @notice Generic library for storing and reading large content using chunked SSTORE2
/// @dev Handles content larger than SSTORE2's single-contract limit by splitting into chunks
library SSTORE2ChunkedStorageLib {
    /// @dev Maximum chunk size for SSTORE2 (24KB - 1 byte for STOP opcode)
    uint256 internal constant CHUNK_SIZE = 24575;

    /// @notice Store content in chunked SSTORE2 contracts
    /// @param content The content to store
    /// @return pointers Array of SSTORE2 contract addresses containing the chunks
    function store(bytes calldata content)
        internal
        returns (address[] memory pointers)
    {
        uint256 contentLength = content.length;

        if (contentLength == 0) {
            // Return empty array for empty content
            return pointers;
        }

        // Calculate number of chunks needed
        uint256 numChunks = (contentLength + CHUNK_SIZE - 1) / CHUNK_SIZE;
        pointers = new address[](numChunks);

        // Split content into chunks and store each via SSTORE2
        for (uint256 i = 0; i < numChunks; i++) {
            uint256 start = i * CHUNK_SIZE;
            uint256 end = start + CHUNK_SIZE;
            if (end > contentLength) {
                end = contentLength;
            }

            // Use calldata slicing for efficiency
            bytes calldata chunk = content[start:end];

            // Store chunk and save pointer
            pointers[i] = SSTORE2.write(chunk);
        }

        return pointers;
    }

    /// @notice Read content from storage array of SSTORE2 pointers
    /// @param pointers Storage array of SSTORE2 contract addresses
    /// @return content The concatenated content from all chunks
    function read(address[] storage pointers)
        internal
        view
        returns (bytes memory content)
    {
        uint256 length = pointers.length;

        if (length == 0) {
            return "";
        }

        if (length == 1) {
            return SSTORE2.read(pointers[0]);
        }

        // Multiple chunks - use assembly for efficient concatenation
        assembly {
            // Calculate total size needed
            let totalSize := 0
            let pointersSlot := pointers.slot
            let pointersLength := sload(pointersSlot)
            let dataOffset := 0x01 // SSTORE2 data starts after STOP opcode

            for { let i := 0 } lt(i, pointersLength) { i := add(i, 1) } {
                // Storage array elements are at keccak256(slot) + index
                mstore(0, pointersSlot)
                let elementSlot := add(keccak256(0, 0x20), i)
                let pointer := sload(elementSlot)
                let codeSize := extcodesize(pointer)
                totalSize := add(totalSize, sub(codeSize, dataOffset))
            }

            // Allocate result buffer
            content := mload(0x40)
            let contentPtr := add(content, 0x20)

            // Copy data from each pointer
            let currentOffset := 0
            for { let i := 0 } lt(i, pointersLength) { i := add(i, 1) } {
                mstore(0, pointersSlot)
                let elementSlot := add(keccak256(0, 0x20), i)
                let pointer := sload(elementSlot)
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
}

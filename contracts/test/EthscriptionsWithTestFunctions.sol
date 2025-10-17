// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../src/Ethscriptions.sol";
import {SSTORE2} from "solady/utils/SSTORE2.sol";

/// @title EthscriptionsWithTestFunctions
/// @notice Test contract that extends Ethscriptions with additional functions for testing
/// @dev These functions expose internal storage details useful for tests but not needed in production
/// @dev Usage: Deploy this contract instead of regular Ethscriptions in test setup, then cast to this type
contract EthscriptionsWithTestFunctions is Ethscriptions {

    /// @notice Get the number of content pointers for an ethscription
    /// @dev Test-only function to inspect storage chunks
    function getContentPointerCount(bytes32 transactionHash) external view requireExists(transactionHash) returns (uint256) {
        Ethscription storage etsc = ethscriptions[transactionHash];
        return contentPointersBySha[etsc.content.contentSha].length;
    }

    /// @notice Get all content pointers for an ethscription
    /// @dev Test-only function to inspect SSTORE2 addresses
    function getContentPointers(bytes32 transactionHash) external view requireExists(transactionHash) returns (address[] memory) {
        Ethscription storage etsc = ethscriptions[transactionHash];
        return contentPointersBySha[etsc.content.contentSha];
    }

    /// @notice Read a specific chunk of content
    /// @dev Test-only function to read individual SSTORE2 chunks
    /// @param transactionHash The ethscription transaction hash
    /// @param index The chunk index to read
    /// @return The chunk data
    function readChunk(bytes32 transactionHash, uint256 index) external view requireExists(transactionHash) returns (bytes memory) {
        Ethscription storage etsc = ethscriptions[transactionHash];
        address[] storage pointers = contentPointersBySha[etsc.content.contentSha];
        require(index < pointers.length, "Chunk index out of bounds");
        return SSTORE2.read(pointers[index]);
    }
}
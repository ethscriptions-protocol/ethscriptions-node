// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockL2ToL1MessagePasser
/// @notice Mock implementation of L2ToL1MessagePasser for testing
/// @dev This is a simplified version without OP Stack dependencies
contract MockL2ToL1MessagePasser {
    /// @notice Includes the message hashes for all withdrawals
    mapping(bytes32 => bool) public sentMessages;
    
    /// @notice A unique value hashed with each withdrawal
    uint256 internal msgNonce;
    
    /// @notice Emitted any time a withdrawal is initiated
    event MessagePassed(
        uint256 indexed nonce,
        address indexed sender,
        address indexed target,
        uint256 value,
        uint256 gasLimit,
        bytes data,
        bytes32 withdrawalHash
    );
    
    /// @notice Sends a message from L2 to L1
    /// @param _target   Address to call on L1 execution
    /// @param _gasLimit Minimum gas limit for executing the message on L1
    /// @param _data     Data to forward to L1 target
    function initiateWithdrawal(address _target, uint256 _gasLimit, bytes memory _data) public payable {
        bytes32 withdrawalHash = keccak256(
            abi.encode(
                msgNonce,
                msg.sender,
                _target,
                msg.value,
                _gasLimit,
                _data
            )
        );
        
        sentMessages[withdrawalHash] = true;
        
        emit MessagePassed(msgNonce, msg.sender, _target, msg.value, _gasLimit, _data, withdrawalHash);
        
        unchecked {
            ++msgNonce;
        }
    }
    
    /// @notice Get the current message nonce
    function messageNonce() public view returns (uint256) {
        return msgNonce;
    }
}
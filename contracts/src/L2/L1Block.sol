// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Constants } from "../libraries/Constants.sol";

/// @custom:proxied
/// @custom:predeploy 0x4200000000000000000000000000000000000015
/// @title L1Block
/// @notice The L1Block predeploy gives users access to information about the last known L1 block.
///         Values within this contract are updated once per epoch (every L1 block) and can only be
///         set by the "depositor" account, a special system address. Depositor account transactions
///         are created by the protocol whenever we move to a new epoch.
contract L1Block {
    /// @notice Address of the special depositor account.
    function DEPOSITOR_ACCOUNT() public pure returns (address addr_) {
        addr_ = Constants.DEPOSITOR_ACCOUNT;
    }

    /// @notice The latest L1 block number known by the L2 system.
    uint64 public number;

    /// @notice The latest L1 timestamp known by the L2 system.
    uint64 public timestamp;

    /// @notice The latest L1 base fee.
    uint256 public basefee;

    /// @notice The latest L1 blockhash.
    bytes32 public hash;

    /// @notice The number of L2 blocks in the same epoch.
    uint64 public sequenceNumber;

    /// @notice The scalar value applied to the L1 blob base fee portion of the blob-capable L1 cost func.
    uint32 public blobBaseFeeScalar;

    /// @notice The scalar value applied to the L1 base fee portion of the blob-capable L1 cost func.
    uint32 public baseFeeScalar;

    /// @notice The versioned hash to authenticate the batcher by.
    bytes32 public batcherHash;

    /// @notice The overhead value applied to the L1 portion of the transaction fee.
    /// @custom:legacy
    uint256 public l1FeeOverhead;

    /// @notice The scalar value applied to the L1 portion of the transaction fee.
    /// @custom:legacy
    uint256 public l1FeeScalar;

    /// @notice The latest L1 blob base fee.
    uint256 public blobBaseFee;

    mapping(uint256 => L1BlockInfo) public l2ToL1BlockMapping;

    struct L1BlockInfo {
        uint64 l1BlockNumber;
        bytes32 l1BlockHash;
    }

    /// @notice Store current L1 block info for the current L2 block
    /// @dev For now, anyone can call this (will be restricted later)
    function setL1BlockInfoForCurrentBlock() external {
        L1BlockInfo storage s = l2ToL1BlockMapping[block.number];
        
        if (s.l1BlockNumber != 0) {
            s.l1BlockNumber = number;
            s.l1BlockHash = hash;
        }
    }

    /// @notice Get L1 block info for current L2 block or from mapping
    /// @return l1BlockNumber The L1 block number
    /// @return l1BlockHash The L1 block hash
    function getL1BlockInfo(uint256 l2BlockNumber) external view returns (
        uint64 l1BlockNumber,
        bytes32 l1BlockHash
    ) {
        // First check if there's a specific mapping for this L2 block
        L1BlockInfo memory info = l2ToL1BlockMapping[l2BlockNumber];
        if (info.l1BlockNumber != 0) {
            return (info.l1BlockNumber, info.l1BlockHash);
        }
        
        revert("No L1 block info found");
    }

    /// @notice Updates the L1 block values for an Ecotone upgraded chain.
    /// Params are packed and passed in as raw msg.data instead of ABI to reduce calldata size.
    /// Params are expected to be in the following order:
    ///   1. _baseFeeScalar      L1 base fee scalar
    ///   2. _blobBaseFeeScalar  L1 blob base fee scalar
    ///   3. _sequenceNumber     Number of L2 blocks since epoch start.
    ///   4. _timestamp          L1 timestamp.
    ///   5. _number             L1 blocknumber.
    ///   6. _basefee            L1 base fee.
    ///   7. _blobBaseFee        L1 blob base fee.
    ///   8. _hash               L1 blockhash.
    ///   9. _batcherHash        Versioned hash to authenticate batcher by.
    function setL1BlockValuesEcotone() external {
        address depositor = DEPOSITOR_ACCOUNT();
        assembly {
            // Revert if the caller is not the depositor account.
            if xor(caller(), depositor) {
                mstore(0x00, 0x3cc50b45) // 0x3cc50b45 is the 4-byte selector of "NotDepositor()"
                revert(0x1C, 0x04) // returns the stored 4-byte selector from above
            }
            // sequencenum (uint64), blobBaseFeeScalar (uint32), baseFeeScalar (uint32)
            sstore(sequenceNumber.slot, shr(128, calldataload(4)))
            // number (uint64) and timestamp (uint64)
            sstore(number.slot, shr(128, calldataload(20)))
            sstore(basefee.slot, calldataload(36)) // uint256
            sstore(blobBaseFee.slot, calldataload(68)) // uint256
            sstore(hash.slot, calldataload(100)) // bytes32
            sstore(batcherHash.slot, calldataload(132)) // bytes32
        }
    }
}

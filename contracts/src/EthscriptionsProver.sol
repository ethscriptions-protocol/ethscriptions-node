// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./Ethscriptions.sol";
import "./L2/L2ToL1MessagePasser.sol";
import "./L2/L1Block.sol";
import "./libraries/Predeploys.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title EthscriptionsProver
/// @notice Proves Ethscription ownership and token balances to L1 via OP Stack
/// @dev Uses L2ToL1MessagePasser to send provable messages to L1
contract EthscriptionsProver {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    // =============================================================
    //                           STRUCTS
    // =============================================================

    /// @notice Info stored when an ethscription is queued for proving
    struct QueuedProof {
        uint256 l2BlockNumber;
        uint256 l2BlockTimestamp;
        bytes32 l1BlockHash;
        uint256 l1BlockNumber;
    }

    /// @notice Struct for ethscription data proof
    struct EthscriptionDataProof {
        bytes32 ethscriptionTxHash;
        bytes32 contentSha;
        bytes32 contentUriHash;
        address creator;
        address currentOwner;
        address previousOwner;
        uint256 ethscriptionNumber;
        bool esip6;
        bytes32 l1BlockHash;
        uint256 l1BlockNumber;
        uint256 l2BlockNumber;
        uint256 l2Timestamp;
    }

    // =============================================================
    //                         CONSTANTS
    // =============================================================

    /// @notice L1Block contract address for access control
    address constant L1_BLOCK = Predeploys.L1_BLOCK_ATTRIBUTES;

    /// @notice L2ToL1MessagePasser predeploy address on OP Stack
    L2ToL1MessagePasser constant L2_TO_L1_MESSAGE_PASSER =
        L2ToL1MessagePasser(Predeploys.L2_TO_L1_MESSAGE_PASSER);

    /// @notice The Ethscriptions contract (pre-deployed at known address)
    Ethscriptions constant ethscriptions = Ethscriptions(Predeploys.ETHSCRIPTIONS);

    // =============================================================
    //                      STATE VARIABLES
    // =============================================================

    /// @notice Set of all ethscription transaction hashes queued for proving
    EnumerableSet.Bytes32Set private queuedEthscriptions;

    /// @notice Mapping from ethscription tx hash to its queued proof info
    mapping(bytes32 => QueuedProof) private queuedProofInfo;

    // =============================================================
    //                      CUSTOM ERRORS
    // =============================================================

    error OnlyEthscriptions();
    error OnlyL1Block();

    // =============================================================
    //                          EVENTS
    // =============================================================

    /// @notice Emitted when an ethscription data proof is sent to L1
    event EthscriptionDataProofSent(
        bytes32 indexed ethscriptionTxHash,
        uint256 indexed l2BlockNumber,
        uint256 l2Timestamp
    );

    // =============================================================
    //                    EXTERNAL FUNCTIONS
    // =============================================================

    /// @notice Queue an ethscription for proving
    /// @dev Only callable by the Ethscriptions contract
    /// @param txHash The transaction hash of the ethscription
    function queueEthscription(bytes32 txHash) external virtual {
        if (msg.sender != address(ethscriptions)) revert OnlyEthscriptions();

        // Add to the set (deduplicates automatically)
        if (queuedEthscriptions.add(txHash)) {
            // Only store info if this is the first time we're queueing this txHash
            // Capture the L1 block hash and number at the time of queuing
            L1Block l1Block = L1Block(L1_BLOCK);
            queuedProofInfo[txHash] = QueuedProof({
                l2BlockNumber: block.number,
                l2BlockTimestamp: block.timestamp,
                l1BlockHash: l1Block.hash(),
                l1BlockNumber: l1Block.number()
            });
        }
    }

    /// @notice Flush all queued proofs
    /// @dev Only callable by the L1Block contract at the start of each new block
    function flushAllProofs() external {
        if (msg.sender != L1_BLOCK) revert OnlyL1Block();

        uint256 count = queuedEthscriptions.length();

        // Process and remove each ethscription from the set
        // We iterate backwards to avoid index shifting during removal
        for (uint256 i = count; i > 0; i--) {
            bytes32 txHash = queuedEthscriptions.at(i - 1);

            // Create and send proof for current state with stored block info
            _createAndSendProof(txHash, queuedProofInfo[txHash]);

            // Clean up: remove from set and delete the proof info
            queuedEthscriptions.remove(txHash);
            delete queuedProofInfo[txHash];
        }
    }

    // =============================================================
    //                    INTERNAL FUNCTIONS
    // =============================================================

    /// @notice Internal function to create and send proof for an ethscription
    /// @param ethscriptionTxHash The transaction hash of the ethscription
    /// @param proofInfo The queued proof info containing block data
    function _createAndSendProof(bytes32 ethscriptionTxHash, QueuedProof memory proofInfo) internal {
        // Get ethscription data including previous owner
        Ethscriptions.Ethscription memory etsc = ethscriptions.getEthscription(ethscriptionTxHash);
        address currentOwner = ethscriptions.ownerOf(ethscriptionTxHash);

        // Create proof struct with all ethscription data
        EthscriptionDataProof memory proof = EthscriptionDataProof({
            ethscriptionTxHash: ethscriptionTxHash,
            contentSha: etsc.content.contentSha,
            contentUriHash: etsc.content.contentUriHash,
            creator: etsc.creator,
            currentOwner: currentOwner,
            previousOwner: etsc.previousOwner,
            ethscriptionNumber: etsc.ethscriptionNumber,
            esip6: etsc.content.esip6,
            l1BlockHash: proofInfo.l1BlockHash,
            l1BlockNumber: proofInfo.l1BlockNumber,
            l2BlockNumber: proofInfo.l2BlockNumber,
            l2Timestamp: proofInfo.l2BlockTimestamp
        });

        // Encode and send to L1 with zero address and gas (only for state recording)
        bytes memory proofData = abi.encode(proof);
        L2_TO_L1_MESSAGE_PASSER.initiateWithdrawal(address(0), 0, proofData);

        emit EthscriptionDataProofSent(ethscriptionTxHash, proofInfo.l2BlockNumber, proofInfo.l2BlockTimestamp);
    }
}
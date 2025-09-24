// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./Ethscriptions.sol";
import "./TokenManager.sol";
import "./EthscriptionsERC20.sol";
import "./L2/L2ToL1MessagePasser.sol";
import "./libraries/Predeploys.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title EthscriptionsProver
/// @notice Proves Ethscription ownership and token balances to L1 via OP Stack
/// @dev Uses L2ToL1MessagePasser to send provable messages to L1
contract EthscriptionsProver {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /// @notice Info stored when an ethscription is queued for proving
    struct QueuedProof {
        uint256 blockNumber;
        uint256 blockTimestamp;
    }

    /// @notice Set of all ethscription transaction hashes queued for proving
    EnumerableSet.Bytes32Set private queuedEthscriptions;

    /// @notice Mapping from ethscription tx hash to its queued proof info
    mapping(bytes32 => QueuedProof) private queuedProofInfo;

    /// @notice L1Block contract address for access control
    address public constant L1_BLOCK = Predeploys.L1_BLOCK_ATTRIBUTES;
    /// @notice L2ToL1MessagePasser predeploy address on OP Stack
    L2ToL1MessagePasser constant L2_TO_L1_MESSAGE_PASSER = 
        L2ToL1MessagePasser(Predeploys.L2_TO_L1_MESSAGE_PASSER);
    
    /// @notice The Ethscriptions contract (pre-deployed at known address)
    Ethscriptions public constant ethscriptions = Ethscriptions(Predeploys.ETHSCRIPTIONS);
    
    /// @notice The TokenManager contract (pre-deployed at known address)
    TokenManager public constant tokenManager = TokenManager(Predeploys.TOKEN_MANAGER);
    
    /// @notice Struct for token balance proof data
    struct TokenBalanceProof {
        address holder;
        string protocol;
        string tick;
        uint256 balance;
        uint256 l2BlockNumber;
        uint256 l2Timestamp;
        // TODO: Add l1BlockNumber once we have L2->L1 block mapping
    }
    
    /// @notice Struct for ethscription data proof
    struct EthscriptionDataProof {
        bytes32 ethscriptionTxHash;
        bytes32 contentSha;
        address creator;
        address currentOwner;
        address previousOwner;
        uint256 ethscriptionNumber;
        bool isToken;
        uint256 tokenAmount;
        uint256 l2BlockNumber;
        uint256 l2Timestamp;
        // TODO: Add l1BlockNumber once we have L2->L1 block mapping
    }
    
    /// @notice Events for tracking proofs
    event TokenBalanceProofSent(
        address indexed holder,
        string tick,
        uint256 indexed l2BlockNumber,
        uint256 l2Timestamp
    );
    
    event EthscriptionDataProofSent(
        bytes32 indexed ethscriptionTxHash,
        uint256 indexed l2BlockNumber,
        uint256 l2Timestamp
    );

    /// @notice Emitted when a batch of proofs is flushed
    event ProofBatchFlushed(uint256 count, uint256 blockNumber);
    
    /// @notice Prove token balance for an address
    /// @param holder The address to prove balance for
    /// @param deployTxHash The deploy transaction hash (identifies the token type)
    function proveTokenBalance(
        address holder,
        bytes32 deployTxHash
    ) external {
        // Get token info from TokenManager
        TokenManager.TokenInfo memory tokenInfo = tokenManager.getTokenInfo(deployTxHash);
        
        // Get balance
        EthscriptionsERC20 token = EthscriptionsERC20(tokenInfo.tokenContract);
        uint256 balance = token.balanceOf(holder);
        
        // Create proof struct
        TokenBalanceProof memory proof = TokenBalanceProof({
            holder: holder,
            protocol: tokenInfo.protocol,
            tick: tokenInfo.tick,
            balance: balance,
            l2BlockNumber: block.number,
            l2Timestamp: block.timestamp
        });
        
        // Encode and send to L1 with zero address and gas (only for state recording)
        bytes memory proofData = abi.encode(proof);
        L2_TO_L1_MESSAGE_PASSER.initiateWithdrawal(address(0), 0, proofData);
        
        emit TokenBalanceProofSent(holder, tokenInfo.tick, block.number, block.timestamp);
    }
    
    /// @notice Queue an ethscription for proving
    /// @dev Only callable by the Ethscriptions contract
    /// @param txHash The transaction hash of the ethscription
    function queueEthscription(bytes32 txHash) external virtual {
        require(msg.sender == address(ethscriptions), "Only Ethscriptions contract can queue");

        // Add to the set (deduplicates automatically)
        if (queuedEthscriptions.add(txHash)) {
            // Only store info if this is the first time we're queueing this txHash
            queuedProofInfo[txHash] = QueuedProof({
                blockNumber: block.number,
                blockTimestamp: block.timestamp
            });
        }
    }

    /// @notice Flush all queued proofs
    /// @dev Only callable by the L1Block contract at the start of each new block
    function flushAllProofs() external {
        require(msg.sender == L1_BLOCK, "Only L1Block can flush");

        uint256 count = queuedEthscriptions.length();

        // Process and remove each ethscription from the set
        // We iterate backwards to avoid index shifting during removal
        for (uint256 i = count; i > 0; i--) {
            bytes32 txHash = queuedEthscriptions.at(i - 1);

            // Get the stored proof info to know which block this was from
            QueuedProof memory proofInfo = queuedProofInfo[txHash];

            // Create and send proof for current state with stored block info
            _createAndSendProof(txHash, proofInfo.blockNumber, proofInfo.blockTimestamp);

            // Clean up: remove from set and delete the proof info
            queuedEthscriptions.remove(txHash);
            delete queuedProofInfo[txHash];
        }

        emit ProofBatchFlushed(count, block.number - 1);
    }

    /// @notice Internal function to create and send proof for an ethscription
    /// @param ethscriptionTxHash The transaction hash of the ethscription
    /// @param blockNumber The L2 block number being proved
    /// @param blockTimestamp The timestamp of the L2 block being proved
    function _createAndSendProof(bytes32 ethscriptionTxHash, uint256 blockNumber, uint256 blockTimestamp) internal {
        // Get ethscription data including previous owner
        Ethscriptions.Ethscription memory etsc = ethscriptions.getEthscription(ethscriptionTxHash);
        address currentOwner = ethscriptions.currentOwner(ethscriptionTxHash);

        // Check if it's a token item
        bool isToken = tokenManager.isTokenItem(ethscriptionTxHash);
        uint256 tokenAmount = 0;
        if (isToken) {
            tokenAmount = tokenManager.getTokenAmount(ethscriptionTxHash);
        }

        // Create proof struct with previous owner
        EthscriptionDataProof memory proof = EthscriptionDataProof({
            ethscriptionTxHash: ethscriptionTxHash,
            contentSha: etsc.content.contentSha,
            creator: etsc.creator,
            currentOwner: currentOwner,
            previousOwner: etsc.previousOwner,
            ethscriptionNumber: etsc.ethscriptionNumber,
            isToken: isToken,
            tokenAmount: tokenAmount,
            l2BlockNumber: blockNumber,
            l2Timestamp: blockTimestamp
        });

        // Encode and send to L1 with zero address and gas (only for state recording)
        bytes memory proofData = abi.encode(proof);
        L2_TO_L1_MESSAGE_PASSER.initiateWithdrawal(address(0), 0, proofData);

        emit EthscriptionDataProofSent(ethscriptionTxHash, blockNumber, blockTimestamp);
    }

}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title SystemAddresses
/// @notice Defines the pre-deployed addresses for all system contracts
library SystemAddresses {
    /// @notice L2ToL1MessagePasser predeploy (standard OP Stack address)
    address constant L2_TO_L1_MESSAGE_PASSER = 0x4200000000000000000000000000000000000016;
    
    /// @notice Ethscriptions contract pre-deploy
    address constant ETHSCRIPTIONS = 0xe000000000000000000000000000000000000001;
    
    /// @notice TokenManager contract pre-deploy
    address constant TOKEN_MANAGER = 0xe000000000000000000000000000000000000002;
    
    /// @notice EthscriptionsProver contract pre-deploy
    address constant PROVER = 0xE000000000000000000000000000000000000003;
    
    /// @notice EthscriptionsERC20 template contract pre-deploy
    address constant ERC20_TEMPLATE = 0xe000000000000000000000000000000000000004;
}

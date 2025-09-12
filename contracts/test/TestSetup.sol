// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Ethscriptions.sol";
import "../src/TokenManager.sol";
import "../src/EthscriptionsProver.sol";
import "../src/EthscriptionsERC20.sol";
import "../src/L2/L2ToL1MessagePasser.sol";
import "../src/libraries/Predeploys.sol";

/// @title TestSetup
/// @notice Base test contract that pre-deploys all system contracts at their known addresses
abstract contract TestSetup is Test {
    Ethscriptions public ethscriptions;
    TokenManager public tokenManager;
    EthscriptionsProver public prover;
    
    function setUp() public virtual {
        // Deploy all system contracts to temporary addresses first
        Ethscriptions tempEthscriptions = new Ethscriptions();
        TokenManager tempTokenManager = new TokenManager();
        EthscriptionsProver tempProver = new EthscriptionsProver();
        EthscriptionsERC20 tempERC20Template = new EthscriptionsERC20();
        L2ToL1MessagePasser tempMessagePasser = new L2ToL1MessagePasser();
        
        // Etch them at their known addresses
        vm.etch(Predeploys.ETHSCRIPTIONS, address(tempEthscriptions).code);
        vm.etch(Predeploys.TOKEN_MANAGER, address(tempTokenManager).code);
        vm.etch(Predeploys.ETHSCRIPTIONS_PROVER, address(tempProver).code);
        vm.etch(Predeploys.ERC20_TEMPLATE, address(tempERC20Template).code);
        vm.etch(Predeploys.L2_TO_L1_MESSAGE_PASSER, address(tempMessagePasser).code);
        
        // Initialize name and symbol for Ethscriptions contract
        // This would normally be done in genesis state
        ethscriptions = Ethscriptions(Predeploys.ETHSCRIPTIONS);
        
        // Store contract references for tests
        tokenManager = TokenManager(Predeploys.TOKEN_MANAGER);
        prover = EthscriptionsProver(Predeploys.ETHSCRIPTIONS_PROVER);
        
        // ERC20 template doesn't need initialization - it's just a template for cloning
    }
}
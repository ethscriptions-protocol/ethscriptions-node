// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title Predeploys
/// @notice Defines all predeploy addresses for the L2 chain
library Predeploys {
    // ============ OP Stack Predeploys ============

    /// @notice L1Block predeploy (stores L1 block information)
    address constant L1_BLOCK_ATTRIBUTES = 0x4200000000000000000000000000000000000015;

    /// @notice Depositor Account (system address that can make deposits)
    address constant DEPOSITOR_ACCOUNT = 0xDeaDDEaDDeAdDeAdDEAdDEaddeAddEAdDEAd0001;
    
    /// @notice L2ToL1MessagePasser predeploy (for L2->L1 messages)
    address constant L2_TO_L1_MESSAGE_PASSER = 0x4200000000000000000000000000000000000016;
    
    /// @notice ProxyAdmin predeploy (manages all proxy upgrades)
    address constant PROXY_ADMIN = 0x4200000000000000000000000000000000000018;
    
    // ============ Ethscriptions System Predeploys ============
    // Using 0x3300… namespace for Ethscriptions contracts
    
    /// @notice Ethscriptions NFT contract
    /// @dev Moved to the 0x3300… namespace to align with other Ethscriptions predeploys
    address constant ETHSCRIPTIONS = 0x3300000000000000000000000000000000000001;
    
    /// @notice TokenManager for ERC20 token creation
    address constant TOKEN_MANAGER = 0x3300000000000000000000000000000000000002;
    
    /// @notice EthscriptionsProver for L1 provability
    address constant ETHSCRIPTIONS_PROVER = 0x3300000000000000000000000000000000000003;

    /// @notice Proxy address reserved for the ERC20 template (blank proxy)
    address constant ERC20_TEMPLATE_PROXY = 0x3300000000000000000000000000000000000004;

    /// @notice Implementation address for the ERC20 template (actual logic contract)
    address constant ERC20_TEMPLATE_IMPLEMENTATION = 0xc0D3c0D3c0D3c0d3c0d3C0d3C0d3c0D3C0D30004;

    /// @notice Proxy address reserved for the ERC721 template (blank proxy)
    address constant ERC721_TEMPLATE_PROXY = 0x3300000000000000000000000000000000000005;

    /// @notice Implementation address for the ERC721 template (actual logic contract)
    address constant ERC721_TEMPLATE_IMPLEMENTATION = 0xc0d3C0d3c0D3c0d3C0D3C0D3c0D3C0D3c0d30005;

    /// @notice CollectionsManager for collections protocol
    address constant COLLECTIONS_MANAGER = 0x3300000000000000000000000000000000000006;
    
    // ============ Helper Functions ============
    
    /// @notice Returns true if the address is an OP Stack predeploy (0x4200… namespace)
    function isOPPredeployNamespace(address _addr) internal pure returns (bool) {
        return uint160(_addr) >> 11 == uint160(0x4200000000000000000000000000000000000000) >> 11;
    }

    /// @notice Returns true if the address is an Ethscriptions predeploy (0x3300… namespace)
    function isEthscriptionsPredeployNamespace(address _addr) internal pure returns (bool) {
        return uint160(_addr) >> 11 == uint160(0x3300000000000000000000000000000000000000) >> 11;
    }

    /// @notice Returns true if the address is a recognized predeploy (OP or Ethscriptions)
    function isPredeployNamespace(address _addr) internal pure returns (bool) {
        return isOPPredeployNamespace(_addr) || isEthscriptionsPredeployNamespace(_addr);
    }
    
    /// @notice Converts a predeploy address to its code namespace equivalent
    function predeployToCodeNamespace(address _addr) internal pure returns (address) {
        require(
            isPredeployNamespace(_addr), 
            "Predeploys: can only derive code-namespace address for predeploy addresses"
        );
        return address(
            uint160(uint256(uint160(_addr)) & 0xffff | uint256(uint160(0xc0D3C0d3C0d3C0D3c0d3C0d3c0D3C0d3c0d30000)))
        );
    }
}

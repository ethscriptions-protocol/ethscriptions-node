// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {L2GenesisConfig} from "./L2GenesisConfig.sol";
import {Predeploys} from "../src/libraries/Predeploys.sol";
import {Constants} from "../src/libraries/Constants.sol";

/// @title L2Genesis
/// @notice Generates the minimal genesis state for the L2 network.
///         Sets up L1Block contract, L2ToL1MessagePasser, ProxyAdmin, and proxy infrastructure.
contract L2Genesis is Script {
    uint256 constant PRECOMPILE_COUNT = 256;
    uint256 internal constant PREDEPLOY_COUNT = 2048;
    
    string constant GENESIS_JSON_FILE = "genesis-allocs.json";

    L2GenesisConfig.Config config;

    /// @notice Main entry point for genesis generation
    function run() public {
        // Load configuration
        config = L2GenesisConfig.getConfig();

        // Use a deployer account for genesis setup
        address deployer = makeAddr("deployer");
        vm.startPrank(deployer);
        vm.chainId(config.l2ChainID);

        // Set up genesis state
        dealEthToPrecompiles();
        setOPStackPredeploys();
        setEthscriptionsPredeploys();
        
        // Fund dev accounts if enabled
        if (config.fundDevAccounts) {
            fundDevAccounts();
        }

        // Clean up deployer
        vm.stopPrank();
        vm.deal(deployer, 0);
        vm.resetNonce(deployer);
        
        // Dump state and prettify with jq
        vm.dumpState(GENESIS_JSON_FILE);
        
        // Use FFI to prettify and sort the JSON keys
        string[] memory inputs = new string[](3);
        inputs[0] = "sh";
        inputs[1] = "-c";
        // Use block timestamp for unique temp file
        string memory tempFile = string.concat("/tmp/genesis-", vm.toString(block.timestamp), ".json");
        inputs[2] = string.concat("jq --sort-keys . ", GENESIS_JSON_FILE, " > ", tempFile, " && mv ", tempFile, " ", GENESIS_JSON_FILE);
        vm.ffi(inputs);
    }

    /// @notice Give all precompiles 1 wei (required for EVM compatibility)
    function dealEthToPrecompiles() internal {
        for (uint256 i; i < PRECOMPILE_COUNT; i++) {
            vm.deal(address(uint160(i)), 1);
        }
    }

    /// @notice Set up OP Stack predeploys with proxies
    function setOPStackPredeploys() internal {
        bytes memory proxyCode = vm.getDeployedCode("Proxy.sol:Proxy");
        // Deploy proxies at sequential addresses starting from 0x42...00
        uint160 prefix = uint160(0x420) << 148;
        
        for (uint256 i = 0; i < PREDEPLOY_COUNT; i++) {
            address addr = address(prefix | uint160(i));
            
            // Deploy proxy
            vm.etch(addr, proxyCode);
            
            vm.setNonce(addr, 1);
            
            // Set admin to ProxyAdmin
            setProxyAdminSlot(addr, Predeploys.PROXY_ADMIN);
            
            bool isSupportedPredeploy = addr == Predeploys.L1_BLOCK_ATTRIBUTES ||
                addr == Predeploys.L2_TO_L1_MESSAGE_PASSER ||
                addr == Predeploys.PROXY_ADMIN;
            
            if (isSupportedPredeploy) {
                address implementation = Predeploys.predeployToCodeNamespace(addr);
                setImplementation(addr, implementation);
            }
        }
        
        // Now set implementations for OP Stack contracts
        setL1Block();
        setL2ToL1MessagePasser();
        setProxyAdmin();
    }
    
    /// @notice Set up Ethscriptions system contracts
    function setEthscriptionsPredeploys() internal {
        // Deploy Ethscriptions contracts directly (no proxies for now)
        _setEthscriptionsCode(Predeploys.ETHSCRIPTIONS, "Ethscriptions");
        _setEthscriptionsCode(Predeploys.TOKEN_MANAGER, "TokenManager");
        _setEthscriptionsCode(Predeploys.ETHSCRIPTIONS_PROVER, "EthscriptionsProver");
        _setEthscriptionsCode(Predeploys.ERC20_TEMPLATE, "EthscriptionsERC20");
        
        // Disable initializers on all Ethscriptions contracts
        _disableInitializers(Predeploys.ETHSCRIPTIONS);
        _disableInitializers(Predeploys.ERC20_TEMPLATE);
    }

    /// @notice Deploy L1Block contract (stores L1 block attributes)
    function setL1Block() internal {
        _setImplementationCode(Predeploys.L1_BLOCK_ATTRIBUTES);
    }

    /// @notice Deploy L2ToL1MessagePasser contract
    function setL2ToL1MessagePasser() internal {
        _setImplementationCode(Predeploys.L2_TO_L1_MESSAGE_PASSER);
    }

    /// @notice Deploy ProxyAdmin contract
    function setProxyAdmin() internal {
        address impl = _setImplementationCode(Predeploys.PROXY_ADMIN);

        // Set the owner
        bytes32 ownerSlot = bytes32(0); // Owner is typically stored at slot 0
        vm.store(Predeploys.PROXY_ADMIN, ownerSlot, bytes32(uint256(uint160(config.proxyAdminOwner))));
        vm.store(impl, ownerSlot, bytes32(uint256(uint160(config.proxyAdminOwner))));
    }

    /// @notice Fund development accounts with ETH
    function fundDevAccounts() internal {
        address[] memory accounts = L2GenesisConfig.getDevAccounts();
        uint256 amount = L2GenesisConfig.getDevAccountFundAmount();
        
        for (uint256 i = 0; i < accounts.length; i++) {
            vm.deal(accounts[i], amount);
        }
    }

    // ============ Helper Functions ============
    
    /// @notice Disable initializers on a contract to prevent initialization
    function _disableInitializers(address _addr) internal {
        vm.store(_addr, Constants.INITIALIZABLE_STORAGE, bytes32(uint256(0x000000000000000000000000000000000000000000000000ffffffffffffffff)));
    }
    
    /// @notice Set bytecode for Ethscriptions contracts
    function _setEthscriptionsCode(address _addr, string memory _name) internal {
        bytes memory code = vm.getDeployedCode(string.concat(_name, ".sol:", _name));
        vm.etch(_addr, code);
        vm.setNonce(_addr, 1);
    }

    /// @notice Set the admin of a proxy contract
    function setProxyAdminSlot(address proxy, address admin) internal {
        // EIP-1967 admin slot
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        vm.store(proxy, adminSlot, bytes32(uint256(uint160(admin))));
    }

    /// @notice Set the implementation of a proxy contract
    function setImplementation(address proxy, address implementation) internal {
        // EIP-1967 implementation slot
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        vm.store(proxy, implSlot, bytes32(uint256(uint160(implementation))));
    }
    
    /// @notice Sets the bytecode in state
    function _setImplementationCode(address _addr) internal returns (address) {
        string memory cname = getName(_addr);
        address impl = Predeploys.predeployToCodeNamespace(_addr);
        vm.etch(impl, vm.getDeployedCode(string.concat(cname, ".sol:", cname)));
        return impl;
    }
    
    function getName(address _addr) internal pure returns (string memory) {
        // OP Stack predeploys
        if (_addr == Predeploys.L1_BLOCK_ATTRIBUTES) {
            return "L1Block";
        } else if (_addr == Predeploys.L2_TO_L1_MESSAGE_PASSER) {
            return "L2ToL1MessagePasser";
        } else if (_addr == Predeploys.PROXY_ADMIN) {
            return "ProxyAdmin";
        }
        
        revert("Invalid predeploy address");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ERC20NullOwnerCappedUpgradeable.sol";
import "./libraries/Predeploys.sol";

/// @title EthscriptionsERC20
/// @notice ERC20 with cap that supports null address ownership
/// @dev Only TokenManager can mint/transfer. User-initiated transfers are disabled.
contract EthscriptionsERC20 is ERC20NullOwnerCappedUpgradeable {

    // =============================================================
    //                         CONSTANTS
    // =============================================================

    /// @notice The TokenManager contract that controls this token
    address public constant tokenManager = Predeploys.TOKEN_MANAGER;

    // =============================================================
    //                      STATE VARIABLES
    // =============================================================

    /// @notice The ethscription hash that deployed this token
    bytes32 public deployTxHash;

    // =============================================================
    //                      CUSTOM ERRORS
    // =============================================================

    error OnlyTokenManager();
    error TransfersOnlyViaEthscriptions();
    error ApprovalsNotAllowed();

    // =============================================================
    //                         MODIFIERS
    // =============================================================

    modifier onlyTokenManager() {
        if (msg.sender != tokenManager) revert OnlyTokenManager();
        _;
    }

    // =============================================================
    //                    EXTERNAL FUNCTIONS
    // =============================================================

    /// @notice Initialize the ERC20 token
    /// @param name_ The token name
    /// @param symbol_ The token symbol
    /// @param cap_ The maximum supply cap (in 18 decimals)
    /// @param deployTxHash_ The ethscription hash that deployed this token
    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 cap_,
        bytes32 deployTxHash_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __ERC20Capped_init(cap_);
        deployTxHash = deployTxHash_;
    }

    /// @notice Mint tokens (TokenManager only)
    /// @dev Allows minting to address(0) for null ownership
    /// @param to The recipient address (can be address(0))
    /// @param amount The amount to mint (in 18 decimals)
    function mint(address to, uint256 amount) external onlyTokenManager {
        _mint(to, amount);
    }

    /// @notice Force transfer tokens (TokenManager only)
    /// @dev Allows transfers to/from address(0) for null ownership
    /// @param from The sender address (can be address(0))
    /// @param to The recipient address (can be address(0))
    /// @param amount The amount to transfer (in 18 decimals)
    function forceTransfer(address from, address to, uint256 amount) external onlyTokenManager {
        _update(from, to, amount);
    }

    // =============================================================
    //                DISABLED ERC20 FUNCTIONS
    // =============================================================

    /// @notice User-initiated transfers are disabled
    /// @dev All transfers must go through the Ethscriptions NFT
    function transfer(address, uint256) public pure override returns (bool) {
        revert TransfersOnlyViaEthscriptions();
    }

    /// @notice User-initiated transfers are disabled
    /// @dev All transfers must go through the Ethscriptions NFT
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert TransfersOnlyViaEthscriptions();
    }

    /// @notice Approvals are disabled
    /// @dev All transfers are controlled by the TokenManager
    function approve(address, uint256) public pure override returns (bool) {
        revert ApprovalsNotAllowed();
    }
}
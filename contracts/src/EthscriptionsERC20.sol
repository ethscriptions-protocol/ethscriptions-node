// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./ERC20NullOwnerCappedUpgradeable.sol";
import "./libraries/Predeploys.sol";

/// @title EthscriptionsERC20
/// @notice ERC20 with cap that supports null address ownership; only TokenManager can mint/transfer
contract EthscriptionsERC20 is ERC20NullOwnerCappedUpgradeable {
    address public constant tokenManager = Predeploys.TOKEN_MANAGER;
    bytes32 public deployTxHash; // The ethscription hash that deployed this token

    function initialize(
        string memory name_,
        string memory symbol_,
        uint256 cap_,
        bytes32 deployTxHash_
    ) public initializer {
        __ERC20_init(name_, symbol_);
        __ERC20Capped_init(cap_);
        deployTxHash = deployTxHash_;
    }

    modifier onlyTokenManager() {
        require(msg.sender == tokenManager, "Only TokenManager");
        _;
    }

    // TokenManager-only mint that allows to == address(0)
    function mint(address to, uint256 amount) external onlyTokenManager {
        _mint(to, amount);
    }

    // TokenManager-only transfer that allows to/from == address(0)
    function forceTransfer(address from, address to, uint256 amount) external onlyTokenManager {
        _update(from, to, amount);
    }

    // Disable user-initiated ERC20 flows
    function transfer(address, uint256) public pure override returns (bool) {
        revert("Transfers only allowed via Ethscriptions NFT");
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("Transfers only allowed via Ethscriptions NFT");
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert("Approvals not allowed");
    }
}

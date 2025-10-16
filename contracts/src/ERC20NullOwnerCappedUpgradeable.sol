// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title ERC20NullOwnerCappedUpgradeable
/// @notice ERC20 (Upgradeable) + Cap adapted to treat address(0) as a valid holder; single storage struct
abstract contract ERC20NullOwnerCappedUpgradeable is Initializable, ContextUpgradeable, IERC20, IERC20Metadata, IERC20Errors {
    /// @custom:storage-location erc7201:ethscriptions.storage.ERC20NullOwnerCapped
    struct TokenStorage {
        mapping(address account => uint256) balances;
        mapping(address account => mapping(address spender => uint256)) allowances;
        uint256 totalSupply;
        string name;
        string symbol;
        uint256 cap;
    }

    // Unique storage slot for this combined ERC20 + Cap storage
    // keccak256(abi.encode(uint256(keccak256("ethscriptions.storage.ERC20NullOwnerCapped")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_LOCATION = 0x8f4f7bb0f9a741a04db8c5a3930ef1872dc1b0c6f996f78adc3f57e5f8b78400;

    function _getS() private pure returns (TokenStorage storage $) {
        assembly {
            $.slot := STORAGE_LOCATION
        }
    }

    // Errors copied from OZ
    error ERC20ExceededCap(uint256 increasedSupply, uint256 cap);
    error ERC20InvalidCap(uint256 cap);

    // Initializers
    function __ERC20_init(string memory name_, string memory symbol_) internal onlyInitializing {
        __ERC20_init_unchained(name_, symbol_);
    }

    function __ERC20_init_unchained(string memory name_, string memory symbol_) internal onlyInitializing {
        TokenStorage storage $ = _getS();
        $.name = name_;
        $.symbol = symbol_;
    }

    function __ERC20Capped_init(uint256 cap_) internal onlyInitializing {
        __ERC20Capped_init_unchained(cap_);
    }

    function __ERC20Capped_init_unchained(uint256 cap_) internal onlyInitializing {
        TokenStorage storage $ = _getS();
        if (cap_ == 0) {
            revert ERC20InvalidCap(0);
        }
        $.cap = cap_;
    }

    // Views
    function name() public view virtual returns (string memory) {
        TokenStorage storage $ = _getS();
        return $.name;
    }

    function symbol() public view virtual returns (string memory) {
        TokenStorage storage $ = _getS();
        return $.symbol;
    }

    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    function totalSupply() public view virtual returns (uint256) {
        TokenStorage storage $ = _getS();
        return $.totalSupply;
    }

    function balanceOf(address account) public view virtual returns (uint256) {
        TokenStorage storage $ = _getS();
        return $.balances[account];
    }

    function allowance(address owner, address spender) public view virtual returns (uint256) {
        TokenStorage storage $ = _getS();
        return $.allowances[owner][spender];
    }

    // External ERC-20 (can be overridden to restrict usage in child)
    function transfer(address to, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    // Internal core
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        // Allow `to == address(0)` to support null-owner semantics
        _update(from, to, value);
    }

    // Modified from OZ: do NOT burn on to == address(0); always credit recipient (including zero address).
    function _update(address from, address to, uint256 value) internal virtual {
        TokenStorage storage $ = _getS();
        if (from == address(0)) {
            // Mint path
            $.totalSupply += value;
        } else {
            uint256 fromBalance = $.balances[from];
            if (fromBalance < value) {
                revert ERC20InsufficientBalance(from, fromBalance, value);
            }
            unchecked {
                $.balances[from] = fromBalance - value;
            }
        }

        // No burning: credit even address(0)
        unchecked {
            $.balances[to] += value;
        }

        emit Transfer(from, to, value);

        // Cap enforcement when minting
        if (from == address(0)) {
            uint256 maxSupply = $.cap;
            uint256 supply = $.totalSupply;
            if (supply > maxSupply) {
                revert ERC20ExceededCap(supply, maxSupply);
            }
        }
    }

    // Mint (null-owner aware)
    function _mint(address account, uint256 value) internal {
        _update(address(0), account, value);
    }

    // Approvals
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal virtual {
        TokenStorage storage $ = _getS();
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        $.allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance < type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }

    // Cap view
    function maxSupply() public view virtual returns (uint256) {
        TokenStorage storage $ = _getS();
        return $.cap;
    }
}

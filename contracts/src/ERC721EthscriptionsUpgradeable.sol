// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @dev Minimal ERC-721 implementation that supports null address ownership.
 * Unlike standard ERC-721, tokens can be owned by address(0) and still exist.
 * This is required for Ethscriptions protocol compatibility.
 *
 * Simplifications from standard ERC-721:
 * - No safe transfer functionality (no onERC721Received checks)
 * - No approval functionality (approve, getApproved, setApprovalForAll removed)
 * - No tokenURI implementation (must be overridden by child)
 * - No burn function (transfer to address(0) instead)
 * - Keeps only core transfer and ownership logic
 */
abstract contract ERC721EthscriptionsUpgradeable is Initializable, ContextUpgradeable, ERC165Upgradeable, IERC721, IERC721Metadata, IERC721Enumerable, IERC721Errors {
    // Errors for enumerable functionality
    error ERC721OutOfBoundsIndex(address owner, uint256 index);
    error ERC721EnumerableForbiddenBatchMint();

    /// @custom:storage-location erc7201:ethscriptions.storage.ERC721
    struct ERC721Storage {
        string _name;
        string _symbol;
        
        // Token owners (can be address(0) for null-owned tokens)
        mapping(uint256 tokenId => address) _owners;
        // Balance per address (including null address)
        mapping(address owner => uint256) _balances;

        // === Ethscriptions-specific storage ===
        // Explicit existence tracking (true = token exists)
        mapping(uint256 tokenId => bool) _existsFlag;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC721.ethscriptions")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC721StorageLocation = 0x03f081da1bf59345b57bd2323b19ea3e2315141ee27bd283a32089733412b400;

    function _getERC721Storage() private pure returns (ERC721Storage storage $) {
        assembly {
            $.slot := ERC721StorageLocation
        }
    }

    /// @custom:storage-location erc7201:openzeppelin.storage.ERC721Enumerable
    struct ERC721EnumerableStorage {
        mapping(address owner => mapping(uint256 index => uint256)) _ownedTokens;
        mapping(uint256 tokenId => uint256) _ownedTokensIndex;
        uint256[] _allTokens;
        mapping(uint256 tokenId => uint256) _allTokensIndex;
    }

    // keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC721Enumerable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC721EnumerableStorageLocation = 0x645e039705490088daad89bae25049a34f4a9072d398537b1ab2425f24cbed00;

    function _getERC721EnumerableStorage() private pure returns (ERC721EnumerableStorage storage $) {
        assembly {
            $.slot := ERC721EnumerableStorageLocation
        }
    }

    /**
     * @dev Initializes the contract.
     */
    function __ERC721_init(string memory name_, string memory symbol_) internal onlyInitializing {
        __ERC721_init_unchained(name_, symbol_);
    }

    function __ERC721_init_unchained(string memory name_, string memory symbol_) internal onlyInitializing {
        ERC721Storage storage $ = _getERC721Storage();
        $._name = name_;
        $._symbol = symbol_;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165Upgradeable, IERC165) returns (bool) {
        return
            interfaceId == type(IERC721).interfaceId ||
            interfaceId == type(IERC721Metadata).interfaceId ||
            interfaceId == type(IERC721Enumerable).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /**
     * @dev See {IERC721-balanceOf}.
     * Modified to support null address balance queries.
     */
    function balanceOf(address owner) public view virtual returns (uint256) {
        ERC721Storage storage $ = _getERC721Storage();
        return $._balances[owner];
    }

    /**
     * @dev See {IERC721-ownerOf}.
     */
    function ownerOf(uint256 tokenId) public view virtual returns (address) {
        return _requireOwned(tokenId);
    }

    /**
     * @dev See {IERC721Metadata-name}.
     * Must be overridden by child contract.
     */
    function name() public view virtual returns (string memory) {
        ERC721Storage storage $ = _getERC721Storage();
        return $._name;
    }

    /**
     * @dev See {IERC721Metadata-symbol}.
     * Must be overridden by child contract.
     */
    function symbol() public view virtual returns (string memory) {
        ERC721Storage storage $ = _getERC721Storage();
        return $._symbol;
    }

    /**
     * @dev See {IERC721Metadata-tokenURI}.
     * Must be overridden by child contract.
     */
    function tokenURI(uint256 tokenId) public view virtual returns (string memory);

    /// @inheritdoc IERC721Enumerable
    function totalSupply() public view virtual returns (uint256) {
        ERC721EnumerableStorage storage $ = _getERC721EnumerableStorage();
        return $._allTokens.length;
    }

    /// @inheritdoc IERC721Enumerable
    function tokenOfOwnerByIndex(address owner, uint256 index) public view virtual returns (uint256) {
        ERC721EnumerableStorage storage $ = _getERC721EnumerableStorage();
        if (index >= balanceOf(owner)) {
            revert ERC721OutOfBoundsIndex(owner, index);
        }
        return $._ownedTokens[owner][index];
    }

    /// @inheritdoc IERC721Enumerable
    function tokenByIndex(uint256 index) public view virtual returns (uint256) {
        ERC721EnumerableStorage storage $ = _getERC721EnumerableStorage();
        if (index >= totalSupply()) {
            revert ERC721OutOfBoundsIndex(address(0), index);
        }
        return $._allTokens[index];
    }

    /**
     * @dev Approval functions removed - not needed for Ethscriptions.
     * These can be added back in child contracts if needed.
     */
    function approve(address, uint256) public virtual {
        revert("Approvals not supported");
    }

    function getApproved(uint256 tokenId) public view virtual returns (address) {
        if (!_tokenExists(tokenId)) {
            revert ERC721NonexistentToken(tokenId);
        }
        return address(0);
    }

    function setApprovalForAll(address, bool) public virtual {
        revert("Approvals not supported");
    }

    function isApprovedForAll(address, address) public view virtual returns (bool) {
        return false;
    }

    /**
     * @dev See {IERC721-transferFrom}.
     * Modified to allow transfers to address(0) (not burns, just transfers).
     */
    function transferFrom(address from, address to, uint256 tokenId) public virtual {
        // Removed check for to == address(0) to allow null transfers
        address previousOwner = _update(to, tokenId, _msgSender());
        if (previousOwner != from) {
            revert ERC721IncorrectOwner(from, tokenId, previousOwner);
        }
    }

    /**
     * @dev Safe transfer functions removed - not needed for Ethscriptions.
     */
    function safeTransferFrom(address, address, uint256) public virtual {
        revert("Safe transfers not supported");
    }

    function safeTransferFrom(address, address, uint256, bytes memory) public virtual {
        revert("Safe transfers not supported");
    }

    /**
     * @dev Returns the owner of the `tokenId`. Does NOT revert if token doesn't exist.
     * Modified to check existence flag instead of owner == address(0).
     */
    function _ownerOf(uint256 tokenId) internal view virtual returns (address) {
        ERC721Storage storage $ = _getERC721Storage();
        return $._owners[tokenId]; // May be address(0) for null-owned
    }

    /**
     * @dev Simplified authorization - only owner can transfer.
     */
    function _checkAuthorized(address owner, address spender, uint256 tokenId) internal view virtual {
        ERC721Storage storage $ = _getERC721Storage();

        if (!$._existsFlag[tokenId]) {
            revert ERC721NonexistentToken(tokenId);
        }

        // Only the owner can transfer (no approvals)
        // Since spender (msg.sender) can never be address(0), null-owned tokens are automatically protected
        if (owner != spender) {
            revert ERC721InsufficientApproval(spender, tokenId);
        }
    }

    /**
     * @dev Transfers `tokenId` from its current owner to `to`.
     * Modified to handle null address as a valid owner.
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual returns (address) {
        ERC721Storage storage $ = _getERC721Storage();

        bool existed = $._existsFlag[tokenId];
        address from = _ownerOf(tokenId);

        // Perform authorization check if needed
        if (auth != address(0)) {
            _checkAuthorized(from, auth, tokenId);
        }

        // Handle transfer/mint - enumeration helpers handle balance updates
        if (existed) {
            // This is a transfer
            if (from != to) {
                // Remove from old owner (also decrements from's balance)
                _removeTokenFromOwnerEnumeration(from, tokenId);
                // Add to new owner (also increments to's balance)
                _addTokenToOwnerEnumeration(to, tokenId);
            }
        } else {
            // This is a mint
            $._existsFlag[tokenId] = true;

            // Add to all tokens enumeration
            _addTokenToAllTokensEnumeration(tokenId);

            // Add to owner enumeration (also increments balance)
            _addTokenToOwnerEnumeration(to, tokenId);
        }

        // Update owner and emit
        $._owners[tokenId] = to;
        emit Transfer(from, to, tokenId);

        return from;
    }

    /**
     * @dev Mints `tokenId` and transfers it to `to`.
     * Routes through _update to ensure consistent behavior.
     * Does not allow minting directly to address(0) - mint then transfer instead.
     */
    function _mint(address to, uint256 tokenId) internal {
        ERC721Storage storage $ = _getERC721Storage();

        // Check if token already exists
        if ($._existsFlag[tokenId]) {
            revert ERC721InvalidSender(address(0));
        }

        if (to == address(0)) {
            revert ERC721InvalidReceiver(address(0));
        }

        // Mint the token via _update
        _update(to, tokenId, address(0));
    }

    /**
     * @dev Transfers `tokenId` from `from` to `to`.
     * Modified to allow transfers to address(0) (not burns).
     */
    function _transfer(address from, address to, uint256 tokenId) internal {
        address previousOwner = _update(to, tokenId, address(0));
        if (!_tokenExists(tokenId)) {
            revert ERC721NonexistentToken(tokenId);
        } else if (previousOwner != from) {
            revert ERC721IncorrectOwner(from, tokenId, previousOwner);
        }
    }

    /**
     * @dev Reverts if the `tokenId` doesn't have a current owner (it hasn't been minted, or it has been burned).
     * Modified to use existence flag instead of owner == address(0).
     */
    function _requireOwned(uint256 tokenId) internal view returns (address) {
        ERC721Storage storage $ = _getERC721Storage();
        if (!$._existsFlag[tokenId]) {
            revert ERC721NonexistentToken(tokenId);
        }
        return $._owners[tokenId]; // May be address(0) for null-owned
    }

    /**
     * @dev Returns whether `tokenId` exists.
     * Tokens start existing when they are minted (`_mint`).
     */
    function _tokenExists(uint256 tokenId) internal view returns (bool) {
        ERC721Storage storage $ = _getERC721Storage();
        return $._existsFlag[tokenId];
    }

    /**
     * @dev Sets the existence flag for a token. Used by child contracts for removal.
     */
    function _setTokenExists(uint256 tokenId, bool exists) internal {
        ERC721Storage storage $ = _getERC721Storage();

        // If removing a token, also remove from enumeration and update balance
        if (!exists && $._existsFlag[tokenId]) {
            address owner = $._owners[tokenId];

            // Remove from enumerations (balance is decremented inside _removeTokenFromOwnerEnumeration)
            _removeTokenFromOwnerEnumeration(owner, tokenId);
            _removeTokenFromAllTokensEnumeration(tokenId);

            // Clear owner storage for cleanliness
            delete $._owners[tokenId];
        }

        $._existsFlag[tokenId] = exists;
    }

    /**
     * @dev Override to forbid batch minting which would break enumeration.
     */
    function _increaseBalance(address account, uint128 amount) internal virtual {
        if (amount > 0) {
            revert ERC721EnumerableForbiddenBatchMint();
        }
        // Note: We don't have a parent _increaseBalance to call since we're not inheriting from ERC721Upgradeable
        // This function exists just to prevent batch minting attempts
    }

    /**
     * @dev Private function to add a token to this extension's ownership-tracking data structures.
     * Also increments the owner's balance.
     * @param to address representing the new owner of the given token ID
     * @param tokenId uint256 ID of the token to be added to the tokens list of the given address
     */
    function _addTokenToOwnerEnumeration(address to, uint256 tokenId) private {
        ERC721Storage storage $ = _getERC721Storage();
        ERC721EnumerableStorage storage $enum = _getERC721EnumerableStorage();

        // Use current balance as the index for the new token
        uint256 length = $._balances[to];
        $enum._ownedTokens[to][length] = tokenId;
        $enum._ownedTokensIndex[tokenId] = length;

        // Now increment the balance
        unchecked {
            $._balances[to] += 1;
        }
    }

    /**
     * @dev Private function to add a token to this extension's token tracking data structures.
     * @param tokenId uint256 ID of the token to be added to the tokens list
     */
    function _addTokenToAllTokensEnumeration(uint256 tokenId) private {
        ERC721EnumerableStorage storage $ = _getERC721EnumerableStorage();
        $._allTokensIndex[tokenId] = $._allTokens.length;
        $._allTokens.push(tokenId);
    }

    /**
     * @dev Private function to remove a token from this extension's ownership-tracking data structures.
     * Also decrements the owner's balance.
     * Note that while the token is not assigned a new owner, the `_ownedTokensIndex` mapping is _not_ updated: this allows for
     * gas optimizations e.g. when performing a transfer operation (avoiding double writes).
     * This has O(1) time complexity, but alters the order of the _ownedTokens array.
     * @param from address representing the previous owner of the given token ID
     * @param tokenId uint256 ID of the token to be removed from the tokens list of the given address
     */
    function _removeTokenFromOwnerEnumeration(address from, uint256 tokenId) private {
        ERC721Storage storage $ = _getERC721Storage();
        ERC721EnumerableStorage storage $enum = _getERC721EnumerableStorage();

        // To prevent a gap in from's tokens array, we store the last token in the index of the token to delete, and
        // then delete the last slot (swap and pop).

        // First decrement the balance
        unchecked {
            $._balances[from] -= 1;
        }

        // Now use the updated balance as the last index
        uint256 lastTokenIndex = $._balances[from];
        uint256 tokenIndex = $enum._ownedTokensIndex[tokenId];

        mapping(uint256 index => uint256) storage _ownedTokensByOwner = $enum._ownedTokens[from];

        // When the token to delete is the last token, the swap operation is unnecessary
        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = _ownedTokensByOwner[lastTokenIndex];

            _ownedTokensByOwner[tokenIndex] = lastTokenId; // Move the last token to the slot of the to-delete token
            $enum._ownedTokensIndex[lastTokenId] = tokenIndex; // Update the moved token's index
        }

        // This also deletes the contents at the last position of the array
        delete $enum._ownedTokensIndex[tokenId];
        delete _ownedTokensByOwner[lastTokenIndex];
    }

    /**
     * @dev Private function to remove a token from this extension's token tracking data structures.
     * This has O(1) time complexity, but alters the order of the _allTokens array.
     * @param tokenId uint256 ID of the token to be removed from the tokens list
     */
    function _removeTokenFromAllTokensEnumeration(uint256 tokenId) private {
        ERC721EnumerableStorage storage $ = _getERC721EnumerableStorage();
        // To prevent a gap in the tokens array, we store the last token in the index of the token to delete, and
        // then delete the last slot (swap and pop).

        uint256 lastTokenIndex = $._allTokens.length - 1;
        uint256 tokenIndex = $._allTokensIndex[tokenId];

        // When the token to delete is the last token, the swap operation is unnecessary. However, since this occurs so
        // rarely (when the last minted token is burnt) that we still do the swap here to avoid the gas cost of adding
        // an 'if' statement (like in _removeTokenFromOwnerEnumeration)
        uint256 lastTokenId = $._allTokens[lastTokenIndex];

        $._allTokens[tokenIndex] = lastTokenId; // Move the last token to the slot of the to-delete token
        $._allTokensIndex[lastTokenId] = tokenIndex; // Update the moved token's index

        // This also deletes the contents at the last position of the array
        delete $._allTokensIndex[tokenId];
        $._allTokens.pop();
    }
}
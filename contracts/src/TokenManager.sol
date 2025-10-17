// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";
import {LibString} from "solady/utils/LibString.sol";
import "./EthscriptionsERC20.sol";
import "./Ethscriptions.sol";
import "./libraries/Predeploys.sol";
import "./interfaces/IProtocolHandler.sol";

/// @title Token Manager for Ethscriptions ERC-20 Protocol
/// @notice Manages ERC-20 token deployments and minting through the Ethscriptions protocol
/// @dev Implements IProtocolHandler for integration with Ethscriptions contract
contract TokenManager is IProtocolHandler {
    using Clones for address;
    using LibString for string;

    // =============================================================
    //                           STRUCTS
    // =============================================================

    struct TokenInfo {
        address tokenContract;
        bytes32 deployTxHash;
        string protocol;
        string tick;
        uint256 maxSupply;
        uint256 mintAmount;
        uint256 totalMinted;
    }

    struct TokenItem {
        bytes32 deployTxHash;  // Which token this ethscription belongs to
        uint256 amount;        // How many tokens this ethscription represents
    }

    // Protocol operation structs for cleaner decoding
    struct DeployOperation {
        string tick;
        uint256 maxSupply;
        uint256 mintAmount;
    }

    struct MintOperation {
        string tick;
        uint256 id;
        uint256 amount;
    }

    // =============================================================
    //                         CONSTANTS
    // =============================================================

    address public constant erc20Template = Predeploys.ERC20_TEMPLATE_IMPLEMENTATION;
    address public constant ethscriptions = Predeploys.ETHSCRIPTIONS;

    // =============================================================
    //                      STATE VARIABLES
    // =============================================================

    /// @dev Track deployed tokens by protocol+tick for find-or-create
    mapping(bytes32 => TokenInfo) internal tokensByTick;  // keccak256(abi.encode(protocol, tick)) => TokenInfo

    /// @dev Map deploy transaction hash to tick key for lookups
    mapping(bytes32 => bytes32) public deployToTick;    // deployTxHash => tickKey

    /// @dev Track which ethscription is a token item
    mapping(bytes32 => TokenItem) internal tokenItems;    // ethscription tx hash => TokenItem

    // =============================================================
    //                      CUSTOM ERRORS
    // =============================================================

    error OnlyEthscriptions();
    error TokenAlreadyDeployed();
    error TokenNotDeployed();
    error MintAmountMismatch();
    error InvalidMintId();
    error InvalidMaxSupply();
    error InvalidMintAmount();
    error MaxSupplyNotDivisibleByMintAmount();

    // =============================================================
    //                          EVENTS
    // =============================================================

    event TokenDeployed(
        bytes32 indexed deployTxHash,
        address indexed tokenAddress,
        string tick,
        uint256 maxSupply,
        uint256 mintAmount
    );

    event TokenMinted(
        bytes32 indexed deployTxHash,
        address indexed to,
        uint256 amount,
        bytes32 ethscriptionTxHash
    );

    event TokenTransferred(
        bytes32 indexed deployTxHash,
        address indexed from,
        address indexed to,
        uint256 amount,
        bytes32 ethscriptionTxHash
    );

    // =============================================================
    //                         MODIFIERS
    // =============================================================

    modifier onlyEthscriptions() {
        if (msg.sender != ethscriptions) revert OnlyEthscriptions();
        _;
    }

    // =============================================================
    //                    EXTERNAL FUNCTIONS
    // =============================================================

    /// @notice Handle deploy operation
    /// @param txHash The ethscription transaction hash
    /// @param data The encoded DeployOperation data
    function op_deploy(bytes32 txHash, bytes calldata data) external virtual onlyEthscriptions {
        // Decode the operation data
        DeployOperation memory deployOp = abi.decode(data, (DeployOperation));

        bytes32 tickKey = _getTickKey(deployOp.tick);
        TokenInfo storage token = tokensByTick[tickKey];

        // Revert if token already exists
        if (token.deployTxHash != bytes32(0)) revert TokenAlreadyDeployed();

        _deployToken(
            txHash,
            tickKey,
            protocolName(),
            deployOp.tick,
            deployOp.maxSupply,
            deployOp.mintAmount
        );
    }

    /// @notice Handle mint operation
    /// @param txHash The ethscription transaction hash
    /// @param data The encoded MintOperation data
    function op_mint(bytes32 txHash, bytes calldata data) external virtual onlyEthscriptions {
        // Decode the operation data
        MintOperation memory mintOp = abi.decode(data, (MintOperation));

        bytes32 tickKey = _getTickKey(mintOp.tick);
        TokenInfo storage token = tokensByTick[tickKey];

        // Token must exist to mint
        if (token.deployTxHash == bytes32(0)) revert TokenNotDeployed();

        // Validate mint amount matches token's configured limit
        if (mintOp.amount != token.mintAmount) revert MintAmountMismatch();

        // Validate mint ID is within valid range (1 to maxId)
        // maxId = maxSupply / mintAmount (both are in user units, not 18 decimals)
        uint256 maxId = token.maxSupply / token.mintAmount;
        if (mintOp.id < 1 || mintOp.id > maxId) revert InvalidMintId();

        // Get the initial owner from the Ethscriptions contract
        Ethscriptions ethscriptionsContract = Ethscriptions(ethscriptions);
        Ethscriptions.Ethscription memory ethscription = ethscriptionsContract.getEthscription(txHash);
        address initialOwner = ethscription.initialOwner;

        // Track this ethscription as a token item
        tokenItems[txHash] = TokenItem({
            deployTxHash: token.deployTxHash,
            amount: mintOp.amount
        });

        // Mint tokens to the initial owner - convert to 18 decimals
        EthscriptionsERC20(token.tokenContract).mint(initialOwner, mintOp.amount * 10**18);

        // Update total minted after successful mint
        token.totalMinted += mintOp.amount;

        emit TokenMinted(token.deployTxHash, initialOwner, mintOp.amount, txHash);
    }

    /// @notice Handle transfer notification from Ethscriptions contract
    /// @dev Implementation of IProtocolHandler interface
    /// @param txHash The ethscription transaction hash being transferred
    /// @param from The address transferring from
    /// @param to The address transferring to
    function onTransfer(
        bytes32 txHash,
        address from,
        address to
    ) external virtual override onlyEthscriptions {
        TokenItem memory item = tokenItems[txHash];

        // Not a token item, nothing to do
        if (item.deployTxHash == bytes32(0)) return;

        bytes32 tickKey = deployToTick[item.deployTxHash];
        TokenInfo storage token = tokensByTick[tickKey];

        // Force transfer tokens (shadow transfer) - convert to 18 decimals
        EthscriptionsERC20(token.tokenContract).forceTransfer(from, to, item.amount * 10**18);

        emit TokenTransferred(item.deployTxHash, from, to, item.amount, txHash);
        // Proofs will be automatically generated by EthscriptionsERC20._update
    }

    // =============================================================
    //                  EXTERNAL VIEW FUNCTIONS
    // =============================================================

    /// @notice Get token contract address by deploy transaction hash
    /// @param deployTxHash The deployment transaction hash
    /// @return The token contract address
    function getTokenAddress(bytes32 deployTxHash) external view returns (address) {
        bytes32 tickKey = deployToTick[deployTxHash];
        return tokensByTick[tickKey].tokenContract;
    }

    /// @notice Get token contract address by tick
    /// @param tick The token tick symbol
    /// @return The token contract address
    function getTokenAddressByTick(string memory tick) external view returns (address) {
        bytes32 tickKey = _getTickKey(tick);
        return tokensByTick[tickKey].tokenContract;
    }

    /// @notice Get complete token information by deploy transaction hash
    /// @param deployTxHash The deployment transaction hash
    /// @return The TokenInfo struct
    function getTokenInfo(bytes32 deployTxHash) external view returns (TokenInfo memory) {
        bytes32 tickKey = deployToTick[deployTxHash];
        return tokensByTick[tickKey];
    }

    /// @notice Get complete token information by tick
    /// @param tick The token tick symbol
    /// @return The TokenInfo struct
    function getTokenInfoByTick(string memory tick) external view returns (TokenInfo memory) {
        bytes32 tickKey = _getTickKey(tick);
        return tokensByTick[tickKey];
    }

    /// @notice Predict token address for a tick (before deployment)
    /// @param tick The token tick symbol
    /// @return The predicted or actual token address
    function predictTokenAddressByTick(string memory tick) external view returns (address) {
        bytes32 tickKey = _getTickKey(tick);

        // Check if already deployed
        if (tokensByTick[tickKey].tokenContract != address(0)) {
            return tokensByTick[tickKey].tokenContract;
        }

        // Predict using CREATE2
        return Clones.predictDeterministicAddress(erc20Template, tickKey, address(this));
    }

    /// @notice Check if an ethscription is a token item
    /// @param ethscriptionTxHash The ethscription transaction hash
    /// @return True if the ethscription represents tokens
    function isTokenItem(bytes32 ethscriptionTxHash) external view returns (bool) {
        return tokenItems[ethscriptionTxHash].deployTxHash != bytes32(0);
    }

    /// @notice Get token amount for an ethscription
    /// @param ethscriptionTxHash The ethscription transaction hash
    /// @return The amount of tokens this ethscription represents
    function getTokenAmount(bytes32 ethscriptionTxHash) external view returns (uint256) {
        return tokenItems[ethscriptionTxHash].amount;
    }

    /// @notice Get complete token item information
    /// @param ethscriptionTxHash The ethscription transaction hash
    /// @return The TokenItem struct
    function getTokenItem(bytes32 ethscriptionTxHash) external view returns (TokenItem memory) {
        return tokenItems[ethscriptionTxHash];
    }

    // =============================================================
    //                   PUBLIC VIEW FUNCTIONS
    // =============================================================

    /// @notice Returns human-readable protocol name
    /// @return The protocol name
    function protocolName() public pure override returns (string memory) {
        return "erc-20";
    }

    // =============================================================
    //                    PRIVATE FUNCTIONS
    // =============================================================

    /// @notice Generate tick key for storage mapping
    /// @param tick The token tick symbol
    /// @return The tick key for storage lookups
    function _getTickKey(string memory tick) private pure returns (bytes32) {
        // Use the protocol name from this handler
        return keccak256(abi.encode("erc-20", tick));
    }

    /// @notice Deploy a new token
    /// @param deployTxHash The deployment transaction hash
    /// @param tickKey The tick key for storage
    /// @param protocol The protocol name
    /// @param tick The token tick symbol
    /// @param maxSupply The maximum supply (in user units)
    /// @param mintAmount The amount per mint (in user units)
    function _deployToken(
        bytes32 deployTxHash,
        bytes32 tickKey,
        string memory protocol,
        string memory tick,
        uint256 maxSupply,
        uint256 mintAmount
    ) private {
        if (maxSupply == 0) revert InvalidMaxSupply();
        if (mintAmount == 0) revert InvalidMintAmount();
        if (maxSupply % mintAmount != 0) revert MaxSupplyNotDivisibleByMintAmount();

        // Deploy ERC20 clone with CREATE2 using tickKey as salt for deterministic address
        address tokenAddress = erc20Template.cloneDeterministic(tickKey);

        // Initialize the clone
        string memory name = string.concat(protocol, " ", tick);
        string memory symbol = LibString.upper(tick);

        // Initialize with max supply in 18 decimals
        // User maxSupply "1000000" means 1000000 * 10^18 smallest units
        EthscriptionsERC20(tokenAddress).initialize(
            name,
            symbol,
            maxSupply * 10**18,
            deployTxHash
        );

        // Store token info
        tokensByTick[tickKey] = TokenInfo({
            tokenContract: tokenAddress,
            deployTxHash: deployTxHash,
            protocol: protocol,
            tick: tick,
            maxSupply: maxSupply,
            mintAmount: mintAmount,
            totalMinted: 0
        });

        // Map deploy hash to tick key for lookups
        deployToTick[deployTxHash] = tickKey;

        emit TokenDeployed(deployTxHash, tokenAddress, tick, maxSupply, mintAmount);
    }
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/proxy/Clones.sol";
import {LibString} from "solady/utils/LibString.sol";
import "./EthscriptionsERC20.sol";
import "./Ethscriptions.sol";
import "./libraries/Predeploys.sol";
import "./protocols/IProtocolHandler.sol";

contract TokenManager is IProtocolHandler {
    using Clones for address;
    using LibString for string;

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

    address public constant erc20Template = Predeploys.ERC20_TEMPLATE;
    address public constant ethscriptions = Predeploys.ETHSCRIPTIONS;
    
    // Track deployed tokens by protocol+tick for find-or-create
    mapping(bytes32 => TokenInfo) public tokensByTick;  // keccak256(abi.encode(protocol, tick)) => TokenInfo
    mapping(bytes32 => bytes32) public deployToTick;     // deployTxHash => tickKey
    
    // Track which ethscription is a token item
    mapping(bytes32 => TokenItem) public tokenItems;  // ethscription tx hash => TokenItem
    
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

    modifier onlyEthscriptions() {
        require(msg.sender == ethscriptions, "Only Ethscriptions contract");
        _;
    }
    
    function _getTickKey(string memory tick) private pure returns (bytes32) {
        // Use the protocol name from this handler
        return keccak256(abi.encode(protocolName(), tick));
    }

    /// @notice Handle deploy operation
    function op_deploy(bytes32 txHash, bytes calldata data) external virtual onlyEthscriptions {
        // Decode the operation data
        DeployOperation memory deployOp = abi.decode(data, (DeployOperation));

        bytes32 tickKey = _getTickKey(deployOp.tick);
        TokenInfo storage token = tokensByTick[tickKey];

        // Revert if token already exists
        require(token.deployTxHash == bytes32(0), "Token already deployed");

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
    function op_mint(bytes32 txHash, bytes calldata data) external virtual onlyEthscriptions {
        // Get the initial owner from the Ethscriptions contract
        Ethscriptions ethscriptionsContract = Ethscriptions(ethscriptions);
        Ethscriptions.Ethscription memory ethscription = ethscriptionsContract.getEthscription(txHash);
        address initialOwner = ethscription.initialOwner;

        // Decode the operation data
        MintOperation memory mintOp = abi.decode(data, (MintOperation));

        bytes32 tickKey = _getTickKey(mintOp.tick);
        TokenInfo storage token = tokensByTick[tickKey];

        // Token must exist to mint
        require(token.deployTxHash != bytes32(0), "Token not deployed");

        // Validate mint amount matches token's configured limit
        require(mintOp.amount == token.mintAmount, "amt mismatch");

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
    function onTransfer(
        bytes32 txHash,
        address from,
        address to
    ) external virtual override onlyEthscriptions {
        bytes32 ethscriptionHash = txHash;
        bytes32 ethscriptionTxHash = ethscriptionHash;
        TokenItem memory item = tokenItems[ethscriptionTxHash];
        if (item.deployTxHash == bytes32(0)) {
            // Not a token item, nothing to do
            return;
        }
        
        bytes32 tickKey = deployToTick[item.deployTxHash];
        TokenInfo storage token = tokensByTick[tickKey];
        
        // Force transfer tokens (shadow transfer) - convert to 18 decimals
        EthscriptionsERC20(token.tokenContract).forceTransfer(from, to, item.amount * 10**18);
        
        emit TokenTransferred(item.deployTxHash, from, to, item.amount, ethscriptionTxHash);
        // Proofs will be automatically generated by EthscriptionsERC20._update
    }

    function _deployToken(
        bytes32 deployTxHash,
        bytes32 tickKey,
        string memory protocol,
        string memory tick,
        uint256 maxSupply,
        uint256 mintAmount
    ) private {
        require(maxSupply > 0, "Invalid max supply");
        require(mintAmount > 0, "Invalid mint amount");
        require(maxSupply % mintAmount == 0, "Max supply must be divisible by mint amount");
        
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

    // View functions
    function getTokenAddress(bytes32 deployTxHash) external view returns (address) {
        bytes32 tickKey = deployToTick[deployTxHash];
        return tokensByTick[tickKey].tokenContract;
    }

    function getTokenAddressByTick(string memory tick) external view returns (address) {
        bytes32 tickKey = _getTickKey(tick);
        return tokensByTick[tickKey].tokenContract;
    }

    function getTokenInfo(bytes32 deployTxHash) external view returns (TokenInfo memory) {
        bytes32 tickKey = deployToTick[deployTxHash];
        return tokensByTick[tickKey];
    }

    function getTokenInfoByTick(string memory tick) external view returns (TokenInfo memory) {
        bytes32 tickKey = _getTickKey(tick);
        return tokensByTick[tickKey];
    }

    function predictTokenAddressByTick(string memory tick) external view returns (address) {
        bytes32 tickKey = _getTickKey(tick);
        
        // Check if already deployed
        if (tokensByTick[tickKey].tokenContract != address(0)) {
            return tokensByTick[tickKey].tokenContract;
        }
        
        // Predict using CREATE2
        return Clones.predictDeterministicAddress(erc20Template, tickKey, address(this));
    }
    
    function isTokenItem(bytes32 ethscriptionTxHash) external view returns (bool) {
        return tokenItems[ethscriptionTxHash].deployTxHash != bytes32(0);
    }
    
    function getTokenAmount(bytes32 ethscriptionTxHash) external view returns (uint256) {
        return tokenItems[ethscriptionTxHash].amount;
    }
    
    function getTokenItem(bytes32 ethscriptionTxHash) external view returns (TokenItem memory) {
        return tokenItems[ethscriptionTxHash];
    }

    // IProtocolHandler implementation

    /// @notice Generic sync entrypoint for protocol-specific operations
    /// @dev Not used for token protocol
    function sync(bytes calldata) external pure override {
        // Not implemented for token protocol
        revert("Not implemented");
    }

    /// @notice Returns human-readable protocol name
    /// @return The protocol name
    function protocolName() public pure override returns (string memory) {
        return "erc-20";
    }
}

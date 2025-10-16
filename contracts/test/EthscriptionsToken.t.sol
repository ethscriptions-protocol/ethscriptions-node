// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./TestSetup.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";

contract EthscriptionsTokenTest is TestSetup {
    address alice = address(0x1);
    address bob = address(0x2);
    address charlie = address(0x3);

    bytes32 constant DEPLOY_TX_HASH = bytes32(uint256(0x1234));
    bytes32 constant MINT_TX_HASH_1 = bytes32(uint256(0x5678));
    bytes32 constant MINT_TX_HASH_2 = bytes32(uint256(0x9ABC));

    // Event for tracking protocol handler failures
    event ProtocolHandlerFailed(
        bytes32 indexed transactionHash,
        string indexed protocol,
        bytes revertData
    );
    
    function setUp() public override {
        super.setUp();
    }

    // Helper to create token params
    function createTokenParams(
        bytes32 transactionHash,
        address initialOwner,
        string memory contentUri,
        string memory protocol,
        string memory operation,
        bytes memory data
    ) internal pure returns (Ethscriptions.CreateEthscriptionParams memory) {
        bytes memory contentUriBytes = bytes(contentUri);
        bytes32 contentUriHash = sha256(contentUriBytes);  // Use SHA-256 to match production

        // Extract content after "data:,"
        bytes memory content;
        if (contentUriBytes.length > 6) {
            content = new bytes(contentUriBytes.length - 6);
            for (uint256 i = 0; i < content.length; i++) {
                content[i] = contentUriBytes[i + 6];
            }
        }

        return Ethscriptions.CreateEthscriptionParams({
            transactionHash: transactionHash,
            contentUriHash: contentUriHash,
            initialOwner: initialOwner,
            content: content,
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: protocol,
                operation: operation,
                data: data
            })
        });
    }
    
    function testTokenDeploy() public {
        // Deploy a token as Alice
        vm.prank(alice);
        
        string memory deployContent = 'data:,{"p":"erc-20","op":"deploy","tick":"TEST","max":"1000000","lim":"1000"}';

        // For deploy operation, encode the deploy params
        TokenManager.DeployOperation memory deployOp = TokenManager.DeployOperation({
            tick: "TEST",
            maxSupply: 1000000,
            mintAmount: 1000
        });

        Ethscriptions.CreateEthscriptionParams memory params = createTokenParams(
            DEPLOY_TX_HASH,
            alice,
            deployContent,
            "erc-20",
            "deploy",
            abi.encode(deployOp)
        );

        ethscriptions.createEthscription(params);
        
        // Verify token was deployed
        TokenManager.TokenInfo memory tokenInfo = tokenManager.getTokenInfo(DEPLOY_TX_HASH);
            
        assertEq(tokenInfo.protocol, "erc-20");
        assertEq(tokenInfo.tick, "TEST");
        assertEq(tokenInfo.maxSupply, 1000000);
        assertEq(tokenInfo.mintAmount, 1000);
        assertEq(tokenInfo.totalMinted, 0);
        assertTrue(tokenInfo.tokenContract != address(0));
        
        // Verify Alice owns the deploy ethscription NFT
        Ethscriptions.Ethscription memory deployEthscription = ethscriptions.getEthscription(DEPLOY_TX_HASH);
        assertEq(ethscriptions.ownerOf(deployEthscription.ethscriptionNumber), alice);
    }
    
    function testTokenMint() public {
        // First deploy the token
        testTokenDeploy();
        
        // Now mint some tokens as Bob
        vm.prank(bob);
        
        string memory mintContent = 'data:,{"p":"erc-20","op":"mint","tick":"TEST","id":"1","amt":"1000"}';

        // For mint operation, encode the mint params
        TokenManager.MintOperation memory mintOp = TokenManager.MintOperation({
            tick: "TEST",
            id: 1,
            amount: 1000
        });

        Ethscriptions.CreateEthscriptionParams memory mintParams = createTokenParams(
            MINT_TX_HASH_1,
            bob,
            mintContent,
            "erc-20",
            "mint",
            abi.encode(mintOp)
        );

        ethscriptions.createEthscription(mintParams);
        
        // Verify Bob owns the mint ethscription NFT
        Ethscriptions.Ethscription memory mintEthscription = ethscriptions.getEthscription(MINT_TX_HASH_1);
        assertEq(ethscriptions.ownerOf(mintEthscription.ethscriptionNumber), bob);
        
        // Verify Bob has the tokens (1000 * 10^18 with 18 decimals)
        address tokenAddress = tokenManager.getTokenAddressByTick("TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddress);
        assertEq(token.balanceOf(bob), 1000 ether);  // 1000 * 10^18
        
        // Verify total minted increased
        TokenManager.TokenInfo memory info = tokenManager.getTokenInfo(DEPLOY_TX_HASH);
        assertEq(info.totalMinted, 1000);
    }
    
    function testTokenTransferViaNFT() public {
        // Setup: Deploy and mint
        testTokenMint();
        
        address tokenAddress = tokenManager.getTokenAddressByTick("TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddress);
        
        // Bob transfers the NFT to Charlie
        vm.prank(bob);
        ethscriptions.transferEthscription(charlie, MINT_TX_HASH_1);
        
        // Verify Charlie now owns the NFT
        Ethscriptions.Ethscription memory mintEthscription1 = ethscriptions.getEthscription(MINT_TX_HASH_1);
        assertEq(ethscriptions.ownerOf(mintEthscription1.ethscriptionNumber), charlie);
        
        // Verify tokens moved from Bob to Charlie
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(charlie), 1000 ether);
    }
    
    function testMultipleMints() public {
        // Deploy the token
        testTokenDeploy();
        
        address tokenAddress = tokenManager.getTokenAddressByTick("TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddress);
        
        // Bob mints tokens
        vm.prank(bob);
        string memory mintContent1 = 'data:,{"p":"erc-20","op":"mint","tick":"TEST","id":"1","amt":"1000"}';
        TokenManager.MintOperation memory mintOp1 = TokenManager.MintOperation({
            tick: "TEST",
            id: 1,
            amount: 1000
        });
        ethscriptions.createEthscription(createTokenParams(
            MINT_TX_HASH_1,
            bob,
            mintContent1,
            "erc-20",
            "mint",
            abi.encode(mintOp1)
        ));
        
        // Charlie mints tokens
        vm.prank(charlie);
        string memory mintContent2 = 'data:,{"p":"erc-20","op":"mint","tick":"TEST","id":"2","amt":"1000"}';
        TokenManager.MintOperation memory mintOp2 = TokenManager.MintOperation({
            tick: "TEST",
            id: 2,
            amount: 1000
        });
        ethscriptions.createEthscription(createTokenParams(
            MINT_TX_HASH_2,
            charlie,
            mintContent2,
            "erc-20",
            "mint",
            abi.encode(mintOp2)
        ));
        
        // Verify balances
        assertEq(token.balanceOf(bob), 1000 ether);
        assertEq(token.balanceOf(charlie), 1000 ether);
        
        // Verify total minted
        TokenManager.TokenInfo memory info = tokenManager.getTokenInfo(DEPLOY_TX_HASH);
        assertEq(info.totalMinted, 2000);
    }
    
    function testMaxSupplyEnforcement() public {
        // Deploy a token with very low max supply
        vm.prank(alice);
        
        bytes32 smallDeployHash = bytes32(uint256(0xDEAD));
        string memory deployContent = 'data:,{"p":"erc-20","op":"deploy","tick":"SMALL","max":"2000","lim":"1000"}';
        
        TokenManager.DeployOperation memory smallDeployOp = TokenManager.DeployOperation({
            tick: "SMALL",
            maxSupply: 2000,
            mintAmount: 1000
        });

        ethscriptions.createEthscription(createTokenParams(
            smallDeployHash,
            alice,
            deployContent,
            "erc-20",
            "deploy",
            abi.encode(smallDeployOp)
        ));
        
        // Mint up to max supply
        vm.prank(bob);
        TokenManager.MintOperation memory mintOp1Small = TokenManager.MintOperation({
            tick: "SMALL",
            id: 1,
            amount: 1000
        });
        ethscriptions.createEthscription(createTokenParams(
            bytes32(uint256(0xBEEF1)),
            bob,
            'data:,{"p":"erc-20","op":"mint","tick":"SMALL","id":"1","amt":"1000"}',
            "erc-20",
            "mint",
            abi.encode(mintOp1Small)
        ));
        
        vm.prank(charlie);
        TokenManager.MintOperation memory mintOp2Small = TokenManager.MintOperation({
            tick: "SMALL",
            id: 2,
            amount: 1000
        });
        ethscriptions.createEthscription(createTokenParams(
            bytes32(uint256(0xBEEF2)),
            charlie,
            'data:,{"p":"erc-20","op":"mint","tick":"SMALL","id":"2","amt":"1000"}',
            "erc-20",
            "mint",
            abi.encode(mintOp2Small)
        ));
        
        // Try to mint beyond max supply - should fail silently with event
        bytes32 exceedTxHash = bytes32(uint256(0xBEEF3));
        TokenManager.MintOperation memory exceedMintOp = TokenManager.MintOperation({
            tick: "SMALL",
            id: 3,
            amount: 1000
        });
        Ethscriptions.CreateEthscriptionParams memory exceedParams = createTokenParams(
            exceedTxHash,
            alice,
            'data:,{"p":"erc-20","op":"mint","tick":"SMALL","id":"3","amt":"1000"}',
            "erc-20",
            "mint",
            abi.encode(exceedMintOp)
        );

        // Token creation should succeed but mint will fail due to exceeding cap

        vm.prank(alice);
        uint256 tokenId = ethscriptions.createEthscription(exceedParams);

        // Ethscription should still be created (but mint failed)
        assertEq(ethscriptions.ownerOf(tokenId), alice);

        // Verify supply didn't increase
        address tokenAddress = tokenManager.getTokenAddressByTick("SMALL");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddress);
        assertEq(token.totalSupply(), 2000 ether); // Should still be at max
    }
    
    function testCannotTransferERC20Directly() public {
        // Setup
        testTokenMint();
        
        address tokenAddress = tokenManager.getTokenAddressByTick("TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddress);
        
        // Bob tries to transfer tokens directly (not via NFT) - should revert
        vm.prank(bob);
        vm.expectRevert("Transfers only allowed via Ethscriptions NFT");
        token.transfer(charlie, 500);
    }
    
    function testTokenAddressPredictability() public {
        // Predict the token address before deployment
        address predictedAddress = tokenManager.predictTokenAddressByTick("TEST");
        
        // Deploy the token
        testTokenDeploy();
        
        // Verify the actual address matches prediction
        address actualAddress = tokenManager.getTokenAddressByTick("TEST");
        assertEq(actualAddress, predictedAddress);
    }
    
    function testMintAmountMustMatch() public {
        // Deploy token with lim=1000
        testTokenDeploy();

        // Try to mint with wrong amount - should fail silently with event
        string memory wrongAmountContent = 'data:,{"p":"erc-20","op":"mint","tick":"TEST","id":"1","amt":"500"}';

        bytes32 wrongTxHash = bytes32(uint256(0xBAD));
        TokenManager.MintOperation memory wrongMintOp = TokenManager.MintOperation({
            tick: "TEST",
            id: 1,
            amount: 500  // Wrong - should be 1000 to match lim
        });
        Ethscriptions.CreateEthscriptionParams memory wrongParams = createTokenParams(
            wrongTxHash,
            bob,
            wrongAmountContent,
            "erc-20",
            "mint",
            abi.encode(wrongMintOp)
        );

        // Token creation should succeed but mint will fail due to amount mismatch

        vm.prank(bob);
        uint256 tokenId = ethscriptions.createEthscription(wrongParams);

        // Ethscription should still be created (but mint failed)
        assertEq(ethscriptions.ownerOf(tokenId), bob);

        // Verify no tokens were minted
        address tokenAddr = tokenManager.getTokenAddressByTick("TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddr);
        assertEq(token.balanceOf(bob), 0); // Bob should have no tokens
    }
    
    function testCannotDeployTokenTwice() public {
        // First deploy should succeed
        testTokenDeploy();

        // Try to deploy the same token again with different parameters - should fail silently with event
        // Different max supply in content to avoid duplicate content error
        string memory deployContent = 'data:,{"p":"erc-20","op":"deploy","tick":"TEST","max":"2000000","lim":"2000"}';

        bytes32 duplicateTxHash = bytes32(uint256(0xABCD));
        TokenManager.DeployOperation memory duplicateDeployOp = TokenManager.DeployOperation({
            tick: "TEST",
            maxSupply: 2000000,  // Different parameters but same tick
            mintAmount: 2000
        });

        Ethscriptions.CreateEthscriptionParams memory duplicateParams = createTokenParams(
            duplicateTxHash,
            alice,
            deployContent,
            "erc-20",
            "deploy",
            abi.encode(duplicateDeployOp)
        );

        // Token creation should succeed but deploy will fail due to duplicate

        vm.prank(alice);
        uint256 tokenId = ethscriptions.createEthscription(duplicateParams);

        // Ethscription should still be created (but token deploy failed)
        assertEq(ethscriptions.ownerOf(tokenId), alice);

        // Verify the original token is still the only one
        address tokenAddr = tokenManager.getTokenAddressByTick("TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddr);
        assertEq(token.name(), "erc-20 TEST");  // Token name format is "protocol tick"
        assertEq(token.maxSupply(), 1000000 ether); // Original cap (maxSupply), not the duplicate's
    }

    function testMintWithInvalidIdZero() public {
        // Deploy the token first
        testTokenDeploy();

        // Try to mint with ID 0 (invalid - must be >= 1)
        vm.prank(bob);
        string memory mintContent = 'data:,{"p":"erc-20","op":"mint","tick":"TEST","id":"0","amt":"1000"}';

        TokenManager.MintOperation memory mintOp = TokenManager.MintOperation({
            tick: "TEST",
            id: 0, // Invalid ID - should be >= 1
            amount: 1000
        });

        bytes32 invalidMintHash = bytes32(uint256(0xDEAD));
        Ethscriptions.CreateEthscriptionParams memory mintParams = createTokenParams(
            invalidMintHash,
            bob,
            mintContent,
            "erc-20",
            "mint",
            abi.encode(mintOp)
        );

        // Create the ethscription - mint should fail due to invalid ID
        uint256 tokenId = ethscriptions.createEthscription(mintParams);

        // Ethscription should still be created (but mint failed)
        assertEq(ethscriptions.ownerOf(tokenId), bob);

        // Verify no tokens were minted due to invalid ID
        address tokenAddr = tokenManager.getTokenAddressByTick("TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddr);
        assertEq(token.balanceOf(bob), 0); // Bob should have no tokens

        // Verify total minted didn't increase
        TokenManager.TokenInfo memory info = tokenManager.getTokenInfo(DEPLOY_TX_HASH);
        assertEq(info.totalMinted, 0);
    }

    function testMintWithIdTooHigh() public {
        // Deploy the token first
        testTokenDeploy();

        // Try to mint with ID beyond maxId (maxSupply/mintAmount = 1000000/1000 = 1000)
        vm.prank(bob);
        string memory mintContent = 'data:,{"p":"erc-20","op":"mint","tick":"TEST","id":"1001","amt":"1000"}';

        TokenManager.MintOperation memory mintOp = TokenManager.MintOperation({
            tick: "TEST",
            id: 1001, // Invalid ID - maxId is 1000
            amount: 1000
        });

        bytes32 invalidMintHash = bytes32(uint256(0xBEEF));
        Ethscriptions.CreateEthscriptionParams memory mintParams = createTokenParams(
            invalidMintHash,
            bob,
            mintContent,
            "erc-20",
            "mint",
            abi.encode(mintOp)
        );

        // Create the ethscription - mint should fail due to ID too high
        uint256 tokenId = ethscriptions.createEthscription(mintParams);

        // Ethscription should still be created (but mint failed)
        assertEq(ethscriptions.ownerOf(tokenId), bob);

        // Verify no tokens were minted due to invalid ID
        address tokenAddr = tokenManager.getTokenAddressByTick("TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddr);
        assertEq(token.balanceOf(bob), 0); // Bob should have no tokens

        // Verify total minted didn't increase
        TokenManager.TokenInfo memory info = tokenManager.getTokenInfo(DEPLOY_TX_HASH);
        assertEq(info.totalMinted, 0);
    }

    function testMintWithMaxValidId() public {
        // Deploy the token first
        testTokenDeploy();

        // Mint with the maximum valid ID (maxSupply/mintAmount = 1000000/1000 = 1000)
        vm.prank(bob);
        string memory mintContent = 'data:,{"p":"erc-20","op":"mint","tick":"TEST","id":"1000","amt":"1000"}';

        TokenManager.MintOperation memory mintOp = TokenManager.MintOperation({
            tick: "TEST",
            id: 1000, // Maximum valid ID
            amount: 1000
        });

        bytes32 validMintHash = bytes32(uint256(0xCAFE));
        Ethscriptions.CreateEthscriptionParams memory mintParams = createTokenParams(
            validMintHash,
            bob,
            mintContent,
            "erc-20",
            "mint",
            abi.encode(mintOp)
        );

        uint256 tokenId = ethscriptions.createEthscription(mintParams);

        // Verify Bob owns the mint ethscription NFT
        assertEq(ethscriptions.ownerOf(tokenId), bob);

        // Verify Bob has the tokens (1000 * 10^18 with 18 decimals)
        address tokenAddr = tokenManager.getTokenAddressByTick("TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddr);
        assertEq(token.balanceOf(bob), 1000 ether); // Should have tokens

        // Verify total minted increased
        TokenManager.TokenInfo memory info = tokenManager.getTokenInfo(DEPLOY_TX_HASH);
        assertEq(info.totalMinted, 1000);
    }

    function testMintToNullOwnerMintsERC20ToZero() public {
        // Deploy the token under tick TEST
        testTokenDeploy();

        // Prepare a mint where the Ethscription initial owner is the null address
        bytes32 nullMintTx = bytes32(uint256(0xBADD0));
        string memory mintContent = 'data:,{"p":"erc-20","op":"mint","tick":"TEST","id":"1","amt":"1000"}';

        TokenManager.MintOperation memory mintOp = TokenManager.MintOperation({
            tick: "TEST",
            id: 1,
            amount: 1000
        });

        // Creator is Alice, but initial owner is address(0)
        Ethscriptions.CreateEthscriptionParams memory params = createTokenParams(
            nullMintTx,
            address(0),
            mintContent,
            "erc-20",
            "mint",
            abi.encode(mintOp)
        );

        vm.prank(alice);
        uint256 tokenId = ethscriptions.createEthscription(params);

        // The NFT should exist and end up owned by the null address
        assertEq(ethscriptions.ownerOf(tokenId), address(0));

        // ERC20 should be minted and credited to the null address
        address tokenAddr = tokenManager.getTokenAddressByTick("TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddr);
        assertEq(token.totalSupply(), 1000 ether);
        assertEq(token.balanceOf(address(0)), 1000 ether);

        // TokenManager should record a token item and increase total minted
        assertTrue(tokenManager.isTokenItem(nullMintTx));
        TokenManager.TokenInfo memory info = tokenManager.getTokenInfo(DEPLOY_TX_HASH);
        assertEq(info.totalMinted, 1000);
    }

    function testTransferTokenItemToNullAddressMovesERC20ToZero() public {
        // Setup: deploy and mint a token item to Bob
        testTokenMint();

        address tokenAddr = tokenManager.getTokenAddressByTick("TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddr);

        // Sanity: Bob has the ERC20 minted via the token item
        assertEq(token.balanceOf(bob), 1000 ether);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), 1000 ether);

        // Transfer the NFT representing the token item to the null address
        Ethscriptions.Ethscription memory mintEthscription = ethscriptions.getEthscription(MINT_TX_HASH_1);
        vm.prank(bob);
        ethscriptions.transferEthscription(address(0), MINT_TX_HASH_1);

        // The NFT should now be owned by the null address
        assertEq(ethscriptions.ownerOf(mintEthscription.ethscriptionNumber), address(0));

        // ERC20 transfer follows NFT to null owner
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(0)), 1000 ether);
        assertEq(token.totalSupply(), 1000 ether);
    }
}

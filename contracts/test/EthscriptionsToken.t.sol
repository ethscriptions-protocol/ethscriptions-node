// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestSetup.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";

contract EthscriptionsTokenTest is TestSetup {
    address alice = address(0x1);
    address bob = address(0x2);
    address charlie = address(0x3);
    
    bytes32 constant DEPLOY_TX_HASH = bytes32(uint256(0x1234));
    bytes32 constant MINT_TX_HASH_1 = bytes32(uint256(0x5678));
    bytes32 constant MINT_TX_HASH_2 = bytes32(uint256(0x9ABC));
    
    function setUp() public override {
        super.setUp();
    }
    
    function testTokenDeploy() public {
        // Deploy a token as Alice
        vm.prank(alice);
        
        string memory deployContent = 'data:,{"p":"erc-20","op":"deploy","tick":"TEST","max":"1000000","lim":"1000"}';
        
        Ethscriptions.CreateEthscriptionParams memory params = Ethscriptions.CreateEthscriptionParams({
            transactionHash: DEPLOY_TX_HASH,
            initialOwner: alice,
            contentUri: bytes(deployContent),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            isCompressed: false,
            tokenParams: Ethscriptions.TokenParams({
                op: "deploy",
                protocol: "erc-20",
                tick: "TEST",
                max: 1000000,
                lim: 1000,
                amt: 0
            })
        });
        
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
        assertEq(ethscriptions.ownerOf(uint256(DEPLOY_TX_HASH)), alice);
    }
    
    function testTokenMint() public {
        // First deploy the token
        testTokenDeploy();
        
        // Now mint some tokens as Bob
        vm.prank(bob);
        
        string memory mintContent = 'data:,{"p":"erc-20","op":"mint","tick":"TEST","id":"1","amt":"1000"}';
        
        Ethscriptions.CreateEthscriptionParams memory mintParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: MINT_TX_HASH_1,
            initialOwner: bob,
            contentUri: bytes(mintContent),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            isCompressed: false,
            tokenParams: Ethscriptions.TokenParams({
                op: "mint",
                protocol: "erc-20",
                tick: "TEST",
                max: 0,
                lim: 0,
                amt: 1000
            })
        });
        
        ethscriptions.createEthscription(mintParams);
        
        // Verify Bob owns the mint ethscription NFT
        assertEq(ethscriptions.ownerOf(uint256(MINT_TX_HASH_1)), bob);
        
        // Verify Bob has the tokens (1000 * 10^18 with 18 decimals)
        address tokenAddress = tokenManager.getTokenAddressByTick("erc-20", "TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddress);
        assertEq(token.balanceOf(bob), 1000 ether);  // 1000 * 10^18
        
        // Verify total minted increased
        TokenManager.TokenInfo memory info = tokenManager.getTokenInfo(DEPLOY_TX_HASH);
        assertEq(info.totalMinted, 1000);
    }
    
    function testTokenTransferViaNFT() public {
        // Setup: Deploy and mint
        testTokenMint();
        
        address tokenAddress = tokenManager.getTokenAddressByTick("erc-20", "TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddress);
        
        // Bob transfers the NFT to Charlie
        vm.prank(bob);
        ethscriptions.transferEthscription(charlie, MINT_TX_HASH_1);
        
        // Verify Charlie now owns the NFT
        assertEq(ethscriptions.ownerOf(uint256(MINT_TX_HASH_1)), charlie);
        
        // Verify tokens moved from Bob to Charlie
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(charlie), 1000 ether);
    }
    
    function testMultipleMints() public {
        // Deploy the token
        testTokenDeploy();
        
        address tokenAddress = tokenManager.getTokenAddressByTick("erc-20", "TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddress);
        
        // Bob mints tokens
        vm.prank(bob);
        string memory mintContent1 = 'data:,{"p":"erc-20","op":"mint","tick":"TEST","id":"1","amt":"1000"}';
        ethscriptions.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: MINT_TX_HASH_1,
            initialOwner: bob,
            contentUri: bytes(mintContent1),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            isCompressed: false,
            tokenParams: Ethscriptions.TokenParams({
                op: "mint",
                protocol: "erc-20",
                tick: "TEST",
                max: 0,
                lim: 0,
                amt: 1000
            })
        }));
        
        // Charlie mints tokens
        vm.prank(charlie);
        string memory mintContent2 = 'data:,{"p":"erc-20","op":"mint","tick":"TEST","id":"2","amt":"1000"}';
        ethscriptions.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: MINT_TX_HASH_2,
            initialOwner: charlie,
            contentUri: bytes(mintContent2),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            isCompressed: false,
            tokenParams: Ethscriptions.TokenParams({
                op: "mint",
                protocol: "erc-20",
                tick: "TEST",
                max: 0,
                lim: 0,
                amt: 1000
            })
        }));
        
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
        
        ethscriptions.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: smallDeployHash,
            initialOwner: alice,
            contentUri: bytes(deployContent),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            isCompressed: false,
            tokenParams: Ethscriptions.TokenParams({
                op: "deploy",
                protocol: "erc-20",
                tick: "SMALL",
                max: 2000,
                lim: 1000,
                amt: 0
            })
        }));
        
        // Mint up to max supply
        vm.prank(bob);
        ethscriptions.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0xBEEF1)),
            initialOwner: bob,
            contentUri: bytes('data:,{"p":"erc-20","op":"mint","tick":"SMALL","id":"1","amt":"1000"}'),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            isCompressed: false,
            tokenParams: Ethscriptions.TokenParams({
                op: "mint",
                protocol: "erc-20",
                tick: "SMALL",
                max: 0,
                lim: 0,
                amt: 1000
            })
        }));
        
        vm.prank(charlie);
        ethscriptions.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0xBEEF2)),
            initialOwner: charlie,
            contentUri: bytes('data:,{"p":"erc-20","op":"mint","tick":"SMALL","id":"2","amt":"1000"}'),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            isCompressed: false,
            tokenParams: Ethscriptions.TokenParams({
                op: "mint",
                protocol: "erc-20",
                tick: "SMALL",
                max: 0,
                lim: 0,
                amt: 1000
            })
        }));
        
        // Try to mint beyond max supply - should revert
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC20CappedUpgradeable.ERC20ExceededCap.selector, 3000 ether, 2000 ether));
        ethscriptions.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0xBEEF3)),
            initialOwner: alice,
            contentUri: bytes('data:,{"p":"erc-20","op":"mint","tick":"SMALL","id":"3","amt":"1000"}'),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            isCompressed: false,
            tokenParams: Ethscriptions.TokenParams({
                op: "mint",
                protocol: "erc-20",
                tick: "SMALL",
                max: 0,
                lim: 0,
                amt: 1000
            })
        }));
    }
    
    function testCannotTransferERC20Directly() public {
        // Setup
        testTokenMint();
        
        address tokenAddress = tokenManager.getTokenAddressByTick("erc-20", "TEST");
        EthscriptionsERC20 token = EthscriptionsERC20(tokenAddress);
        
        // Bob tries to transfer tokens directly (not via NFT) - should revert
        vm.prank(bob);
        vm.expectRevert("Transfers only allowed via Ethscriptions NFT");
        token.transfer(charlie, 500);
    }
    
    function testTokenAddressPredictability() public {
        // Predict the token address before deployment
        address predictedAddress = tokenManager.predictTokenAddressByTick("erc-20", "TEST");
        
        // Deploy the token
        testTokenDeploy();
        
        // Verify the actual address matches prediction
        address actualAddress = tokenManager.getTokenAddressByTick("erc-20", "TEST");
        assertEq(actualAddress, predictedAddress);
    }
    
    function testMintAmountMustMatch() public {
        // Deploy token with lim=1000
        testTokenDeploy();
        
        // Try to mint with wrong amount - should revert
        vm.prank(bob);
        vm.expectRevert("amt mismatch");
        
        string memory wrongAmountContent = 'data:,{"p":"erc-20","op":"mint","tick":"TEST","id":"1","amt":"500"}';
        
        ethscriptions.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0xBAD)),
            initialOwner: bob,
            contentUri: bytes(wrongAmountContent),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            isCompressed: false,
            tokenParams: Ethscriptions.TokenParams({
                op: "mint",
                protocol: "erc-20",
                tick: "TEST",
                max: 0,
                lim: 0,
                amt: 500  // Wrong - should be 1000 to match lim
            })
        }));
    }
    
    function testCannotDeployTokenTwice() public {
        // First deploy should succeed
        testTokenDeploy();
        
        // Try to deploy the same token again with different parameters - should revert
        vm.prank(alice);
        vm.expectRevert("Token already deployed");
        
        // Different max supply in content to avoid duplicate content error
        string memory deployContent = 'data:,{"p":"erc-20","op":"deploy","tick":"TEST","max":"2000000","lim":"2000"}';
        
        ethscriptions.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(0xABCD)), // Different tx hash
            initialOwner: alice,
            contentUri: bytes(deployContent),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            isCompressed: false,
            tokenParams: Ethscriptions.TokenParams({
                op: "deploy",
                protocol: "erc-20",
                tick: "TEST",
                max: 2000000,  // Different parameters but same tick
                lim: 2000,
                amt: 0
            })
        }));
    }
}
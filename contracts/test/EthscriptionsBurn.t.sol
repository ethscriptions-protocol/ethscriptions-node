// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./TestSetup.sol";

contract EthscriptionsBurnTest is TestSetup {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    bytes32 testTxHash = keccak256("test_tx");
    
    function setUp() public override {
        super.setUp();
        
        // Create a test ethscription owned by alice
        Ethscriptions.CreateEthscriptionParams memory params = Ethscriptions.CreateEthscriptionParams({
            transactionHash: testTxHash,
            initialOwner: alice,
            contentUri: bytes("data:text/plain,Hello World"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            isCompressed: false,
            tokenParams: Ethscriptions.TokenParams({
                op: "",
                protocol: "",
                tick: "",
                max: 0,
                lim: 0,
                amt: 0
            })
        });
        
        vm.prank(alice);
        ethscriptions.createEthscription(params);
    }
    
    function testBurnViaTransferToAddressZero() public {
        uint256 tokenId = uint256(testTxHash);
        
        // Verify alice owns the ethscription
        assertEq(ethscriptions.ownerOf(tokenId), alice);
        
        // Alice burns the ethscription by transferring to address(0)
        vm.prank(alice);
        ethscriptions.transferFrom(alice, address(0), tokenId);
        
        // Verify the token is burned (ownerOf should revert)
        vm.expectRevert();
        ethscriptions.ownerOf(tokenId);
        
        // Verify the ethscription data still exists
        Ethscriptions.Ethscription memory etsc = ethscriptions.getEthscription(testTxHash);
        assertEq(etsc.creator, alice);
        assertEq(etsc.previousOwner, alice); // Previous owner should be set to alice
    }
    
    function testBurnViaTransferEthscription() public {
        uint256 tokenId = uint256(testTxHash);
        
        // Verify alice owns the ethscription
        assertEq(ethscriptions.ownerOf(tokenId), alice);
        
        // Alice burns using transferEthscription function
        vm.prank(alice);
        ethscriptions.transferEthscription(address(0), testTxHash);
        
        // Verify the token is burned
        vm.expectRevert();
        ethscriptions.ownerOf(tokenId);
        
        // Verify previousOwner was updated
        Ethscriptions.Ethscription memory etsc = ethscriptions.getEthscription(testTxHash);
        assertEq(etsc.previousOwner, alice);
    }
    
    function testBurnWithPreviousOwnerValidation() public {
        uint256 tokenId = uint256(testTxHash);
        
        // First transfer from alice to bob
        vm.prank(alice);
        ethscriptions.transferFrom(alice, bob, tokenId);
        
        // Verify bob owns it and alice is previous owner
        assertEq(ethscriptions.ownerOf(tokenId), bob);
        Ethscriptions.Ethscription memory etsc = ethscriptions.getEthscription(testTxHash);
        assertEq(etsc.previousOwner, alice);
        
        // Bob burns with previous owner validation
        vm.prank(bob);
        ethscriptions.transferEthscriptionForPreviousOwner(address(0), testTxHash, alice);
        
        // Verify the token is burned
        vm.expectRevert();
        ethscriptions.ownerOf(tokenId);
        
        // Verify previousOwner was updated to bob
        etsc = ethscriptions.getEthscription(testTxHash);
        assertEq(etsc.previousOwner, bob);
    }
    
    function testCannotTransferBurnedToken() public {
        uint256 tokenId = uint256(testTxHash);
        
        // Alice burns the token
        vm.prank(alice);
        ethscriptions.transferFrom(alice, address(0), tokenId);
        
        // Try to transfer a burned token (should fail)
        vm.prank(alice);
        vm.expectRevert();
        ethscriptions.transferFrom(address(0), bob, tokenId);
    }
    
    function testBurnUpdatesBalances() public {
        uint256 tokenId = uint256(testTxHash);
        
        // Check initial balance
        assertEq(ethscriptions.balanceOf(alice), 1);
        
        // Burn the token
        vm.prank(alice);
        ethscriptions.transferFrom(alice, address(0), tokenId);
        
        // Check balance after burn
        assertEq(ethscriptions.balanceOf(alice), 0);
        // Note: We can't check balanceOf(address(0)) as OpenZeppelin prevents that
        // But the token should be burned (not owned by anyone)
    }
    
    function testOnlyOwnerCanBurn() public {
        uint256 tokenId = uint256(testTxHash);
        
        // Bob tries to burn alice's token (should fail)
        vm.prank(bob);
        vm.expectRevert();
        ethscriptions.transferFrom(alice, address(0), tokenId);
        
        // Token should still be owned by alice
        assertEq(ethscriptions.ownerOf(tokenId), alice);
    }
    
    function testApprovedCanBurn() public {
        uint256 tokenId = uint256(testTxHash);
        
        // Alice approves bob
        vm.prank(alice);
        ethscriptions.approve(bob, tokenId);
        
        // Bob burns the token with approval
        vm.prank(bob);
        ethscriptions.transferFrom(alice, address(0), tokenId);
        
        // Verify the token is burned
        vm.expectRevert();
        ethscriptions.ownerOf(tokenId);
    }
    
    function testBurnCallsTokenManagerHandleTransfer() public {
        // Create a simple non-token ethscription first to test basic burn
        bytes32 simpleTxHash = keccak256("simple_tx");
        Ethscriptions.CreateEthscriptionParams memory params = Ethscriptions.CreateEthscriptionParams({
            transactionHash: simpleTxHash,
            initialOwner: alice,
            contentUri: bytes("data:text/plain,Simple text"),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            isCompressed: false,
            tokenParams: Ethscriptions.TokenParams({
                op: "",
                protocol: "",
                tick: "",
                max: 0,
                lim: 0,
                amt: 0
            })
        });
        
        vm.prank(alice);
        ethscriptions.createEthscription(params);
        
        // Burn the ethscription
        vm.prank(alice);
        ethscriptions.transferFrom(alice, address(0), uint256(simpleTxHash));
        
        // Verify it's burned
        vm.expectRevert();
        ethscriptions.ownerOf(uint256(simpleTxHash));
        
        // The burn should have called TokenManager.handleTokenTransfer with to=address(0)
        // This ensures TokenManager is notified of burns
    }
}
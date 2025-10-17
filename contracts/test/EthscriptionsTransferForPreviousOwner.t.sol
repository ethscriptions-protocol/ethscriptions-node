// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./TestSetup.sol";

contract EthscriptionsTransferForPreviousOwnerTest is TestSetup {
    Ethscriptions public eth;
    
    function setUp() public override {
        super.setUp();
        eth = ethscriptions;
    }
    
    function test_TransferForPreviousOwner() public {
        // Create an ethscription
        bytes32 txHash = bytes32(uint256(0x123));
        address creator = address(0x1);
        address initialOwner = address(0x2);
        address newOwner = address(0x3);
        address thirdOwner = address(0x4);
        
        vm.prank(creator);
        eth.createEthscription(
            createTestParams(
                txHash,
                initialOwner,
                "data:,test",
                false
            )
        );
        
        // Transfer from initial owner to new owner
        vm.prank(initialOwner);
        eth.transferEthscription(newOwner, txHash);
        
        // Verify previous owner is now initial owner
        Ethscriptions.Ethscription memory etsc = eth.getEthscription(txHash);
        assertEq(etsc.previousOwner, initialOwner);
        
        // Now transfer from new owner to third owner, validating previous owner
        vm.prank(newOwner);
        eth.transferEthscriptionForPreviousOwner(
            thirdOwner,
            txHash,
            initialOwner // Must match the previous owner
        );
        
        // Verify ownership and previous owner updated
        assertEq(eth.ownerOf(txHash), thirdOwner);
        etsc = eth.getEthscription(txHash);
        assertEq(etsc.previousOwner, newOwner);
        
        // Test that wrong previous owner fails
        vm.prank(thirdOwner);
        vm.expectRevert(Ethscriptions.PreviousOwnerMismatch.selector);
        eth.transferEthscriptionForPreviousOwner(
            address(0x5),
            txHash,
            address(0x999) // Wrong previous owner
        );
    }
}
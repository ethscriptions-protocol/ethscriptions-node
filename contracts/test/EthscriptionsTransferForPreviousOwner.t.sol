// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Ethscriptions.sol";

contract EthscriptionsTransferForPreviousOwnerTest is Test {
    Ethscriptions public eth;
    
    function setUp() public {
        eth = new Ethscriptions("Ethscriptions", "ETSC");
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
            Ethscriptions.CreateEthscriptionParams({
                transactionHash: txHash,
                initialOwner: initialOwner,
                contentUri: bytes("data:,test"),
                mimetype: "text/plain",
                mediaType: "text",
                mimeSubtype: "plain",
                esip6: false,
                tokenParams: Ethscriptions.TokenParams({
                    op: "",
                    protocol: "",
                    tick: "",
                    max: 0,
                    lim: 0,
                    amt: 0
                })
            })
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
        assertEq(eth.currentOwner(txHash), thirdOwner);
        etsc = eth.getEthscription(txHash);
        assertEq(etsc.previousOwner, newOwner);
        
        // Test that wrong previous owner fails
        vm.prank(thirdOwner);
        vm.expectRevert("Previous owner mismatch");
        eth.transferEthscriptionForPreviousOwner(
            address(0x5),
            txHash,
            address(0x999) // Wrong previous owner
        );
    }
    
    function test_TransferForPreviousOwnerGas() public {
        bytes32 txHash = bytes32(uint256(0x456));
        address creator = address(0x10);
        address owner1 = address(0x11);
        address owner2 = address(0x12);
        address owner3 = address(0x13);
        
        vm.prank(creator);
        eth.createEthscription(
            Ethscriptions.CreateEthscriptionParams({
                transactionHash: txHash,
                initialOwner: owner1,
                contentUri: bytes("data:,gas test"),
                mimetype: "text/plain",
                mediaType: "text",
                mimeSubtype: "plain",
                esip6: false,
                tokenParams: Ethscriptions.TokenParams({
                    op: "",
                    protocol: "",
                    tick: "",
                    max: 0,
                    lim: 0,
                    amt: 0
                })
            })
        );
        
        // First transfer (regular)
        vm.prank(owner1);
        eth.transferEthscription(owner2, txHash);
        
        // Second transfer with previous owner validation
        vm.prank(owner2);
        uint256 gasBefore = gasleft();
        eth.transferEthscriptionForPreviousOwner(owner3, txHash, owner1);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("transferEthscriptionForPreviousOwner gas:", gasUsed);
        
        // Should be slightly more than regular transfer due to extra validation
        assertGt(gasUsed, 25000);
        assertLt(gasUsed, 50000);
    }
}
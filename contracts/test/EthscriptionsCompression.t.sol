// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./TestSetup.sol";
import {LibZip} from "solady/src/utils/LibZip.sol";
import "forge-std/console.sol";

contract EthscriptionsCompressionTest is TestSetup {
    using LibZip for bytes;
    
    function testCompressedEthscriptionCreation() public {
        // Load the actual example ethscription content
        string memory json = vm.readFile("test/example_ethscription.json");
        bytes memory originalContent = bytes(vm.parseJsonString(json, ".result.content_uri"));
        
        console.log("Original content size:", originalContent.length);
        
        // Compress off-chain (simulating what the indexer would do)
        bytes memory compressedContent = LibZip.flzCompress(originalContent);
        console.log("Compressed content size:", compressedContent.length);
        console.log("Compression ratio:", (compressedContent.length * 100) / originalContent.length, "%");
        
        // Create ethscription with compressed content
        bytes32 txHash = bytes32(uint256(0xC0113E55));
        address owner = address(0x1337);
        
        vm.prank(owner);
        uint256 tokenId = ethscriptions.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: txHash,
            initialOwner: owner,
            contentUri: compressedContent,
            mimetype: "image/png",
            mediaType: "image",
            mimeSubtype: "png",
            esip6: false,
            isCompressed: true,  // Flag indicating content is compressed
            tokenParams: Ethscriptions.TokenParams({
                op: "",
                protocol: "",
                tick: "",
                max: 0,
                lim: 0,
                amt: 0
            })
        }));
        
        // Verify the ethscription was created
        assertEq(tokenId, uint256(txHash));
        assertEq(ethscriptions.ownerOf(tokenId), owner);
        
        // Get tokenURI - should automatically decompress
        string memory tokenURI = ethscriptions.tokenURI(tokenId);
        
        // Verify decompressed content matches original
        assertEq(bytes(tokenURI), originalContent, "Decompressed content should match original");
        
        console.log("Successfully created and retrieved compressed ethscription!");
    }
    
    function testUncompressedEthscriptionCreation() public {
        // Test regular uncompressed creation still works
        bytes memory content = bytes("data:,Hello World!");
        bytes32 txHash = bytes32(uint256(0x00C0113E));
        address owner = address(0xBEEF);
        
        vm.prank(owner);
        uint256 tokenId = ethscriptions.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: txHash,
            initialOwner: owner,
            contentUri: content,
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            isCompressed: false,  // Not compressed
            tokenParams: Ethscriptions.TokenParams({
                op: "",
                protocol: "",
                tick: "",
                max: 0,
                lim: 0,
                amt: 0
            })
        }));
        
        // Verify
        string memory tokenURI = ethscriptions.tokenURI(tokenId);
        assertEq(bytes(tokenURI), content, "Uncompressed content should be unchanged");
    }
    
    // function testCompressionGasSavings() public {
    //     // Load example content
    //     string memory json = vm.readFile("test/example_ethscription.json");
    //     bytes memory originalContent = bytes(vm.parseJsonString(json, ".result.content_uri"));
    //     bytes memory compressedContent = LibZip.flzCompress(originalContent);
        
    //     address owner = address(0x6A5);
        
    //     // Measure gas for uncompressed creation
    //     vm.prank(owner);
    //     uint256 gasStart = gasleft();
    //     ethscriptions.createEthscription(Ethscriptions.CreateEthscriptionParams({
    //         transactionHash: bytes32(uint256(0x1111)),
    //         initialOwner: owner,
    //         contentUri: originalContent,
    //         mimetype: "image/png",
    //         mediaType: "image",
    //         mimeSubtype: "png",
    //         esip6: false,
    //         isCompressed: false,
    //         tokenParams: Ethscriptions.TokenParams({
    //             op: "", protocol: "", tick: "", max: 0, lim: 0, amt: 0
    //         })
    //     }));
    //     uint256 uncompressedGas = gasStart - gasleft();
        
    //     // Measure gas for compressed creation
    //     vm.prank(owner);
    //     gasStart = gasleft();
    //     ethscriptions.createEthscription(Ethscriptions.CreateEthscriptionParams({
    //         transactionHash: bytes32(uint256(0x2222)),
    //         initialOwner: owner,
    //         contentUri: compressedContent,
    //         mimetype: "image/png",
    //         mediaType: "image",
    //         mimeSubtype: "png",
    //         esip6: false,
    //         isCompressed: true,
    //         tokenParams: Ethscriptions.TokenParams({
    //             op: "", protocol: "", tick: "", max: 0, lim: 0, amt: 0
    //         })
    //     }));
    //     uint256 compressedGas = gasStart - gasleft();
        
    //     console.log("Uncompressed creation gas:", uncompressedGas);
    //     console.log("Compressed creation gas:", compressedGas);
        
    //     if (compressedGas < uncompressedGas) {
    //         uint256 gasSaved = uncompressedGas - compressedGas;
    //         console.log("Gas saved:", gasSaved);
    //         console.log("Savings percentage:", (gasSaved * 100) / uncompressedGas, "%");
    //     } else {
    //         uint256 extraGas = compressedGas - uncompressedGas;
    //         console.log("Extra gas for compression:", extraGas);
    //     }
    // }
}
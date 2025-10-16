// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./TestSetup.sol";
import {Base64} from "solady/utils/Base64.sol";

contract DataURIEdgeCaseTest is TestSetup {
    address creator = address(0x1234);

    function testDataURIAsContentTokenURI() public {
        // The content is literally a data URI string
        string memory dataURIContent = "data:EthscriptionsApe3332;image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAFAAAABQAQMAAAC032DuAAAABlBMVEXWtYs0MlAmBrhqAAABEklEQVQoz+3SP0vDUBAA8EszJINgJsGpq26ZxK1fwcW9bo7FyUGaFkEHQQTX0tXRjiKiLRV0c3QQbIKuJYOir/QlJ3p/XoZ+BN/04zi4u3cHqA/+WeHXgzI9Fs4+ZsI3TITfL8/Ciae5JXjMZQswJwZmd3NE9FuDrfs/lt2d2lGXovAerZwz03gjI4ZZHI+JUQrAuWettXWfc23NC4id9vXnBXFc9PdybsdkJ9LZfDjS2TqHShg6Nt0Uyj40E+ap46PjFUQNqeZ4A1Fdo9BYxFBYICZaeH/BArAI3LJ84R3KV+Nrqbx0xAp7oFxyXBVaHAD3YBMjNO1im3lg3ZWY6u3kxAni7ZT4hPUeX0le+uEvfwAZzbx2rozFmgAAAABJRU5ErkJggg==";

        // Create an ethscription with this content as a data URI (text/plain with base64 encoded content)
        bytes32 txHash = keccak256(abi.encodePacked("test_datauri_edge_case"));

        // Create params with the data URI content
        // The content itself is a data URI string, stored as text/plain
        Ethscriptions.CreateEthscriptionParams memory params = createTestParams(
            txHash,
            creator,
            string(abi.encodePacked("data:text/plain;base64,", Base64.encode(bytes(dataURIContent)))),
            false
        );

        // Create the ethscription
        vm.prank(creator);
        uint256 tokenId = ethscriptions.createEthscription(params);

        // Get the tokenURI
        string memory tokenURI = ethscriptions.tokenURI(tokenId);

        console.log("\n=== DATA URI EDGE CASE TEST ===\n");
        console.log("Original content (a data URI string):");
        console.log(dataURIContent);
        console.log("\nThis content is stored as text/plain in the ethscription.");
        console.log("\nGenerated tokenURI (paste this into your browser):\n");
        console.log(tokenURI);
        console.log("\n=== EXPECTED BEHAVIOR ===");
        console.log("The viewer should display the full data URI string as text.");
        console.log("You should NOT see an image, but rather the data URI text itself.");
        console.log("\n=============================\n");
    }

    function testBinaryPNGTokenURI() public {
        // Create actual binary PNG content (tiny 1x1 pixel PNG)
        bytes memory pngBytes = hex"89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c636080000000050001d507211200000000";

        bytes32 txHash = keccak256(abi.encodePacked("test_binary_png"));

        // Create params with binary PNG data as base64 data URI
        Ethscriptions.CreateEthscriptionParams memory params = createTestParams(
            txHash,
            creator,
            string(abi.encodePacked("data:image/png;base64,", Base64.encode(pngBytes))),
            false
        );

        // Create the ethscription
        vm.prank(creator);
        uint256 tokenId = ethscriptions.createEthscription(params);

        // Get the tokenURI
        string memory tokenURI = ethscriptions.tokenURI(tokenId);

        console.log("\n=== BINARY PNG TEST ===\n");
        console.log("Binary PNG data stored with mimetype: image/png");
        console.log("\nGenerated tokenURI (paste this into your browser):\n");
        console.log(tokenURI);
        console.log("\n=== EXPECTED BEHAVIOR ===");
        console.log("The viewer should display a data URI starting with 'data:image/png;base64,...'");
        console.log("This is because binary content cannot be decoded as UTF-8.");
        console.log("\n=============================\n");
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./TestSetup.sol";
import "forge-std/StdJson.sol";

contract EthscriptionsJsonTest is TestSetup {
    using stdJson for string;

    Ethscriptions internal eth;

    function setUp() public override {
        super.setUp();
        eth = ethscriptions;
    }

    function test_CreateAndTokenURIGas_FromJson() public {
        vm.pauseGasMetering();
        (
            bytes32 txHash,
            address creator,
            address initialOwner,
            ,
            string memory contentUri,
            , // l1BlockNumber - no longer used
            , // l1BlockTimestamp - no longer used
            , // l1BlockHash - no longer used
            , // transactionIndex - no longer used
            string memory mimetype,
            string memory mediaType,
            string memory mimeSubtype
        ) = _read();
        
        // Note: l1BlockNumber, l1BlockTimestamp, l1BlockHash, transactionIndex are read but no longer used

        Ethscriptions.CreateEthscriptionParams memory params = Ethscriptions.CreateEthscriptionParams({
            transactionHash: txHash,
            initialOwner: initialOwner,
            contentUri: bytes(contentUri),
            mimetype: mimetype,
            mediaType: mediaType,
            mimeSubtype: mimeSubtype,
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

        vm.startPrank(creator);
        uint256 g0 = gasleft();
        vm.resumeGasMetering();
        uint256 tokenId = eth.createEthscription(params);
        vm.pauseGasMetering();
        uint256 createGas = g0 - gasleft();
        vm.stopPrank();

        emit log_named_uint("createEthscription gas", createGas);

        // State checks (not metered)
        assertEq(eth.ownerOf(tokenId), initialOwner, "owner mismatch");

        // tokenURI gas
        g0 = gasleft();
        vm.resumeGasMetering();
        string memory got = eth.tokenURI(tokenId);
        vm.pauseGasMetering();
        uint256 uriGas = g0 - gasleft();
        emit log_named_uint("tokenURI gas", uriGas);

        // Validate JSON metadata format
        assertTrue(startsWith(got, "data:application/json;base64,"), "Should return base64-encoded JSON");

        // Decode and validate JSON contains expected fields
        bytes memory base64Part = bytes(substring(got, 29, bytes(got).length));
        bytes memory decodedJson = Base64.decode(string(base64Part));
        string memory json = string(decodedJson);

        // Check JSON contains the actual content in the image field
        // The contentUri from the JSON file starts with data:image/png;base64,
        assertTrue(contains(json, '"image":"data:image/png;base64,'), "JSON should contain PNG image data");
        assertTrue(contains(json, '"name":"Ethscription #11"'), "Should have correct name");
        assertTrue(contains(json, '"attributes":['), "Should have attributes array");
    }

    function _read()
        internal
        view
        returns (
            bytes32 txHash,
            address creator,
            address initialOwner,
            address currentOwner,
            string memory contentUri,
            uint256, // l1BlockNumber - no longer used
            uint256, // l1BlockTimestamp - no longer used
            bytes32, // l1BlockHash - no longer used
            uint256, // transactionIndex - no longer used
            string memory mimetype,
            string memory mediaType,
            string memory mimeSubtype
        )
    {
        // Update the filename here if you add a different fixture
        string memory path = string.concat(vm.projectRoot(), "/test/example_ethscription.json");
        string memory json = vm.readFile(path);

        txHash = json.readBytes32(".result.transaction_hash");
        creator = json.readAddress(".result.creator");
        initialOwner = json.readAddress(".result.initial_owner");
        currentOwner = json.readAddress(".result.current_owner");
        contentUri = json.readString(".result.content_uri");
        // L1 data no longer used, but still read to maintain compatibility
        // l1BlockNumber = vm.parseUint(json.readString(".result.block_number"));
        // l1BlockTimestamp = vm.parseUint(json.readString(".result.block_timestamp"));
        // l1BlockHash = json.readBytes32(".result.block_blockhash");
        // transactionIndex = vm.parseUint(json.readString(".result.transaction_index"));
        mimetype = json.readString(".result.mimetype");
        mediaType = json.readString(".result.media_type");
        mimeSubtype = json.readString(".result.mime_subtype");
    }

    function test_TransferFromJson() public {
        vm.pauseGasMetering();
        (
            bytes32 txHash,
            address creator,
            address initialOwner,
            address currentOwner,
            string memory contentUri,
            , // l1BlockNumber - no longer used
            , // l1BlockTimestamp - no longer used
            , // l1BlockHash - no longer used
            , // transactionIndex - no longer used
            string memory mimetype,
            string memory mediaType,
            string memory mimeSubtype
        ) = _read();
        
        // Note: l1BlockNumber, l1BlockTimestamp, l1BlockHash, transactionIndex are read but no longer used

        Ethscriptions.CreateEthscriptionParams memory params = Ethscriptions.CreateEthscriptionParams({
            transactionHash: txHash,
            initialOwner: initialOwner,
            contentUri: bytes(contentUri),
            mimetype: mimetype,
            mediaType: mediaType,
            mimeSubtype: mimeSubtype,
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

        // Create ethscription
        vm.startPrank(creator);
        uint256 tokenId = eth.createEthscription(params);
        vm.stopPrank();
        
        // Transfer from initialOwner to currentOwner
        vm.startPrank(initialOwner);
        vm.resumeGasMetering();
        uint256 g0 = gasleft();
        eth.transferEthscription(currentOwner, txHash);
        uint256 transferGas = g0 - gasleft();
        vm.pauseGasMetering();
        vm.stopPrank();
        
        emit log_named_uint("transferEthscription gas", transferGas);
        
        // Verify ownership changed
        assertEq(eth.ownerOf(tokenId), currentOwner, "Owner should be currentOwner");
        
        // Verify previous owner tracking
        Ethscriptions.Ethscription memory e = eth.getEthscription(txHash);
        assertEq(e.previousOwner, initialOwner, "Previous owner should be tracked");
        
        // Verify content is still readable via JSON metadata
        string memory retrievedUri = eth.tokenURI(tokenId);

        // Decode JSON and verify content is preserved
        assertTrue(startsWith(retrievedUri, "data:application/json;base64,"), "Should return base64-encoded JSON");
        bytes memory base64Part = bytes(substring(retrievedUri, 29, bytes(retrievedUri).length));
        bytes memory decodedJson = Base64.decode(string(base64Part));
        string memory json = string(decodedJson);
        assertTrue(contains(json, '"image":"data:image/png;base64,'), "Content should be unchanged after transfer");
    }
    
    function test_ReadChunk() public {
        // Create a multi-chunk ethscription
        bytes memory largeContent = new bytes(50000); // ~2 chunks
        for (uint i = 0; i < largeContent.length; i++) {
            largeContent[i] = bytes1(uint8(65 + (i % 26)));
        }
        bytes memory contentUri = abi.encodePacked("data:text/plain;base64,", largeContent);
        
        bytes32 txHash = bytes32(uint256(999));
        address creator = address(0xBEEF);
        address initialOwner = address(0xCAFE);
        
        Ethscriptions.CreateEthscriptionParams memory params = Ethscriptions.CreateEthscriptionParams({
            transactionHash: txHash,
            initialOwner: initialOwner,
            contentUri: bytes(contentUri),
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
        
        vm.prank(creator);
        eth.createEthscription(params);
        
        // Test readChunk
        uint256 pointerCount = eth.getContentPointerCount(txHash);
        assertEq(pointerCount, 3, "Should have 3 chunks"); // 50023 bytes total = 3 chunks
        
        // Read first chunk
        bytes memory chunk0 = eth.readChunk(txHash, 0);
        assertEq(chunk0.length, 24575, "First chunk should be full size");
        
        // Read last chunk  
        bytes memory chunk2 = eth.readChunk(txHash, 2);
        uint256 totalLength = contentUri.length;
        uint256 expectedLastChunkSize = totalLength - (24575 * 2);
        assertEq(chunk2.length, expectedLastChunkSize, "Last chunk should be remainder");
        
        // Verify content matches when reassembled from chunks
        bytes memory reconstructed;
        for (uint256 i = 0; i < pointerCount; i++) {
            reconstructed = abi.encodePacked(reconstructed, eth.readChunk(txHash, i));
        }
        assertEq(reconstructed, contentUri, "Reconstructed chunks should match original");

        // Also verify tokenURI returns valid JSON
        string memory tokenUri = eth.tokenURI(eth.getTokenId(txHash));
        assertTrue(startsWith(tokenUri, "data:application/json;base64,"), "Should return JSON metadata");
    }
    
    function test_ExactChunkBoundary() public {
        // Test with content that exactly fills 2 chunks when including prefix
        bytes memory prefix = "data:application/octet-stream;base64,";
        uint256 targetChunks = 2;
        uint256 exactSize = (24575 * targetChunks) - prefix.length;
        bytes memory content = new bytes(exactSize);
        
        // Fill with a pattern that we can verify
        for (uint256 i = 0; i < exactSize; i++) {
            content[i] = bytes1(uint8(i % 256));
        }
        
        bytes memory contentUri = abi.encodePacked(prefix, content);
        assertEq(contentUri.length, 24575 * 2, "Total should be exactly 2 chunks");
        
        bytes32 txHash = bytes32(uint256(0xEEEE));
        vm.prank(address(0xAAAA));
        uint256 tokenId = eth.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: txHash,
            initialOwner: address(0xBBBB),
            contentUri: contentUri,
            mimetype: "application/octet-stream",
            mediaType: "application",
            mimeSubtype: "octet-stream",
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
        }));
        
        // Verify we have exactly 2 chunks
        assertEq(eth.getContentPointerCount(txHash), targetChunks, "Should have exactly 2 chunks");
        
        // Read back and verify in JSON metadata
        string memory retrieved = eth.tokenURI(tokenId);
        assertTrue(startsWith(retrieved, "data:application/json;base64,"), "Should return JSON metadata");

        // Decode JSON and verify it contains our content
        bytes memory base64Part = bytes(substring(retrieved, 29, bytes(retrieved).length));
        bytes memory decodedJson = Base64.decode(string(base64Part));
        string memory json = string(decodedJson);

        // The JSON should contain our exact content URI in the image field
        assertTrue(contains(json, '"image":"data:application/octet-stream;base64,'), "JSON should have correct content prefix");
        assertTrue(bytes(json).length > contentUri.length, "JSON should be larger than raw content");
    }
    
    function test_NonAlignedChunkSize() public {
        // Test with size that doesn't align to chunk boundaries (30000 bytes = 1.22 chunks)
        uint256 oddSize = 30000;
        bytes memory content = new bytes(oddSize);
        
        // Fill with a different pattern - use prime number for more irregularity
        for (uint256 i = 0; i < oddSize; i++) {
            content[i] = bytes1(uint8((i * 17 + 23) % 256));
        }
        
        bytes memory contentUri = abi.encodePacked("data:text/plain;base64,", content);
        
        bytes32 txHash = bytes32(uint256(0xDDDD));
        vm.prank(address(0xCCCC));
        uint256 tokenId = eth.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: txHash,
            initialOwner: address(0xEEEE),
            contentUri: contentUri,
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
        }));
        
        // Verify we have 2 chunks (24575 + 5450 bytes)
        assertEq(eth.getContentPointerCount(txHash), 2, "Should have 2 chunks");
        
        // Verify second chunk has correct size
        bytes memory secondChunk = eth.readChunk(txHash, 1);
        uint256 expectedSecondChunkSize = contentUri.length - 24575;
        assertEq(secondChunk.length, expectedSecondChunkSize, "Second chunk size mismatch");
        
        // Read back and verify in JSON metadata
        string memory retrieved = eth.tokenURI(tokenId);
        assertTrue(startsWith(retrieved, "data:application/json;base64,"), "Should return JSON metadata");

        // Decode JSON and verify content is preserved
        bytes memory base64Part = bytes(substring(retrieved, 29, bytes(retrieved).length));
        bytes memory decodedJson = Base64.decode(string(base64Part));
        string memory json = string(decodedJson);

        // Verify the JSON contains our content
        assertTrue(contains(json, '"image":"data:text/plain;base64,'), "JSON should contain content in image field");
        assertTrue(bytes(json).length > contentUri.length, "JSON should be larger than raw content");
    }
    
    function test_SingleByteContent() public {
        // Edge case: single byte
        bytes memory contentUri = hex"42"; // Single byte: 'B'
        
        bytes32 txHash = bytes32(uint256(0x9999));
        vm.prank(address(0x7777));
        uint256 tokenId = eth.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: txHash,
            initialOwner: address(0x8888),
            contentUri: contentUri,
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
        }));
        
        // Verify single chunk
        assertEq(eth.getContentPointerCount(txHash), 1, "Should have 1 chunk");
        
        // Verify content in JSON metadata
        string memory retrieved = eth.tokenURI(tokenId);
        assertTrue(startsWith(retrieved, "data:application/json;base64,"), "Should return JSON metadata");

        // Decode JSON and verify single byte content
        bytes memory base64Part = bytes(substring(retrieved, 29, bytes(retrieved).length));
        bytes memory decodedJson = Base64.decode(string(base64Part));
        string memory json = string(decodedJson);

        // Check the image field contains our single byte (0x42 = 'B')
        assertTrue(contains(json, '"image":"B"'), "JSON should contain single byte content 'B'");
    }
    
    function test_EmptyStringBoundaryCase() public {
        // Edge case: empty content should revert
        bytes memory contentUri = "";
        
        bytes32 txHash = bytes32(uint256(0x5555));
        vm.prank(address(0x4444));
        vm.expectRevert(Ethscriptions.EmptyContentUri.selector);
        eth.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: txHash,
            initialOwner: address(0x3333),
            contentUri: contentUri,
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
        }));
    }
    
    function test_ESIP6_ContentDeduplication() public {
        bytes memory contentUri = hex"48656c6c6f20576f726c64"; // "Hello World"
        
        // First ethscription - should store content
        bytes32 txHash1 = bytes32(uint256(0xAAA1));
        vm.prank(address(0x1111));
        eth.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: txHash1,
            initialOwner: address(0x2222),
            contentUri: contentUri,
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
        }));
        
        // Second ethscription with same content, no ESIP6 - should fail
        bytes32 txHash2 = bytes32(uint256(0xAAA2));
        vm.prank(address(0x3333));
        vm.expectRevert(Ethscriptions.DuplicateContent.selector);
        eth.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: txHash2,
            initialOwner: address(0x4444),
            contentUri: contentUri,
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
        }));
        
        // Third ethscription with same content, ESIP6 enabled - should succeed and reuse pointers
        bytes32 txHash3 = bytes32(uint256(0xAAA3));
        vm.prank(address(0x5555));
        uint256 gasBeforeEsip6 = gasleft();
        eth.createEthscription(Ethscriptions.CreateEthscriptionParams({
            transactionHash: txHash3,
            initialOwner: address(0x6666),
            contentUri: contentUri,
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: true,
            isCompressed: false,
            tokenParams: Ethscriptions.TokenParams({
                op: "",
                protocol: "",
                tick: "",
                max: 0,
                lim: 0,
                amt: 0
            })
        }));
        uint256 esip6Gas = gasBeforeEsip6 - gasleft();
        
        // Verify both ethscriptions return JSON with same content
        string memory uri1 = eth.tokenURI(eth.getTokenId(txHash1));
        string memory uri3 = eth.tokenURI(eth.getTokenId(txHash3));

        // Both should be JSON
        assertTrue(startsWith(uri1, "data:application/json;base64,"), "Should return JSON");
        assertTrue(startsWith(uri3, "data:application/json;base64,"), "Should return JSON");

        // Decode and verify both contain same content
        bytes memory json1 = Base64.decode(string(bytes(substring(uri1, 29, bytes(uri1).length))));
        bytes memory json3 = Base64.decode(string(bytes(substring(uri3, 29, bytes(uri3).length))));

        // Both should contain the same content in image field
        assertTrue(contains(string(json1), '"image":"Hello World"'), "JSON1 should contain content");
        assertTrue(contains(string(json3), '"image":"Hello World"'), "JSON3 should contain content");

        // Verify they have different ethscription numbers but same content
        assertTrue(contains(string(json1), '"name":"Ethscription #11"'), "JSON1 should be #11");
        assertTrue(contains(string(json3), '"name":"Ethscription #12"'), "JSON3 should be #12 with ESIP-6");
        
        // Verify gas savings from content reuse
        console.log("ESIP6 creation gas (reusing content):", esip6Gas);
        assertTrue(esip6Gas < 1000000, "ESIP6 should save gas by reusing content");
        
        // Verify both have same pointer count
        assertEq(eth.getContentPointerCount(txHash1), eth.getContentPointerCount(txHash3), "Should have same pointer count");
    }
    
    function test_WorstCaseGas_1MB() public {
        vm.pauseGasMetering();
        
        // Create 1MB content URI (1,048,576 bytes)
        bytes memory largeContent = new bytes(1048576);
        for (uint i = 0; i < largeContent.length; i++) {
            largeContent[i] = bytes1(uint8(65 + (i % 26))); // Fill with A-Z pattern
        }
        bytes memory contentUri = abi.encodePacked("data:text/plain;base64,", largeContent);
        
        bytes32 txHash = bytes32(uint256(1));
        address creator = address(0x1234);
        address initialOwner = address(0x5678);
        
        Ethscriptions.CreateEthscriptionParams memory params = Ethscriptions.CreateEthscriptionParams({
            transactionHash: txHash,
            initialOwner: initialOwner,
            contentUri: bytes(contentUri),
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
        
        vm.startPrank(creator);
        uint256 g0 = gasleft();
        vm.resumeGasMetering();
        uint256 tokenId = eth.createEthscription(params);
        vm.pauseGasMetering();
        uint256 createGas = g0 - gasleft();
        vm.stopPrank();
        
        emit log_named_uint("1MB createEthscription gas", createGas);
        emit log_named_uint("1MB content size (bytes)", contentUri.length);
        
        // tokenURI gas
        g0 = gasleft();
        vm.resumeGasMetering();
        string memory got = eth.tokenURI(tokenId);
        vm.pauseGasMetering();
        uint256 uriGas = g0 - gasleft();
        emit log_named_uint("1MB tokenURI gas", uriGas);
        
        // Verify it stored correctly as JSON
        assertTrue(startsWith(got, "data:application/json;base64,"), "Should return JSON metadata");
        assertEq(eth.ownerOf(tokenId), initialOwner);

        // Decode and verify large content is in the JSON
        bytes memory base64Part = bytes(substring(got, 29, bytes(got).length));
        bytes memory decodedJson = Base64.decode(string(base64Part));
        string memory json = string(decodedJson);
        assertTrue(contains(json, '"image":"data:text/plain;base64,'), "JSON should contain base64 content");
    }

    // Helper functions for JSON validation
    function startsWith(string memory str, string memory prefix) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory prefixBytes = bytes(prefix);

        if (prefixBytes.length > strBytes.length) return false;

        for (uint256 i = 0; i < prefixBytes.length; i++) {
            if (strBytes[i] != prefixBytes[i]) return false;
        }
        return true;
    }

    function contains(string memory str, string memory substr) internal pure returns (bool) {
        bytes memory strBytes = bytes(str);
        bytes memory substrBytes = bytes(substr);

        if (substrBytes.length > strBytes.length) return false;

        for (uint256 i = 0; i <= strBytes.length - substrBytes.length; i++) {
            bool found = true;
            for (uint256 j = 0; j < substrBytes.length; j++) {
                if (strBytes[i + j] != substrBytes[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    function substring(string memory str, uint256 start, uint256 end) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory result = new bytes(end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = strBytes[i];
        }
        return string(result);
    }
}

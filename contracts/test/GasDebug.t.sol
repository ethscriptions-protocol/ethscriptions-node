// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import "../src/Ethscriptions.sol";
import "../script/L2Genesis.s.sol";

contract GasDebugTest is Test {
    Ethscriptions public ethscriptions;
    address constant INITIAL_OWNER = 0xC2172a6315c1D7f6855768F843c420EbB36eDa97;

    function setUp() public {
        // Run the genesis setup without dumping to file
        L2Genesis genesis = new L2Genesis();
        genesis.runWithoutDump();

        // Get the deployed Ethscriptions contract
        ethscriptions = Ethscriptions(0x3300000000000000000000000000000000000001);

        // Check if it's deployed
        require(address(ethscriptions).code.length > 0, "Ethscriptions contract not deployed");
    }

    function testExactMainnetInput() public {
        // Set up the exact input from mainnet block 17478950
        Ethscriptions.CreateEthscriptionParams memory params = Ethscriptions.CreateEthscriptionParams({
            transactionHash: 0x05aac415994e0e01e66c4970133a51a4cdcea1f3a967743b87e6eb08f2f4d9f9,
            initialOwner: INITIAL_OWNER,
            contentUri: bytes("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAAm0lEQVR42mNgGITgPxTTxvBleTo0swBsOK0s+N8aJkczC1AMR7KAKpb8v72xAY5hFsD4lFoCN+j56ZUoliAbSoklGIZjwxRbQAjT1YK7d+82kGUBeuQiiJ1rAYYrL81NwCpGFQtoEUT/6RoHWAyknQV0S6ZI5RE6Jt8CZIOOH TuGgR9Fq5FkCf19QM3wx5rZKHEtsRZQtJqkhgUARpCGaUehOD4AAAAAElFTkSuQmCC"),
            mimetype: "image/png",
            mediaType: "image",
            mimeSubtype: "png",
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

        // Prank as the creator address
        vm.prank(INITIAL_OWNER);

        // Measure gas before
        uint256 gasBefore = gasleft();
        console.log("Gas before createEthscription:", gasBefore);

        // Try to create the ethscription
        try ethscriptions.createEthscription(params) returns (uint256 tokenId) {
            uint256 gasAfter = gasleft();
            uint256 gasUsed = gasBefore - gasAfter;
            console.log("Gas after createEthscription:", gasAfter);
            console.log("Gas used:", gasUsed);
            console.log("Token ID created:", tokenId);

            // Verify it was created
            Ethscriptions.Ethscription memory etsc = ethscriptions.getEthscription(params.transactionHash);
            assertEq(etsc.creator, INITIAL_OWNER);
            assertEq(etsc.initialOwner, INITIAL_OWNER);
            assertEq(etsc.mimetype, "image/png");
        } catch Error(string memory reason) {
            console.log("Failed with reason:", reason);
            revert(reason);
        } catch (bytes memory lowLevelData) {
            console.log("Failed with low-level error");
            console.logBytes(lowLevelData);
            revert("Low-level error");
        }
    }

    function testStoreContentDirectly() public {
        // Test _storeContent in isolation by creating a minimal wrapper
        // First deploy a test contract that exposes _storeContent
        StoreContentTester tester = new StoreContentTester();

        bytes memory contentUri = bytes("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAYAAADgdz34AAAAm0lEQVR42mNgGITgPxTTxvBleTo0swBsOK0s+N8aJkczC1AMR7KAKpb8v72xAY5hFsD4lFoCN+j56ZUoliAbSoklGIZjwxRbQAjT1YK7d+82kGUBeuQiiJ1rAYYrL81NwCpGFQtoEUT/6RoHWAyknQV0S6ZI5RE6Jt8CZIOOH TuGgR9Fq5FkCf19QM3wx5rZKHEtsRZQtJqkhgUARpCGaUehOD4AAAAAElFTkSuQmCC");

        console.log("Content URI length:", contentUri.length);

        uint256 gasBefore = gasleft();
        bytes32 contentSha = tester.storeContentHelper(contentUri, false, false);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for _storeContent:", gasUsed);
        console.log("Content SHA:", uint256(contentSha));
    }

    // Add bounded test for fuzzing
    function testStoreContentBounded(bytes calldata contentUri) public {
        // Limit input size to avoid OOG in tests
        vm.assume(contentUri.length > 0 && contentUri.length <= 1000);

        StoreContentTester tester = new StoreContentTester();

        // Only test uncompressed content to avoid decompression gas costs
        tester.storeContentHelper(contentUri, false, false);
    }
}

// Helper contract to test _storeContent directly
contract StoreContentTester is Ethscriptions {
    // Not prefixed with 'test' to avoid fuzzing
    function storeContentHelper(
        bytes calldata contentUri,
        bool isCompressed,
        bool esip6
    ) external returns (bytes32) {
        return _storeContent(contentUri, isCompressed, esip6);
    }
}
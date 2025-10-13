// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./TestSetup.sol";
import "forge-std/console.sol";

contract EthscriptionsTokenParamsTest is TestSetup {

    function testCreateWithTokenDeployParams() public {
        // Create a token deploy ethscription
        string memory tokenJson = '{"p":"erc-20","op":"deploy","tick":"eths","max":"21000000","lim":"1000"}';
        string memory dataUri = string.concat("data:,", tokenJson);
        bytes32 contentUriHash = sha256(bytes(dataUri));

        TokenManager.DeployOperation memory deployOp = TokenManager.DeployOperation({
            tick: "eths",
            maxSupply: 21000000,
            mintAmount: 1000
        });

        Ethscriptions.CreateEthscriptionParams memory params = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(1)),
            contentUriHash: contentUriHash,
            initialOwner: address(this),
            content: bytes(tokenJson),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "erc-20",
                operation: "deploy",
                data: abi.encode(deployOp)
            })
        });

        // Create the ethscription
        ethscriptions.createEthscription(params);

        // Verify it was created
        assertEq(ethscriptions.totalSupply(), 12, "Should have created new ethscription");

        // Get the ethscription data
        Ethscriptions.Ethscription memory eth = ethscriptions.getEthscription(params.transactionHash);
        assertEq(eth.creator, address(this), "Creator should match");
        assertEq(eth.initialOwner, address(this), "Initial owner should match");
    }

    function testCreateWithTokenMintParams() public {
        // Create a token mint ethscription
        string memory tokenJson = '{"p":"erc-20","op":"mint","tick":"eths","id":"1","amt":"1000"}';
        string memory dataUri = string.concat("data:,", tokenJson);
        bytes32 contentUriHash = sha256(bytes(dataUri));

        TokenManager.MintOperation memory mintOp = TokenManager.MintOperation({
            tick: "eths",
            id: 1,
            amount: 1000
        });

        Ethscriptions.CreateEthscriptionParams memory params = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(2)),
            contentUriHash: contentUriHash,
            initialOwner: address(this),
            content: bytes(tokenJson),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "erc-20",
                operation: "mint",
                data: abi.encode(mintOp)
            })
        });

        // Create the ethscription
        ethscriptions.createEthscription(params);

        // Verify it was created
        assertEq(ethscriptions.totalSupply(), 12, "Should have created new ethscription");
    }

    function testCreateWithoutTokenParams() public {
        // Create a regular non-token ethscription
        string memory content = "Hello, World!";
        string memory dataUri = string.concat("data:,", content);
        bytes32 contentUriHash = sha256(bytes(dataUri));

        Ethscriptions.CreateEthscriptionParams memory params = Ethscriptions.CreateEthscriptionParams({
            transactionHash: bytes32(uint256(3)),
            contentUriHash: contentUriHash,
            initialOwner: address(this),
            content: bytes(content),
            mimetype: "text/plain",
            mediaType: "text",
            mimeSubtype: "plain",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "",
                operation: "",
                data: ""
            })
        });

        // Create the ethscription
        ethscriptions.createEthscription(params);

        // Verify it was created
        assertEq(ethscriptions.totalSupply(), 12, "Should have created new ethscription");
    }

    function testTokenManagerIntegration() public {
        // First create a deploy operation
        string memory deployJson = '{"p":"erc-20","op":"deploy","tick":"test","max":"1000000","lim":"100"}';
        string memory deployUri = string.concat("data:,", deployJson);


        TokenManager.DeployOperation memory deployOp = TokenManager.DeployOperation({
            tick: "test",
            maxSupply: 1000000,
            mintAmount: 100
        });

        Ethscriptions.CreateEthscriptionParams memory deployParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: keccak256("deploy_tx"),
            contentUriHash: sha256(bytes(deployUri)),
            initialOwner: address(this),
            content: bytes(deployJson),
            mimetype: "application/json",
            mediaType: "application",
            mimeSubtype: "json",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "erc-20",
                operation: "deploy",
                data: abi.encode(deployOp)
            })
        });

        ethscriptions.createEthscription(deployParams);

        // Then create a mint operation
        string memory mintJson = '{"p":"erc-20","op":"mint","tick":"test","id":"1","amt":"100"}';
        string memory mintUri = string.concat("data:,", mintJson);

        TokenManager.MintOperation memory mintOp = TokenManager.MintOperation({
            tick: "test",
            id: 1,
            amount: 100
        });

        Ethscriptions.CreateEthscriptionParams memory mintParams = Ethscriptions.CreateEthscriptionParams({
            transactionHash: keccak256("mint_tx"),
            contentUriHash: sha256(bytes(mintUri)),
            initialOwner: address(this),
            content: bytes(mintJson),
            mimetype: "application/json",
            mediaType: "application",
            mimeSubtype: "json",
            esip6: false,
            protocolParams: Ethscriptions.ProtocolParams({
                protocol: "erc-20",
                operation: "mint",
                data: abi.encode(mintOp)
            })
        });

        ethscriptions.createEthscription(mintParams);

        // Verify both were created
        assertEq(ethscriptions.totalSupply(), 13, "Should have 13 total (11 genesis + 2 new)");
    }
}
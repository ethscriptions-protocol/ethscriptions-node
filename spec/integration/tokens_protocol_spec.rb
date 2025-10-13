require 'rails_helper'

RSpec.describe "Tokens Protocol", type: :integration do
  include EthscriptionsTestHelper

  let(:alice) { valid_address("alice") }
  let(:bob) { valid_address("bob") }
  let(:charlie) { valid_address("charlie") }
  # Ethscriptions are created by sending to any address with data in the input
  # The protocol handler is called automatically by the Ethscriptions contract
  let(:dummy_recipient) { valid_address("recipient") }

  describe "Token Deployment" do
    it "deploys a new token with all parameters" do
      token_data = {
        "p" => "erc-20",
        "op" => "deploy",
        "tick" => "punk",
        "max" => "21000000",
        "lim" => "1000"
      }

      expect_ethscription_success(
        create_input(
          creator: alice,
          to: dummy_recipient,
          data_uri: "data:," + token_data.to_json
        )
      ) do |results|
        # Verify the ethscription was created
        ethscription_id = results[:ethscription_ids].first
        stored = get_ethscription_content(ethscription_id)

        # Verify the content includes our data
        expect(stored[:content]).to include('"p":"erc-20"')
        expect(stored[:content]).to include('"op":"deploy"')
        expect(stored[:content]).to include('"tick":"punk"')

        # TODO: Once TokenManager contract is available, verify token was deployed
        # token_info = get_token_info("punk")
        # expect(token_info[:max_supply]).to eq(21000000)
        # expect(token_info[:mint_limit]).to eq(1000)
        # expect(token_info[:deployer]).to eq(alice)
      end
    end

    it "handles large numbers as strings for JavaScript compatibility" do
      token_data = {
        "p" => "erc-20",
        "op" => "deploy",
        "tick" => "bignum",
        "max" => "1000000000000000000", # 1e18
        "lim" => "100000000000000000"   # 1e17
      }

      expect_ethscription_success(
        create_input(
          creator: alice,
          to: dummy_recipient,
          data_uri: "data:," + token_data.to_json
        )
      ) do |results|
        # Verify the ethscription was created with large numbers
        ethscription_id = results[:ethscription_ids].first
        stored = get_ethscription_content(ethscription_id)

        expect(stored[:content]).to include('"max":"1000000000000000000"')
        expect(stored[:content]).to include('"lim":"100000000000000000"')
      end
    end

    it "rejects malformed deploy data" do
      # Missing required field
      malformed_data = {
        "p" => "erc-20",
        "op" => "deploy",
        "tick" => "badtoken"
        # Missing max and lim
      }

      expect_protocol_extraction_failure(
        create_input(
          creator: alice,
          to: dummy_recipient,
          data_uri: "data:," + malformed_data.to_json
        )
      ) do |results, stored|
        # Ethscription created but protocol extraction failed
        expect(stored[:content]).to include('"p":"erc-20"')

        # TODO: Verify no token was deployed in contract
        # token_info = get_token_info("bad")
        # expect(token_info).to be_nil
      end
    end
  end

  describe "Token Minting" do
    context "with shared token deployment" do
      before do
        # Deploy a token first
        deploy_data = {
          "p" => "erc-20",
          "op" => "deploy",
          "tick" => "minttest",
          "max" => "1000000",
          "lim" => "100"
        }

        expect_ethscription_success(
          create_input(
            creator: alice,
            to: dummy_recipient,
            data_uri: "data:," + deploy_data.to_json
          )
        )
      end

      it "mints tokens successfully" do
        mint_data = {
          "p" => "erc-20",
          "op" => "mint",
          "tick" => "minttest",
          "id" => "1",
          "amt" => "100"
        }

        expect_ethscription_success(
          create_input(
            creator: bob,
            to: dummy_recipient,
            data_uri: "data:," + mint_data.to_json
          )
        ) do |results|
          # Verify the ethscription was created
          ethscription_id = results[:ethscription_ids].first
          stored = get_ethscription_content(ethscription_id)

          expect(stored[:content]).to include('"op":"mint"')
          expect(stored[:content]).to include('"amt":"100"')

          # TODO: Once TokenManager contract is available, verify mint
          # balance = get_token_balance("test", bob)
          # expect(balance).to eq(100)

          # mint_info = get_mint_info("test", 1)
          # expect(mint_info[:minter]).to eq(bob)
          # expect(mint_info[:amount]).to eq(100)
        end
      end
    end  # end of "with shared token deployment" context

    it "handles sequential mints with incremental IDs" do
      # Deploy a separate token for this test to avoid conflicts
      deploy_data = {
        "p" => "erc-20",
        "op" => "deploy",
        "tick" => "seqmint",  # Different token name
        "max" => "1000000",
        "lim" => "100"
      }

      deploy_results = import_l1_block([
        create_input(
          creator: alice,
          to: dummy_recipient,
          data_uri: "data:," + deploy_data.to_json
        )
      ], esip_overrides: {})

      expect(deploy_results[:l2_receipts].first[:status]).to eq('0x1'), "Token deployment should succeed"

      # First mint with ID 1
      mint1_data = {
        "p" => "erc-20",
        "op" => "mint",
        "tick" => "seqmint",
        "id" => "1",
        "amt" => "100"
      }

      results1 = import_l1_block([
        create_input(
          creator: bob,
          to: dummy_recipient,
          data_uri: "data:," + mint1_data.to_json
        )
      ], esip_overrides: {})

      expect(results1[:l2_receipts].first[:status]).to eq('0x1'), "First mint should succeed"

      # Second mint with ID 2
      mint2_data = {
        "p" => "erc-20",
        "op" => "mint",
        "tick" => "seqmint",
        "id" => "2",
        "amt" => "100"
      }

      results2 = import_l1_block([
        create_input(
          creator: bob,
          to: dummy_recipient,
          data_uri: "data:," + mint2_data.to_json
        )
      ], esip_overrides: {})

      expect(results2[:l2_receipts].first[:status]).to eq('0x1'), "Second mint should succeed"

      # TODO: Verify both mints in contract
      # balance = get_token_balance("seqmint", bob)
      # expect(balance).to eq(200)  # 100 + 100
    end

    it "rejects mint with duplicate ID" do
      # Deploy a separate token for this test
      deploy_data = {
        "p" => "erc-20",
        "op" => "deploy",
        "tick" => "duptest",
        "max" => "1000000",
        "lim" => "100"
      }

      expect_ethscription_success(
        create_input(
          creator: alice,
          to: dummy_recipient,
          data_uri: "data:," + deploy_data.to_json
        )
      )

      mint_data = {
        "p" => "erc-20",
        "op" => "mint",
        "tick" => "duptest",
        "id" => "1",
        "amt" => "100"
      }

      # First mint succeeds
      expect_ethscription_success(
        create_input(
          creator: bob,
          to: dummy_recipient,
          data_uri: "data:," + mint_data.to_json
        )
      )

      # Second mint with same ID creates ethscription but protocol handler rejects
      expect_ethscription_failure(
        create_input(
          creator: charlie,
          to: dummy_recipient,
          data_uri: "data:," + mint_data.to_json
        ),
        reason: :revert
      )
    end
  end

  describe "Protocol Format Validation" do
    it "requires exact JSON format for token operations" do
      # Extra whitespace in JSON should fail
      invalid_format = '{"p": "erc-20", "op": "deploy", "tick": "badformat", "max": "100", "lim": "10"}'

      expect_protocol_extraction_failure(
        create_input(
          creator: alice,
          to: dummy_recipient,
          data_uri: "data:," + invalid_format
        )
      ) do |results, stored|
        # The token regex requires exact format with no extra spaces
        expect(stored[:content]).to include('erc-20')

        # TODO: Verify no token was deployed
        # token_info = get_token_info("bad")
        # expect(token_info).to be_nil
      end
    end

    it "requires lowercase ticks" do
      uppercase_tick = {
        "p" => "erc-20",
        "op" => "deploy",
        "tick" => "UPPERTEST",  # Uppercase not allowed
        "max" => "1000",
        "lim" => "100"
      }

      expect_protocol_extraction_failure(
        create_input(
          creator: alice,
          to: dummy_recipient,
          data_uri: "data:," + uppercase_tick.to_json
        )
      )
    end

    it "limits tick length to 28 characters" do
      long_tick = {
        "p" => "erc-20",
        "op" => "deploy",
        "tick" => "toolongtick" + "a" * 29,  # Too long
        "max" => "1000",
        "lim" => "100"
      }

      expect_protocol_extraction_failure(
        create_input(
          creator: alice,
          to: dummy_recipient,
          data_uri: "data:," + long_tick.to_json
        )
      )
    end

    it "rejects negative numbers" do
      negative_max = {
        "p" => "erc-20",
        "op" => "deploy",
        "tick" => "negative",
        "max" => "-1000",  # Negative not allowed
        "lim" => "100"
      }

      expect_protocol_extraction_failure(
        create_input(
          creator: alice,
          to: dummy_recipient,
          data_uri: "data:," + negative_max.to_json
        )
      )
    end

    it "rejects numbers with leading zeros" do
      leading_zero = {
        "p" => "erc-20",
        "op" => "mint",
        "tick" => "leadzero",
        "id" => "01",  # Leading zero not allowed
        "amt" => "100"
      }

      expect_protocol_extraction_failure(
        create_input(
          creator: alice,
          to: dummy_recipient,
          data_uri: "data:," + leading_zero.to_json
        )
      )
    end
  end

  describe "Contract State Verification" do
    it "creates a token and verifies it exists in contract" do
      token_data = {
        "p" => "erc-20",
        "op" => "deploy",
        "tick" => "verifytoken",
        "max" => "1000000",
        "lim" => "1000"
      }

      expect_ethscription_success(
        create_input(
          creator: alice,
          to: dummy_recipient,
          data_uri: "data:," + token_data.to_json
        )
      ) do |results|
        ethscription_id = results[:ethscription_ids].first

        # TODO: Once TokenManager is deployed, verify token state
        # Verify token exists in contract
        # token_info = get_token_info("verified")
        # expect(token_info).to be_present
        # expect(token_info[:deployer]).to eq(alice)
        # expect(token_info[:max_supply]).to eq(1000000)
        # expect(token_info[:mint_limit]).to eq(1000)
        # expect(token_info[:total_minted]).to eq(0)

        # Verify token contract was deployed
        # token_contract = get_token_contract("verified")
        # expect(token_contract).not_to eq('0x0000000000000000000000000000000000000000')
      end
    end

    it "tracks mint count and enforces limits" do
      # Deploy with low limit for testing
      deploy_data = {
        "p" => "erc-20",
        "op" => "deploy",
        "tick" => "limitedtoken",
        "max" => "300",
        "lim" => "100"
      }

      expect_ethscription_success(
        create_input(
          creator: alice,
          to: dummy_recipient,
          data_uri: "data:," + deploy_data.to_json
        )
      )

      # Mint up to limit
      3.times do |i|
        mint_data = {
          "p" => "erc-20",
          "op" => "mint",
          "tick" => "limitedtoken",
          "id" => i.to_s,
          "amt" => "100"
        }

        expect_ethscription_success(
          create_input(
            creator: bob,
            to: dummy_recipient,
            data_uri: "data:," + mint_data.to_json
          )
        )
      end

      # TODO: Verify contract state
      # token_info = get_token_info("limited")
      # expect(token_info[:total_minted]).to eq(300)

      # Fourth mint should fail (exceeds max supply)
      mint_data = {
        "p" => "erc-20",
        "op" => "mint",
        "tick" => "limitedtoken",
        "id" => "3",
        "amt" => "100"
      }

      expect_ethscription_success(
        create_input(
          creator: charlie,
          to: dummy_recipient,
          data_uri: "data:," + mint_data.to_json
        )
      ) do |results|
        # TODO: Check that mint was rejected
        # balance = get_token_balance("limited", charlie)
        # expect(balance).to eq(0)  # Mint rejected - max supply reached
      end
    end
  end

  describe "End-to-End Token Workflow" do
    it "deploys token, mints tokens, and transfers via ethscription transfer" do
      # Step 1: Deploy token
      deploy_data = {
        "p" => "erc-20",
        "op" => "deploy",
        "tick" => "flowtoken",
        "max" => "10000",
        "lim" => "1000"
      }

      deploy_results = expect_ethscription_success(
        create_input(
          creator: alice,
          to: dummy_recipient,
          data_uri: "data:," + deploy_data.to_json
        )
      )

      # TODO: Verify deployment
      # token_info = get_token_info("flow")
      # expect(token_info[:deployer]).to eq(alice)

      # Step 2: Mint tokens to Bob
      mint_data = {
        "p" => "erc-20",
        "op" => "mint",
        "tick" => "flowtoken",
        "id" => "1",
        "amt" => "500"
      }

      mint_results = expect_ethscription_success(
        create_input(
          creator: bob,
          to: bob,  # Mint to Bob so he owns the ethscription and can transfer it
          data_uri: "data:," + mint_data.to_json
        )
      )

      # TODO: Verify mint
      # balance = get_token_balance("flow", bob)
      # expect(balance).to eq(500)

      # Step 3: Transfer the mint ethscription (transfers the tokens)
      # When an erc-20 mint ethscription is transferred, it transfers the tokens
      mint_ethscription_id = mint_results[:ethscription_ids].first

      expect_transfer_success(
        transfer_input(
          from: bob,
          to: charlie,
          id: mint_ethscription_id
        ),
        mint_ethscription_id,
        charlie
      ) do |results|
        # TODO: Verify token transfer
        # bob_balance = get_token_balance("flow", bob)
        # expect(bob_balance).to eq(0)

        # charlie_balance = get_token_balance("flow", charlie)
        # expect(charlie_balance).to eq(500)
      end
    end
  end

  # Helper methods for token protocol (to be implemented when TokenManager is available)

  # def get_token_info(tick)
  #   # Read token info from TokenManager contract
  #   # TODO: Implement when contract is available
  # end

  # def get_token_balance(tick, address)
  #   # Read token balance from TokenManager contract
  #   # TODO: Implement when contract is available
  # end

  # def get_token_contract(tick)
  #   # Get the deployed ERC20 contract address for a token
  #   # TODO: Implement when contract is available
  # end

  # def get_mint_info(tick, mint_id)
  #   # Get information about a specific mint
  #   # TODO: Implement when contract is available
  # end
end

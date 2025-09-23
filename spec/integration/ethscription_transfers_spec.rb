require 'rails_helper'

RSpec.describe "Ethscription Transfers", type: :integration do
  include EthscriptionsTestHelper

  let(:alice) { valid_address("alice") }
  let(:bob) { valid_address("bob") }
  let(:charlie) { valid_address("charlie") }
  let(:zero_address) { "0x0000000000000000000000000000000000000000" }

  # Helper for transfer tests - creates ethscription using new DSL
  def create_test_ethscription(creator:, to:, content:)
    result = expect_ethscription_success(
      create_input(creator: creator, to: to, data_uri: "data:text/plain;charset=utf-8,#{content}")
    )
    result[:ethscription_ids].first
  end

  describe "Single transfer via input" do
    it "transfers from owner (happy path)" do
      # Setup: create ethscription
      create_result = expect_ethscription_success(
        create_input(creator: alice, to: alice, data_uri: "data:text/plain;charset=utf-8,Test content")
      )
      id1 = create_result[:ethscription_ids].first

      # Transfer to bob
      expect_transfer_success(
        transfer_input(from: alice, to: bob, id: id1),
        id1,
        bob
      )
    end

    it "reverts transfer by non-owner" do
      # Setup: create ethscription owned by bob
      create_result = expect_ethscription_success(
        create_input(creator: alice, to: bob, data_uri: "data:text/plain;charset=utf-8,Test content2")
      )
      id1 = create_result[:ethscription_ids].first

      # Alice tries to transfer bob's ethscription - should revert
      expect_transfer_failure(
        transfer_input(from: alice, to: charlie, id: id1),
        id1,
        reason: :revert
      )
    end

    it "reverts transfer of nonexistent ID" do
      # Random nonexistent ID
      fake_id = generate_tx_hash(999)

      results = import_l1_block([
        transfer_input(from: alice, to: bob, id: fake_id)
      ])

      # Should revert for nonexistent ID
      expect(results[:l2_receipts].first[:status]).to eq('0x0'), "Should revert for nonexistent ID"
    end
  end

  describe "Multi-transfer via input (ESIP-5)" do
    it "transfers all valid IDs" do
      # Setup: create two ethscriptions owned by alice
      create1 = expect_ethscription_success(
        create_input(creator: alice, to: alice, data_uri: "data:text/plain;charset=utf-8,Content 1")
      )
      create2 = expect_ethscription_success(
        create_input(creator: alice, to: alice, data_uri: "data:text/plain;charset=utf-8,Content 2")
      )
      id1 = create1[:ethscription_ids].first
      id2 = create2[:ethscription_ids].first

      # Multi-transfer both to bob
      results = import_l1_block([
        transfer_multi_input(from: alice, to: bob, ids: [id1, id2])
      ])

      # Verify L2 transaction succeeded
      expect(results[:l2_receipts].first[:status]).to eq('0x1'), "Multi-transfer should succeed"

      # Verify both ownership changes
      expect(get_ethscription_owner(id1).downcase).to eq(bob.downcase)
      expect(get_ethscription_owner(id2).downcase).to eq(bob.downcase)

      # Verify content unchanged
      expect(get_ethscription_content(id1)[:content]).to eq("Content 1")
      expect(get_ethscription_content(id2)[:content]).to eq("Content 2")
    end

    it "partial success when some IDs not owned by sender" do
      # Setup: id1 owned by alice, id2 owned by bob
      id1 = create_test_ethscription(creator: alice, to: alice, content: "Content 3")
      id2 = create_test_ethscription(creator: bob, to: bob, content: "Content 4")

      # Alice tries to transfer both (can only transfer id1)
      results = import_l1_block([
        transfer_multi_input(from: alice, to: charlie, ids: [id1, id2])
      ])

      # Verify L2 transaction succeeded (partial success)
      expect(results[:l2_receipts].first[:status]).to eq('0x1'), "Multi-transfer should succeed"

      # Only id1 should transfer
      expect(get_ethscription_owner(id1).downcase).to eq(charlie.downcase)
      expect(get_ethscription_owner(id2).downcase).to eq(bob.downcase)  # Unchanged
    end

    it "reverts when all IDs invalid" do
      # Setup: both ids owned by bob, alice tries to transfer
      create1 = expect_ethscription_success(
        create_input(creator: bob, to: bob, data_uri: "data:text/plain;charset=utf-8,Content 5")
      )
      create2 = expect_ethscription_success(
        create_input(creator: bob, to: bob, data_uri: "data:text/plain;charset=utf-8,Content 6")
      )
      id1 = create1[:ethscription_ids].first
      id2 = create2[:ethscription_ids].first

      results = import_l1_block([
        transfer_multi_input(from: alice, to: charlie, ids: [id1, id2])
      ])

      # Should revert when no successful transfers
      expect(results[:l2_receipts].first[:status]).to eq('0x0'), "Should revert with no successful transfers"

      # No ownership changes
      expect(get_ethscription_owner(id1).downcase).to eq(bob.downcase)
      expect(get_ethscription_owner(id2).downcase).to eq(bob.downcase)
    end
  end

  describe "Transfer via event (ESIP-1)" do
    it "transfers via event (happy path)" do
      # Setup: create ethscription
      id1 = create_test_ethscription(creator: alice, to: alice, content: "Test content2a")
# binding.irb
      # Transfer via ESIP-1 event
      expect_transfer_success(
        transfer_event(from: alice, to: bob, id: id1),
        id1,
        bob
      )
    end

    it "ignores event with removed=true" do
      id1 = create_test_ethscription(creator: alice, to: alice, content: "Test content3")

      expect_transfer_failure(
        l1_tx(
          creator: alice,
          to: bob,
          logs: [
            build_transfer_event(from: alice, to: bob, id: id1).merge('removed' => true)
          ]
        ),
        id1,
        reason: :ignored
      )
    end

    it "ignores event with wrong topics length" do
      id1 = create_test_ethscription(creator: alice, to: alice, content: "Test content4")

      expect_transfer_failure(
        l1_tx(
          creator: alice,
          to: bob,
          logs: [
            {
              'address' => alice,
              'topics' => [EthTransaction::Esip1EventSig], # Missing to and id topics
              'data' => '0x',
              'logIndex' => '0x0',
              'removed' => false
            }
          ]
        ),
        id1,
        reason: :ignored
      )
    end
  end

  describe "Transfer for previous owner (ESIP-2)" do
    it "transfers with correct previous owner" do
      # Setup: create ethscription, transfer to bob, then use ESIP-2
      id1 = create_test_ethscription(creator: alice, to: alice, content: "Test content5")

      # First transfer alice -> bob
      expect_transfer_success(
        transfer_input(from: alice, to: bob, id: id1),
        id1,
        bob
      )

      # ESIP-2 transfer bob -> charlie with alice as previous owner
      expect_transfer_success(
        transfer_prev_event(current_owner: bob, prev_owner: alice, to: charlie, id: id1),
        id1,
        charlie
      )
    end

    it "ignores transfer with wrong previous owner" do
      # Setup: create ethscription owned by bob
      id1 = create_test_ethscription(creator: alice, to: bob, content: "Test content6")

      # ESIP-2 transfer with wrong previous owner (charlie instead of alice)
      expect_transfer_failure(
        transfer_prev_event(current_owner: charlie, prev_owner: charlie, to: alice, id: id1),
        id1,
        reason: :revert
      )
    end
  end

  describe "Burn to zero address" do
    it "burns via input transfer to zero address" do
      # Setup: create ethscription
      id1 = create_test_ethscription(creator: alice, to: alice, content: "Burn test")

      # Transfer to zero address (burn)
      expect_transfer_success(
        transfer_input(from: alice, to: zero_address, id: id1),
        id1,
        zero_address
      )
    end

    it "burns via ESIP-1 event to zero address" do
      # Setup: create ethscription
      id1 = create_test_ethscription(creator: alice, to: alice, content: "Burn test2")

      # Transfer to zero via event
      expect_transfer_success(
        transfer_event(from: alice, to: zero_address, id: id1),
        id1,
        zero_address
      )
    end
  end

  describe "In-transaction ordering: create then transfer" do
    it "create via input, transfer via input in same transaction" do
      data_uri = "data:text/plain;charset=utf-8,Create then transfer test"

      results = import_l1_block([
        l1_tx(
          creator: alice,
          to: alice,
          input: string_to_hex(data_uri)
        )
      ])

      # Get the created ethscription ID
      id1 = results[:ethscription_ids].first

      # Now transfer it in a separate transaction
      expect_transfer_success(
        transfer_input(from: alice, to: bob, id: id1),
        id1,
        bob
      )
    end

    it "create via input, transfer via event in same L1 block" do
      data_uri = "data:text/plain;charset=utf-8,Create then transfer via event"

      # Create in first transaction
      create_result = expect_ethscription_success(
        create_input(creator: alice, to: alice, data_uri: data_uri)
      )
      id1 = create_result[:ethscription_ids].first

      # Transfer via event in second transaction of same block
      expect_transfer_success(
        transfer_event(from: alice, to: bob, id: id1),
        id1,
        bob
      )
    end
  end

  describe "ESIP feature gating for transfers" do
    it "ignores ESIP-1 events when disabled" do
      id1 = create_test_ethscription(creator: alice, to: alice, content: "Test content2aaa")

      expect_transfer_failure(
        transfer_event(from: alice, to: bob, id: id1),
        id1,
        reason: :ignored,
        esip_overrides: { esip1_enabled: false }
      )
    end

    it "ignores ESIP-2 events when disabled" do
      id1 = create_test_ethscription(creator: alice, to: bob, content: "Test content3a")

      expect_transfer_failure(
        transfer_prev_event(current_owner: bob, prev_owner: alice, to: charlie, id: id1),
        id1,
        reason: :ignored,
        esip_overrides: { esip2_enabled: false }
      )
    end

    it "rejects multi-transfer when ESIP-5 disabled" do
      id1 = create_test_ethscription(creator: alice, to: alice, content: "Content 1aaaaa")
      id2 = create_test_ethscription(creator: alice, to: alice, content: "Content 2aaaaa")

      expect_transfer_failure(
        transfer_multi_input(from: alice, to: bob, ids: [id1, id2]),
        id1,
        reason: :ignored,
        esip_overrides: { esip5_enabled: false }
      )
    end
  end

  describe "Self-transfer scenarios" do
    it "succeeds self-transfer via input" do
      id1 = create_test_ethscription(creator: alice, to: alice, content: "Self transfer test")

      expect_transfer_success(
        transfer_input(from: alice, to: alice, id: id1),
        id1,
        alice
      )
    end

    it "succeeds self-transfer via event" do
      id1 = create_test_ethscription(creator: alice, to: alice, content: "Self transfer testaaa")

      expect_transfer_success(
        transfer_event(from: alice, to: alice, id: id1),
        id1,
        alice
      )
    end
  end

  describe "Transfer chain scenarios" do
    it "chains multiple transfers in same L1 block" do
      # Setup: create ethscription
      id1 = create_test_ethscription(creator: alice, to: alice, content: "Chain testaaaaaa")

      # Transfer alice -> bob -> charlie in same L1 block
      results = import_l1_block([
        transfer_input(from: alice, to: bob, id: id1),
        transfer_input(from: bob, to: charlie, id: id1)
      ])

      # Both transfers should succeed
      expect(results[:l2_receipts].size).to eq(2)
      results[:l2_receipts].each do |receipt|
        expect(receipt[:status]).to eq('0x1')
      end

      # Final owner should be charlie
      owner = get_ethscription_owner(id1)
      expect(owner.downcase).to eq(charlie.downcase)
    end

    it "transfer after prior transfer respects new owner" do
      # Setup: create ethscription owned by alice
      id1 = create_test_ethscription(creator: alice, to: alice, content: "Chain testbbbb")

      # First: alice -> bob
      expect_transfer_success(
        transfer_input(from: alice, to: bob, id: id1),
        id1,
        bob
      )

      # Second: bob -> charlie (should succeed)
      expect_transfer_success(
        transfer_input(from: bob, to: charlie, id: id1),
        id1,
        charlie
      )

      # Third: alice tries to transfer (should fail - no longer owner)
      expect_transfer_failure(
        transfer_input(from: alice, to: bob, id: id1),
        id1,
        reason: :revert
      )
    end
  end
end
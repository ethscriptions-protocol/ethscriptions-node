require 'rails_helper'

RSpec.describe "Simple Ethscription Creation", type: :integration do
  include EthscriptionsTestHelper

  let(:alice) { valid_address("alice") }
  let(:bob) { valid_address("bob") }

  it "creates a simple ethscription with plain text" do
    # Try the simplest possible ethscription - just plain text
    tx_spec = create_input(
      creator: alice,
      to: bob,
      data_uri: "data:,Hello World"
    )

    results = import_l1_block([tx_spec])

    puts "Results keys: #{results.keys}"
    puts "Ethscription IDs: #{results[:ethscription_ids]}"
    puts "L2 receipts: #{results[:l2_receipts]&.length}"
    puts "Ethscriptions: #{results[:ethscriptions]&.length}"

    if results[:l2_receipts]&.any?
      puts "First receipt status: #{results[:l2_receipts].first[:status]}"
    end

    expect(results[:ethscription_ids]).not_to be_empty
    expect(results[:l2_receipts]).not_to be_empty
    expect(results[:l2_receipts].first[:status]).to eq('0x1')
  end

  it "creates a simple JSON ethscription" do
    # Try a simple JSON structure
    json_data = { "test" => "value" }

    tx_spec = create_input(
      creator: alice,
      to: bob,
      data_uri: "data:," + json_data.to_json
    )

    results = import_l1_block([tx_spec])

    puts "JSON test results:"
    puts "Ethscription IDs: #{results[:ethscription_ids]}"
    puts "L2 receipts: #{results[:l2_receipts]&.length}"

    expect(results[:ethscription_ids]).not_to be_empty
  end

  it "tests content size limits" do
    # Test with increasing content sizes
    base_data = {
      "p" => "collections",
      "op" => "create_collection",
      "name" => "Test",
      "symbol" => "TST",
      "totalSupply" => "100",
      "description" => "A" * 50,  # 50 chars
      "extra1" => "B" * 50,
      "extra2" => "C" * 50,
      "extra3" => "D" * 50
    }

    data_uri = "data:," + base_data.to_json
    puts "Testing with content length: #{data_uri.length} bytes"

    tx_spec = create_input(
      creator: alice,
      to: bob,
      data_uri: data_uri
    )

    results = import_l1_block([tx_spec])
    ethscription_id = results[:ethscription_ids].first
    stored = get_ethscription_content(ethscription_id)

    puts "Original content length: #{base_data.to_json.length}"
    puts "Stored content length: #{stored[:content].length}"
    puts "Content starts with 'p': #{stored[:content].start_with?('{"p":"collections"')}"
    puts "First 50 chars: #{stored[:content][0..49]}"

    # For debugging, show if content was truncated
    if stored[:content].length < base_data.to_json.length
      puts "WARNING: Content was truncated!"
      puts "Lost #{base_data.to_json.length - stored[:content].length} bytes"
    end

    expect(stored[:content].length).to eq(base_data.to_json.length), "Content should not be truncated"
  end

  it "creates a simple collections protocol ethscription" do
    # Try the simplest collections protocol data
    collection_data = {
      "p" => "collections",
      "op" => "create_collection",
      "name" => "Test",
      "symbol" => "TST",
      "totalSupply" => "100"
    }

    data_uri = "data:," + collection_data.to_json
    puts "Data URI: #{data_uri}"
    puts "Data URI length: #{data_uri.length}"

    tx_spec = create_input(
      creator: alice,
      to: bob,
      data_uri: data_uri
    )

    results = import_l1_block([tx_spec])

    # Check the stored content
    ethscription_id = results[:ethscription_ids].first
    stored = get_ethscription_content(ethscription_id)

    puts "Collections test results:"
    puts "Ethscription ID: #{ethscription_id}"
    puts "Stored content: #{stored[:content].inspect}"
    puts "Content includes 'p': #{stored[:content].include?('"p":"collections"')}"
    puts "Full match: #{stored[:content] == collection_data.to_json}"

    expect(results[:ethscription_ids]).not_to be_empty, "Should create ethscription ID"
    expect(results[:l2_receipts]).not_to be_empty, "Should have L2 receipt"
    expect(stored[:content]).to include('"p":"collections"'), "Content should include protocol"
  end
end
require 'rails_helper'

RSpec.describe "Ethscription Creation", type: :integration do
  include EthscriptionsTestHelper

  let(:alice) { valid_address("alice") }
  let(:bob) { valid_address("bob") }
  let(:charlie) { valid_address("charlie") }

  describe "Creation by Input" do
    describe "Valid data URIs" do
      it "creates text/plain ethscription" do
        expect_ethscription_success(
          create_input(
            creator: alice,
            to: bob,
            data_uri: "data:text/plain;charset=utf-8,Hello, Ethscriptions World!"
          )
        )
      end

      it "creates application/json ethscription" do
        expect_ethscription_success(
          create_input(
            creator: alice,
            to: bob,
            data_uri: 'data:application/json,{"op":"deploy","tick":"TEST","max":"21000000"}'
          )
        )
      end

      it "creates image/svg+xml ethscription" do
        expect_ethscription_success(
          create_input(
            creator: alice,
            to: bob,
            data_uri: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="red"/></svg>'
          )
        )
      end
    end

    describe "Base64 data URIs" do
      it "creates image/png with base64 encoding" do
        expect_ethscription_success(
          create_input(
            creator: alice,
            to: bob,
            data_uri: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
          )
        )
      end

      it "creates with custom charset in base64 data URI" do
        expect_ethscription_success(
          create_input(
            creator: alice,
            to: bob,
            data_uri: "data:image/png;charset=utf-8;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
          )
        )
      end
    end

    describe "GZIP compression" do
      it "rejects GZIP input pre-ESIP-7" do
        compressed_data_uri = Zlib.gzip("data:text/plain;charset=utf-8,Hello World")  # Placeholder for GZIP data

        expect_ethscription_failure(
          create_input(
            creator: alice,
            to: bob,
            data_uri: compressed_data_uri
          ),
          reason: :ignored,
          esip_overrides: { esip7_enabled: false }
        )
      end

      it "accepts GZIP input post-ESIP-7" do
        compressed_data_uri = Zlib.gzip("data:text/plain;charset=utf-8,Hello World")  # Placeholder for GZIP data

        expect_ethscription_success(
          create_input(
            creator: alice,
            to: bob,
            data_uri: compressed_data_uri
          ),
          esip_overrides: { esip7_enabled: true }
        )
      end
    end

    describe "Invalid data URIs" do
      it "rejects missing data: prefix" do
        expect_ethscription_failure(
          create_input(
            creator: alice,
            to: bob,
            data_uri: "text/plain;charset=utf-8,Hello World"  # Missing "data:"
          ),
          reason: :ignored
        )
      end

      it "rejects malformed data uri" do
        expect_ethscription_failure(
          create_input(
            creator: alice,
            to: bob,
            data_uri: "data:invalid-mimetype,Hello World"
          ),
          reason: :ignored
        )
      end

      it "rejects bad encoding" do
        expect_ethscription_failure(
          create_input(
            creator: alice,
            to: bob,
            data_uri: "data:text/plain;base64,invalid-base64-!@#$%"
          ),
          reason: :ignored
        )
      end
    end

    describe "Non-UTF8 and edge cases" do
      it "rejects non-UTF8 raw input" do
        expect_ethscription_failure(
          {
            creator: alice,
            to: bob,
            input: "0x" + "ff" * 100  # Invalid UTF-8 bytes
          },
          reason: :ignored
        )
      end

      it "rejects empty input" do
        expect_ethscription_failure(
          {
            creator: alice,
            to: bob,
            input: "0x"
          },
          reason: :ignored
        )
      end

      it "rejects null input" do
        expect_ethscription_failure(
          {
            creator: alice,
            to: bob,
            input: ""
          },
          reason: :ignored
        )
      end
    end

    describe "Invalid addresses" do
      it "allows input to null address" do
        expect_ethscription_success(
          create_input(
            creator: alice,
            to: "0x0000000000000000000000000000000000000000",
            data_uri: "data:text/plain;charset=utf-8,Hello World33333"
          )
        )
      end

      it "rejects contract creation (no to address)" do
        expect_ethscription_failure(
          {
            creator: alice,
            to: nil,  # Contract creation
            input: string_to_hex("data:text/plain;charset=utf-8,Hello World")
          },
          reason: :ignored
        )
      end
    end

    describe "Multiple creates in same transaction" do
      it "input takes precedence over event in same transaction" do
        # Create a transaction with both input creation AND event creation
        # Only input should succeed, event should be ignored per protocol rules
        results = import_l1_block([
          l1_tx(
            creator: alice,
            to: bob,
            input: string_to_hex("data:text/plain;charset=utf-8,Hello from Input"),
            logs: [
              build_create_event(
                creator: alice,
                initial_owner: bob,
                content_uri: "data:text/plain;charset=utf-8,Hello from Event"
              )
            ]
          )
        ])
# binding.irb
        # Should only create one ethscription (via input, not event)
        # expect(results[:ethscription_ids].size).to eq(1)
        expect(results[:l2_receipts].first[:status]).to eq('0x1')
        expect(results[:l2_receipts].second[:status]).to eq('0x0')

        # Verify it used the input content, not the event content
        stored = get_ethscription_content(results[:ethscription_ids].first)
        expect(stored[:content]).to include("Hello from Input")
      end
    end

    describe "Multiple creates in same L1 block" do
      it "creates multiple ethscriptions successfully" do
        results = import_l1_block([
          create_input(
            creator: alice,
            to: bob,
            data_uri: 'data:application/json,{"op":"deploy","tick":"TEST","max":"5"}'
          ),
          create_input(
            creator: charlie,
            to: alice,
            data_uri: "data:text/plain;charset=utf-8,Second ethscription in same block"
          )
        ])

        # Both should succeed
        expect(results[:ethscription_ids].size).to eq(2)
        results[:l2_receipts].each do |receipt|
          expect(receipt[:status]).to eq('0x1')
        end
      end
    end
  end

  describe "Creation by Event (ESIP-3)" do
    describe "Valid CreateEthscription events" do
      it "creates ethscription via event" do
        expect_ethscription_success(
          create_event(
            creator: alice,
            initial_owner: bob,
            data_uri: "data:text/plain;charset=utf-8,Hello via Eve22nt!"
          )
        )
      end

      it "creates with JSON content via event" do
        expect_ethscription_success(
          create_event(
            creator: alice,
            initial_owner: bob,
            data_uri: 'data:application/json,{"message":"Hello via Eve44nt"}'
          )
        )
      end
    end

    describe "ESIP-3 feature gating" do
      it "ignores events when ESIP-3 disabled" do
        expect_ethscription_failure(
          create_event(
            creator: alice,
            initial_owner: bob,
            data_uri: "data:text/plain;charset=utf-8,Should be ignored"
          ),
          reason: :ignored,
          esip_overrides: { esip3_enabled: false }
        )
      end

      it "processes events when ESIP-3 enabled" do
        expect_ethscription_success(
          create_event(
            creator: alice,
            initial_owner: bob,
            data_uri: "data:text/plain;charset=utf-8,Should work"
          ),
          esip_overrides: { esip3_enabled: true }
        )
      end
    end

    describe "Invalid events" do
      it "ignores malformed event (wrong topic length)" do
        expect_ethscription_failure(
          {
            creator: alice,
            to: bob,
            input: "0x",
            logs: [
              {
                'address' => alice,
                'topics' => [EthTransaction::CreateEthscriptionEventSig], # Missing initial_owner topic
                'data' => string_to_hex("data:text/plain,Hello"),
                'logIndex' => '0x0',
                'removed' => false
              }
            ]
          },
          reason: :ignored
        )
      end

      it "ignores removed=true logs" do
        expect_ethscription_failure(
          l1_tx(
            creator: alice,
            to: bob,
            logs: [
              {
                'address' => alice,
                'topics' => [
                  EthTransaction::CreateEthscriptionEventSig,
                  "0x#{Eth::Abi.encode(['address'], [bob]).unpack1('H*')}"
                ],
                'data' => "0x#{Eth::Abi.encode(['string'], ['data:text/plain,Hello']).unpack1('H*')}",
                'logIndex' => '0x0',
                'removed' => true  # Should be ignored
              }
            ]
          ),
          reason: :ignored
        )
      end
    end

    describe "Event content validation" do
      it "sanitizes and accepts valid data URI from non-UTF8 event data" do
        # Event data that becomes valid after sanitization
        expect_ethscription_success(
          create_event(
            creator: alice,
            initial_owner: bob,
            data_uri: "data:text/plain;charset=utf-8,Hello\x00World"  # Contains null byte
          )
        )
      end

      it "rejects event with completely invalid content" do
        expect_ethscription_failure(
          l1_tx(
            creator: alice,
            to: bob,
            logs: [
              {
                'address' => alice,
                'topics' => [
                  EthTransaction::CreateEthscriptionEventSig,
                  "0x#{Eth::Abi.encode(['address'], [bob]).unpack1('H*')}"
                ],
                'data' => "0x" + "ff" * 100,  # Invalid UTF-8 that doesn't sanitize to data URI
                'logIndex' => '0x0',
                'removed' => false
              }
            ]
          ),
          reason: :ignored
        )
      end
    end

    describe "ESIP-6 (duplicate content) end-to-end" do
      it "reverts duplicate content without ESIP-6" do
        content_uri = "data:text/plain;charset=utf-8,Duplicate content test"

        # First creation should succeed
        expect_ethscription_success(
          create_input(creator: alice, to: bob, data_uri: content_uri)
        )

        # Second creation with same content should revert
        expect_ethscription_failure(
          create_input(creator: charlie, to: alice, data_uri: content_uri),
          reason: :revert
        )
      end

      it "succeeds duplicate content with ESIP-6" do
        base_content = "Duplicate content test"
        normal_uri = "data:text/plain;charset=utf-8,#{base_content}"
        esip6_uri = "data:text/plain;charset=utf-8;rule=esip6,#{base_content}"

        # First creation without ESIP-6
        first_result = expect_ethscription_success(
          create_input(creator: alice, to: bob, data_uri: esip6_uri)
        )

        # Second creation with ESIP-6 rule should succeed
        second_result = expect_ethscription_success(
          create_input(creator: charlie, to: alice, data_uri: esip6_uri)
        )

        # Verify both have same content URI hash but second has esip6: true
        first_stored = get_ethscription_content(first_result[:ethscription_ids].first)
        second_stored = get_ethscription_content(second_result[:ethscription_ids].first)

        expect(first_stored[:content_uri_hash]).to eq(second_stored[:content_uri_hash])
        
        expect(first_stored[:esip6]).to be_truthy
        expect(second_stored[:esip6]).to be_truthy
      end
    end

    describe "Multiple create events in same transaction" do
      it "processes only first event, ignores second" do
        results = import_l1_block([
          l1_tx(
            creator: alice,
            to: bob,
            logs: [
              build_create_event(
                creator: alice,
                initial_owner: bob,
                content_uri: "data:text/plain;charset=utf-8,First event"
              ).merge('logIndex' => '0x0'),
              build_create_event(
                creator: alice,
                initial_owner: charlie,
                content_uri: "data:text/plain;charset=utf-8,Second event"
              ).merge('logIndex' => '0x1')
            ]
          )
        ])

        # Should only create one ethscription (from first event)
        expect(results[:l2_receipts].size).to eq(2)
        expect(results[:l2_receipts].map { |r| r[:status] }).to eq(['0x1', '0x0'])

        # Verify content is from first event
        stored = get_ethscription_content(results[:ethscription_ids].first)
        expect(stored[:content]).to include("First event")
      end

      it "respects logIndex order when choosing first event" do
        results = import_l1_block([
          l1_tx(
            creator: alice,
            to: bob,
            logs: [
              build_create_event(
                creator: alice,
                initial_owner: charlie,
                content_uri: "data:text/plain;charset=utf-8,Second by logIndex"
              ).merge('logIndex' => '0x1'),
              build_create_event(
                creator: alice,
                initial_owner: bob,
                content_uri: "data:text/plain;charset=utf-8,First by logIndex"
              ).merge('logIndex' => '0x0')
            ]
          )
        ])

        # Should process event with logIndex 0x0 first
        expect(results[:ethscription_ids].size).to eq(1)
        stored = get_ethscription_content(results[:ethscription_ids].first)
        expect(stored[:content]).to include("First by logIndex")
      end
    end

    describe "Empty content data URI" do
      it "succeeds with empty data URI via input" do
        expect_ethscription_success(
          create_input(
            creator: alice,
            to: bob,
            data_uri: "data:,"
          )
        ) do |results|
          stored = get_ethscription_content(results[:ethscription_ids].first)
          expect(stored[:content]).to be_empty
          # TODO: Verify mimetype defaults
        end
      end
    end

    describe "Creator/owner edge cases (events)" do
      it "handles initialOwner = zero address" do
        expect_ethscription_success(
          create_event(
            creator: alice,
            initial_owner: "0x0000000000000000000000000000000000000000",
            data_uri: "data:text/plain;charset=utf-8,Transfer to zero test"
          )
        ) do |results|
          # Should end up owned by zero address
          owner = get_ethscription_owner(results[:ethscription_ids].first)
          expect(owner.downcase).to eq("0x0000000000000000000000000000000000000000")
        end
      end

      it "rejects event with creator = zero address" do
        expect_ethscription_failure(
          l1_tx(
            creator: "0x0000000000000000000000000000000000000000",
            to: bob,
            logs: [
              {
                'address' => "0x0000000000000000000000000000000000000000",
                'topics' => [
                  EthTransaction::CreateEthscriptionEventSig,
                  "0x#{Eth::Abi.encode(['address'], [bob]).unpack1('H*')}"
                ],
                'data' => "0x#{Eth::Abi.encode(['string'], ['data:text/plain,Hello']).unpack1('H*')}",
                'logIndex' => '0x0',
                'removed' => false
              }
            ]
          ),
          reason: :revert
        )
      end
    end

    describe "Storage field correctness" do
      it "stores correct metadata for input creation" do
        content_uri = "data:image/svg+xml;charset=utf-8,<svg>test</svg>"

        expect_ethscription_success(
          create_input(creator: alice, to: bob, data_uri: content_uri)
        ) do |results|
          stored = get_ethscription_content(results[:ethscription_ids].first)

          # Verify content fields
          expect(stored[:content]).to eq("<svg>test</svg>")
          expect(stored[:mimetype]).to eq("image/svg+xml")
          expect(stored[:media_type]).to eq("image")
          expect(stored[:mime_subtype]).to eq("svg+xml")

          # Verify content URI hash
          expected_hash = Digest::SHA256.hexdigest(content_uri)
          expect(stored[:content_uri_hash]).to eq("0x#{expected_hash}")

          # Verify block references are set
          expect(stored[:l1_block_number]).to be > 0
          expect(stored[:l2_block_number]).to be > 0
          expect(stored[:l1_block_hash]).to match(/^0x[0-9a-f]{64}$/i)
        end
      end

      it "stores correct metadata for event creation" do
        content_uri = "data:application/json,{\"test\":\"data\"}"

        expect_ethscription_success(
          create_event(creator: alice, initial_owner: bob, data_uri: content_uri)
        ) do |results|
          stored = get_ethscription_content(results[:ethscription_ids].first)

          expect(stored[:mimetype]).to eq("application/json")
          expect(stored[:media_type]).to eq("application")
          expect(stored[:mime_subtype]).to eq("json")

          # Verify content URI hash matches
          expected_hash = Digest::SHA256.hexdigest(content_uri)
          expect(stored[:content_uri_hash]).to eq("0x#{expected_hash}")
        end
      end
    end

    describe "Mixed input/event with same content" do
      it "input takes precedence, stores input content exactly" do
        input_content = "data:text/plain;charset=utf-8,Hello from Input123"
        event_content = "data:text/plain;charset=utf-8,Hello from Event123"

        results = import_l1_block([
          l1_tx(
            creator: alice,
            to: bob,
            input: string_to_hex(input_content),
            logs: [
              build_create_event(
                creator: alice,
                initial_owner: bob,
                content_uri: event_content
              )
            ]
          )
        ])

        # Should only create one ethscription (via input)
        expect(results[:ethscription_ids].size).to eq(1)
        expect(results[:l2_receipts].first[:status]).to eq('0x1')

        # Verify stored content exactly matches input URI
        stored = get_ethscription_content(results[:ethscription_ids].first)
        expect(stored[:content]).to eq("Hello from Input123")
      end
    end
  end
end

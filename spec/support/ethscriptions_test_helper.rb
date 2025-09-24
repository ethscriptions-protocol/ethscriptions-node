module EthscriptionsTestHelper
  def generate_ethscription_data(params = {})
    content_type = params[:content_type]
    content = params[:content]

    "data:#{content_type};charset=utf-8,#{content}"
  end

  def build_ethscription_input(params = {})
    raw_input = params[:input] || params[:data]
    return normalize_to_hex(raw_input) if raw_input

    data_uri = generate_ethscription_data(params)
    string_to_hex(data_uri)
  end

  def normalize_to_hex(value)
    return nil if value.nil?

    if value.respond_to?(:to_hex)
      return value.to_hex
    end

    string = value.to_s
    return string if string.start_with?('0x') || string.start_with?('0X')

    string_to_hex(string)
  end

  def string_to_hex(string)
    "0x#{string.to_s.unpack1('H*')}"
  end

  def normalize_address(address)
    return nil if address.nil?
    
    address = address.is_a?(Address20) ? address : Address20.from_hex(address)

    address.to_hex.downcase
  end

  # Generate a simple image ethscription
  def generate_image_ethscription(**params)
    params.merge(
      content_type: "image/svg+xml",
      content: '<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="red"/></svg>'
    )
  end

  # Generate a JSON ethscription (like a token)
  def generate_json_ethscription(**params)
    json_content = params[:json] || { op: "mint", tick: "test", amt: "1000" }
    params.merge(
      content_type: "application/json",
      content: json_content.to_json
    )
  end

  # Validate ethscription was stored correctly in contract
  def verify_ethscription_in_contract(tx_hash, expected_creator: nil, expected_content: nil, block_tag: 'latest')
    stored = StorageReader.get_ethscription_with_content(tx_hash, block_tag: block_tag)

    expect(stored).to be_present, "Ethscription #{tx_hash} not found in contract storage"

    if expected_creator
      expect(stored[:creator].downcase).to eq(expected_creator.downcase)
    end

    if expected_content
      expect(stored[:content]).to eq(expected_content)
    end

    stored
  end

  # Make static call to contract to verify state
  def get_ethscription_owner(tx_hash)
    StorageReader.get_owner(tx_hash)
  end

  def get_ethscription_content(tx_hash, block_tag: 'latest')
    StorageReader.get_ethscription_with_content(tx_hash, block_tag: block_tag)
  end

  # Generate a valid Ethereum address from a seed string
  def valid_address(seed)
    "0x#{Digest::SHA256.hexdigest(seed.to_s)[0,40]}"
  end

  # Minimal DSL for transaction descriptors
  def create_input(creator:, to:, data_uri:, expect: :success)
    {
      type: :create_input,
      creator: creator,
      to: to,
      input: data_uri,
      expect: expect
    }
  end

  def create_event(creator:, initial_owner:, data_uri:, expect: :success)
    {
      type: :create_event,
      creator: creator,
      to: initial_owner,
      input: "0x",
      logs: [build_create_event(creator: creator, initial_owner: initial_owner, content_uri: data_uri)],
      expect: expect
    }
  end

  # Low-level transaction builder - compose input and logs
  def l1_tx(creator:, to: nil, input: "0x", logs: [], tx_hash: nil, status: '0x1', expect: :success)
    {
      type: :custom,
      creator: creator,
      to: to,
      input: input,
      logs: logs,
      tx_hash: tx_hash,
      status: status,
      expect: expect
    }
  end

  def transfer_input(from:, to:, id:, expect: :success)
    {
      type: :transfer_input,
      creator: from,
      to: to,
      input: normalize_to_hex(id),
      expect: expect
    }
  end

  def transfer_multi_input(from:, to:, ids:, expect: :success)
    # Join multiple 32-byte hashes (remove 0x prefixes and concatenate)
    combined_ids = ids.map { |id| id.delete_prefix('0x') }.join('')

    {
      type: :transfer_multi_input,
      creator: from,
      to: to,
      input: "0x#{combined_ids}",
      expect: expect
    }
  end

  def transfer_event(from:, to:, id:, expect: :success)
    {
      type: :transfer_event,
      creator: from,
      to: to,
      input: "0x",
      logs: [build_transfer_event(from: from, to: to, id: id)],
      expect: expect
    }
  end

  def transfer_prev_event(current_owner:, prev_owner:, to:, id:, expect: :success)
    {
      type: :transfer_prev_event,
      creator: prev_owner,
      to: to,
      input: "0x",
      logs: [build_transfer_prev_event(current_owner: current_owner, prev_owner: prev_owner, to: to, id: id)],
      expect: expect
    }
  end

  # Event builders
  def build_create_event(creator:, initial_owner:, content_uri:)
    encoded_data = Eth::Abi.encode(['string'], [content_uri])
    encoded_owner = Eth::Abi.encode(['address'], [initial_owner])
    
    {
      'address' => normalize_address(creator),
      'topics' => [
        EthTransaction::CreateEthscriptionEventSig,
        "0x#{encoded_owner.unpack1('H*')}"
      ],
      'data' => "0x#{encoded_data.unpack1('H*')}",
      'logIndex' => '0x0',
      'removed' => false
    }
  end

  def build_transfer_event(from:, to:, id:)
    encoded_to = Eth::Abi.encode(['address'], [to])
    encoded_id = Eth::Abi.encode(['bytes32'], [ByteString.from_hex(id).to_bin])

    {
      'address' => normalize_address(from),
      'topics' => [
        EthTransaction::Esip1EventSig,
        "0x#{encoded_to.unpack1('H*')}",
        "0x#{encoded_id.unpack1('H*')}"
      ],
      'data' => '0x',
      'logIndex' => '0x0',
      'removed' => false
    }
  end

  def build_transfer_prev_event(prev_owner:, current_owner:, to:, id:)
    encoded_to = Eth::Abi.encode(['address'], [to])
    encoded_prev = Eth::Abi.encode(['address'], [prev_owner])
    encoded_id = Eth::Abi.encode(['bytes32'], [ByteString.from_hex(id).to_bin])

    {
      'address' => normalize_address(current_owner),
      'topics' => [
        EthTransaction::Esip2EventSig,
        "0x#{encoded_prev.unpack1('H*')}",  # previousOwner first
        "0x#{encoded_to.unpack1('H*')}",    # then to
        "0x#{encoded_id.unpack1('H*')}"     # then id
      ],
      'data' => '0x',
      'logIndex' => '0x0',
      'removed' => false
    }
  end

  # Main entry point: import L1 block with transaction descriptors
  def import_l1_block(tx_descriptors, esip_overrides: {})
    # Convert descriptors to L1 transactions
    l1_transactions = tx_descriptors.map.with_index do |descriptor, index|
      build_l1_transaction(descriptor, index)
    end

    # Apply ESIP stubs before the import process
    esip_stubs = setup_esip_stubs(esip_overrides)

    begin
      # Import and return structured results
      results = import_l1_block_with_geth(l1_transactions)

      # Add mapping information for easier assertion
      results[:tx_descriptors] = tx_descriptors
      results[:mapping] = build_mapping(tx_descriptors, results)

      results
    ensure
      # Clean up stubs
      cleanup_esip_stubs(esip_stubs)
    end
  end

  # Helper: create ethscription and return its ID for use in transfers
  def create_ethscription_for_transfer(**params)
    results = expect_ethscription_creation_success([params])
    results[:ethscription_ids].first
  end

  private

  def setup_esip_stubs(overrides = {})
    # Default all ESIPs to enabled unless overridden
    defaults = {
      esip1_enabled: true,  # Event-based transfers
      esip2_enabled: true,  # Transfer for previous owner
      esip3_enabled: true,  # Event-based creation
      esip5_enabled: true,  # Multi-transfer input
      esip7_enabled: true   # GZIP compression
    }

    settings = defaults.merge(overrides)

    # Store original methods for cleanup
    original_methods = {}

    # Stub the SysConfig methods and store originals
    %w[esip1_enabled? esip2_enabled? esip3_enabled? esip5_enabled? esip7_enabled?].each do |method|
      original_methods[method] = SysConfig.method(method) if SysConfig.respond_to?(method)
    end

    allow(SysConfig).to receive(:esip1_enabled?).and_return(settings[:esip1_enabled])
    allow(SysConfig).to receive(:esip2_enabled?).and_return(settings[:esip2_enabled])
    allow(SysConfig).to receive(:esip3_enabled?).and_return(settings[:esip3_enabled])
    allow(SysConfig).to receive(:esip5_enabled?).and_return(settings[:esip5_enabled])
    allow(SysConfig).to receive(:esip7_enabled?).and_return(settings[:esip7_enabled])

    original_methods
  end

  def cleanup_esip_stubs(original_methods)
    # Restore original methods
    original_methods.each do |method_name, original_method|
      if original_method
        allow(SysConfig).to receive(method_name).and_call_original
      end
    end
  end

  def build_l1_transaction(descriptor, index)
    # binding.irb
    {
      transaction_hash: descriptor[:tx_hash] || generate_tx_hash(rand(1000000)),
      from_address: normalize_address(descriptor[:creator]),
      to_address: normalize_address(descriptor[:to]),
      input: normalize_to_hex(descriptor.fetch(:input)),
      value: 0,
      gas_used: descriptor[:gas_used] || 21000,
      transaction_index: index,
      logs: descriptor[:logs] || []
    }
  end

  def build_mapping(tx_descriptors, results)
    # Map each descriptor to its corresponding L2 transaction results
    tx_descriptors.map.with_index do |descriptor, index|
      l2_receipt = results[:l2_receipts][index]
      {
        descriptor: descriptor,
        l2_receipt: l2_receipt,
        success: l2_receipt && l2_receipt[:status] == '0x1'
      }
    end
  end

  # Assertion helpers for the new DSL
  def expect_ethscription_success(tx_spec, esip_overrides: {}, &block)
    results = import_l1_block([tx_spec], esip_overrides: esip_overrides)

    # Find the ethscription ID
    ethscription_id = results[:ethscription_ids].first
    expect(ethscription_id).to be_present, "Expected ethscription to be created"

    # Check L2 receipt status
    expect(results[:l2_receipts].first[:status]).to eq('0x1'), "L2 transaction should succeed"

    # Check contract storage
    stored = get_ethscription_content(ethscription_id)
    expect(stored).to be_present, "Ethscription should be stored in contract"

    yield results if block_given?
    results
  end

  def expect_ethscription_failure(tx_spec, reason: nil, esip_overrides: {})
    results = import_l1_block([tx_spec], esip_overrides: esip_overrides)

    case reason
    when :revert
      # L2 transaction fails
      expect(results[:l2_receipts].first[:status]).to eq('0x0'), "L2 transaction should revert"
      # expect(results[:ethscription_ids]).to be_empty, "No ethscriptions should be created on revert"
    when :ignored
      # Feature disabled or transaction ignored
      expect(results[:l2_receipts]).to be_empty, "No L2 transaction should be created when ignored"
      # expect(results[:ethscription_ids]).to be_empty, "No ethscriptions should be created when ignored"
    else
      # Default: expect failure
      raise "invalid reason"
    end

    results
  end

  # Assertion helper specifically for transfers
  def expect_transfer_success(tx_spec, ethscription_id, expected_new_owner, esip_overrides: {}, &block)
    # Get pre-transfer state
    pre_owner = get_ethscription_owner(ethscription_id)
    pre_content = get_ethscription_content(ethscription_id)

    results = import_l1_block([tx_spec], esip_overrides: esip_overrides)

    # Check L2 receipt status
    expect(results[:l2_receipts].first[:status]).to eq('0x1'), "L2 transaction should succeed"

    # Verify ownership changed
    new_owner = get_ethscription_owner(ethscription_id)
    expect(new_owner.downcase).to eq(expected_new_owner.downcase), "Ownership should change to #{expected_new_owner}"

    # Verify content unchanged
    current_content = get_ethscription_content(ethscription_id)
    expect(current_content[:content]).to eq(pre_content[:content]), "Content should remain unchanged"

    yield results if block_given?
    results
  end

  def expect_transfer_failure(tx_spec, ethscription_id, reason: :revert, esip_overrides: {}, &block)
    # Get pre-transfer state
    pre_owner = get_ethscription_owner(ethscription_id)
    pre_content = get_ethscription_content(ethscription_id)

    results = import_l1_block([tx_spec], esip_overrides: esip_overrides)

    case reason
    when :revert
      # L2 transaction fails
      expect(results[:l2_receipts].first[:status]).to eq('0x0'), "L2 transaction should revert"
    when :ignored
      # Feature disabled or transaction ignored
      expect(results[:l2_receipts]).to be_empty, "No L2 transaction should be created when ignored"
    end

    # Verify ownership and content unchanged
    current_owner = get_ethscription_owner(ethscription_id)
    expect(current_owner).to eq(pre_owner), "Ownership should remain unchanged on failure"

    current_content = get_ethscription_content(ethscription_id)
    expect(current_content[:content]).to eq(pre_content[:content]), "Content should remain unchanged"

    yield results if block_given?
    results
  end

  # Helper: create input-based transfer
  def create_input_transfer(ethscription_id, from:, to:)
    {
      creator: from,
      to: to,
      input: ethscription_id # 32-byte hash for single transfer
    }
  end

  # Helper: create event-based transfer (ESIP-1)
  def create_event_transfer(ethscription_id, from:, to:)
    # ABI encode all topics properly
    encoded_to = Eth::Abi.encode(['address'], [to])
    encoded_id = Eth::Abi.encode(['bytes32'], [ByteString.from_hex(ethscription_id).to_bin])

    {
      creator: from,
      logs: [
        {
          'address' => from,
          'topics' => [
            EthTransaction::Esip1EventSig,
            "0x#{encoded_to.unpack1('H*')}",
            "0x#{encoded_id.unpack1('H*')}"
          ],
          'data' => '0x',
          'logIndex' => '0x0',
          'removed' => false
        }
      ]
    }
  end

  # Helper: create event-based transfer with previous owner (ESIP-2)
  def create_esip2_transfer(ethscription_id, from:, to:, previous_owner:)
    # ABI encode all topics properly
    encoded_to = Eth::Abi.encode(['address'], [to])
    encoded_previous = Eth::Abi.encode(['address'], [previous_owner])
    encoded_id = Eth::Abi.encode(['bytes32'], [ByteString.from_hex(ethscription_id).to_bin])

    {
      creator: from,
      logs: [
        {
          'address' => from,
          'topics' => [
            EthTransaction::Esip2EventSig,
            "0x#{encoded_previous.unpack1('H*')}",
            "0x#{encoded_to.unpack1('H*')}",
            "0x#{encoded_id.unpack1('H*')}"
          ],
          'data' => '0x',
          'logIndex' => '0x0',
          'removed' => false
        }
      ]
    }
  end

  # Helper: create ethscription via event (ESIP-3)
  def create_ethscription_via_event(creator:, initial_owner:, content:)
    # ABI encode the content properly for the CreateEthscription event
    encoded_data = Eth::Abi.encode(['string'], [content])
    # ABI encode the initial_owner address for the topic
    encoded_owner_topic = Eth::Abi.encode(['address'], [initial_owner])

    {
      creator: creator,
      to: initial_owner,  # Event-based transactions still need a to_address
      input: "0x",       # Empty input for event-only transactions
      logs: [
        {
          'address' => creator,
          'topics' => [
            EthTransaction::CreateEthscriptionEventSig,
            "0x#{encoded_owner_topic.unpack1('H*')}"
          ],
          'data' => "0x#{encoded_data.unpack1('H*')}",
          'logIndex' => '0x0',
          'removed' => false
        }
      ]
    }
  end

  private

  def import_l1_block_with_geth(l1_transactions)
    # Get current importer state
    importer = ImporterSingleton.instance
    current_max_eth_block = importer.current_max_eth_block
    block_number = current_max_eth_block.number + 1

    # Create mock L1 block data
    block_data = build_mock_l1_block(l1_transactions, current_max_eth_block)
    receipts_data = l1_transactions.map { |tx| build_mock_receipt(tx) }

    # Rebuild the EthscriptionTransaction objects exactly the way the importer does
    eth_block = EthBlock.from_rpc_result(block_data)
    template_ethscriptions_block = EthscriptionsBlock.from_eth_block(eth_block)

    ethscription_transactions = EthTransaction.ethscription_txs_from_rpc_results(
      block_data,
      receipts_data,
      template_ethscriptions_block
    )
    ethscription_transactions.each { |tx| tx.ethscriptions_block = template_ethscriptions_block }

    mock_ethereum_client = instance_double(EthRpcClient,
      get_block_number: block_number,
      get_block: block_data,
      get_transaction_receipts: receipts_data
    )

    # Mock the prefetcher to return our mock data in the correct format
    eth_block = EthBlock.from_rpc_result(block_data)
    ethscriptions_block = EthscriptionsBlock.from_eth_block(eth_block)

    mock_prefetcher_response = {
      error: nil,
      eth_block: eth_block,
      ethscriptions_block: ethscriptions_block,
      ethscription_txs: ethscription_transactions
    }

    mock_prefetcher = instance_double(L1RpcPrefetcher)
    allow(mock_prefetcher).to receive(:fetch).with(block_number).and_return(mock_prefetcher_response)
    allow(mock_prefetcher).to receive(:ensure_prefetched)
    allow(mock_prefetcher).to receive(:clear_older_than)

    # Replace both client and prefetcher with mocks
    old_client = importer.ethereum_client
    old_prefetcher = importer.prefetcher

    importer.ethereum_client = mock_ethereum_client
    importer.instance_variable_set(:@prefetcher, mock_prefetcher)

    l2_blocks, eth_blocks = importer.import_next_block

    # Get the latest L2 block that was created
    latest_l2_block = EthRpcClient.l2.get_block("latest", true)

    # Get L2 transaction receipts for verification (excluding system/L1 attributes transactions)
    l2_transactions = latest_l2_block ? latest_l2_block['transactions'] || [] : []
    l2_receipts = l2_transactions
      .reject { |l2_tx| l2_tx['from']&.downcase == SysConfig::SYSTEM_ADDRESS.to_hex.downcase }  # Exclude system transactions
      .map do |l2_tx|
        receipt = EthRpcClient.l2.get_transaction_receipt(l2_tx['hash'])
        {
          tx_hash: l2_tx['hash'],
          status: receipt['status'],
          gas_used: receipt['gasUsed'],
          logs: receipt['logs']
        }
      end
    
    # Return all ethscription transactions (both successful and failed)
    imported_ethscriptions = ethscription_transactions
    ethscription_ids = imported_ethscriptions.flat_map do |tx|
      case tx.ethscription_operation
      when :create
        [tx.eth_transaction.tx_hash.to_hex]
      when :transfer
        if tx.transfer_ids.present?
          tx.transfer_ids  # Multi-transfer
        else
          [tx.ethscription_id]  # Single transfer
        end
      else
        [tx.eth_transaction.tx_hash.to_hex]  # Fallback
      end
    end.compact.uniq

    {
      l2_blocks: l2_blocks,
      eth_blocks: eth_blocks,
      ethscriptions: imported_ethscriptions,
      ethscription_ids: ethscription_ids,
      l1_transactions: l1_transactions,
      l2_receipts: l2_receipts,
      l2_block_data: latest_l2_block
    }
  ensure
    importer.ethereum_client = old_client
    importer.prefetcher = old_prefetcher
  end

  def build_mock_l1_block(l1_transactions, current_max_eth_block)
    block_number = current_max_eth_block.number + 1
    next_timestamp = current_max_eth_block.timestamp + 12

    {
      'number' => "0x#{block_number.to_s(16)}",
      'hash' => generate_block_hash(block_number),
      'parentHash' => current_max_eth_block.block_hash.to_hex,
      'timestamp' => "0x#{next_timestamp.to_s(16)}",
      'baseFeePerGas' => "0x#{1.gwei.to_s(16)}",
      'mixHash' => generate_block_hash(block_number + 1000),
      'transactions' => l1_transactions.map { |tx| format_transaction_for_rpc(tx) }
    }
  end

  def build_mock_receipt(tx)
    {
      'transactionHash' => tx[:transaction_hash],
      'transactionIndex' => tx[:transaction_index],
      'status' => tx[:status] || '0x1',
      'gasUsed' => "0x#{tx[:gas_used].to_s(16)}",
      'logs' => tx[:logs] || []  # Include logs from the original transaction
    }
  end

  def format_transaction_for_rpc(tx)
    {
      'hash' => tx[:transaction_hash],
      'transactionIndex' => "0x#{tx[:transaction_index].to_s(16)}",
      'from' => tx[:from_address],
      'to' => tx[:to_address],
      'input' => tx[:input],
      'value' => "0x#{tx[:value].to_s(16)}"
    }
  end

  def format_receipt_for_rpc(tx)
    {
      'transactionHash' => tx[:transaction_hash],
      'transactionIndex' => tx[:transaction_index],
      'status' => '0x1',
      'gasUsed' => "0x#{tx[:gas_used].to_s(16)}",
      'logs' => []
    }
  end

  def generate_tx_hash(index)
    "0x#{Digest::SHA256.hexdigest("tx_hash_#{index}").first(64)}"
  end

  def generate_address(index)
    "0x#{Digest::SHA256.hexdigest("addr_#{index}")[0..39]}"
  end

  def generate_block_hash(block_number)
    "0x#{Digest::SHA256.hexdigest("block_#{block_number}")}"
  end

  def combine_transaction_data(receipt, tx_data)
    combined = receipt.merge(tx_data) do |key, receipt_val, tx_val|
      if receipt_val != tx_val
        [receipt_val, tx_val]
      else
        receipt_val
      end
    end

    # Convert hex strings to integers where appropriate
    %w[blockNumber gasUsed cumulativeGasUsed effectiveGasPrice status transactionIndex nonce value gas depositNonce mint depositReceiptVersion gasPrice].each do |key|
      combined[key] = combined[key].to_i(16) if combined[key].is_a?(String) && combined[key].start_with?('0x')
    end

    # Remove duplicate keys with different casing
    combined.delete('transactionHash')  # Keep 'transactionHash' instead

    obj = OpenStruct.new(combined)

    def obj.method_missing(method, *args, &block)
      if respond_to?(method.to_s.camelize(:lower))
        send(method.to_s.camelize(:lower), *args, &block)
      else
        super
      end
    end

    obj
  end
end

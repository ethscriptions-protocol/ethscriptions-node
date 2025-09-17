class BlockValidator
  attr_reader :errors, :warnings, :stats

  def initialize
    @errors = []
    @warnings = []
    @stats = {}
    @storage_checks_performed = 0
  end

  def validate_l1_block(l1_block_number, l2_block_hashes)
    reset_validation_state

    Rails.logger.info "Validating L1 block #{l1_block_number} with #{l2_block_hashes.size} L2 blocks"

    # Fetch reference data from API
    expected = fetch_expected_data(l1_block_number)

    # Get actual data from L2 events
    actual_events = aggregate_l2_events(l2_block_hashes)

    # Historical block tag for reads as-of this L1 block’s L2 application
    # Use EIP-1898 with blockHash for reorg-safety
    historical_block_tag = l2_block_hashes.any? ? { blockHash: l2_block_hashes.last } : 'latest'

    # Compare events
    compare_events(expected, actual_events, l1_block_number)

    # Verify storage state
    verify_storage_state(expected, l1_block_number, historical_block_tag)

    # Build result
    ValidationResult.new(
      success: @errors.empty?,
      errors: @errors,
      warnings: @warnings,
      l1_block: l1_block_number,
      stats: {
        expected_creations: expected[:creations].size,
        actual_creations: actual_events[:creations].size,
        expected_transfers: expected[:transfers].size,
        actual_transfers: actual_events[:transfers].size,
        storage_checks: @storage_checks_performed,
        errors_count: @errors.size,
        warnings_count: @warnings.size
      }
    )
  end

  private

  def reset_validation_state
    @errors = []
    @warnings = []
    @storage_checks_performed = 0
  end

  def load_genesis_transaction_hashes
    # Load genesis ethscriptions from the JSON file
    genesis_file = Rails.root.join('contracts', 'script', 'genesisEthscriptions.json')
    genesis_data = JSON.parse(File.read(genesis_file))

    # Extract all transaction hashes from the ethscriptions array
    genesis_data['ethscriptions'].map { |e| e['transaction_hash'] }
  rescue => e
    Rails.logger.warn "Failed to load genesis ethscriptions: #{e.message}"
    []
  end

  def fetch_expected_data(l1_block_number)
    EthscriptionsApiClient.fetch_block_data(l1_block_number)
  rescue => e
    @warnings << "Failed to fetch API data: #{e.message}"
    {creations: [], transfers: []}
  end

  def aggregate_l2_events(block_hashes)
    all_creations = []
    all_transfers = []
    all_protocol_transfers = []

    block_hashes.each do |block_hash|
      begin
        receipts = EthRpcClient.l2.call('eth_getBlockReceipts', [block_hash])
        next unless receipts

        data = EventDecoder.decode_block_receipts(receipts)
        all_creations.concat(data[:creations])
        all_transfers.concat(data[:transfers])  # ERC-721 transfers
        all_protocol_transfers.concat(data[:protocol_transfers])  # Ethscriptions protocol transfers
      rescue => e
        @warnings << "Failed to get receipts for block #{block_hash}: #{e.message}"
        binding.irb
        raise
      end
    end

    {
      creations: all_creations.sort_by { |c| c[:tx_hash] },
      transfers: all_transfers.sort_by { |t| [t[:token_id], t[:from], t[:to]] },
      protocol_transfers: all_protocol_transfers.sort_by { |t| [t[:token_id], t[:from], t[:to]] }
    }
  end

  def compare_events(expected, actual, l1_block_num)
    # Calculate the L1 block where L2 block 1 happened (genesis + 1)
    l2_block_1_l1_block = Integer(ENV.fetch("L1_GENESIS_BLOCK")) + 1

    # Special handling for the L1 block where L2 block 1 happened - genesis events are emitted then
    if l1_block_num == l2_block_1_l1_block
      genesis_hashes = load_genesis_transaction_hashes
      Rails.logger.info "L1 Block #{l1_block_num} (L2 block 1): Expecting #{genesis_hashes.size} genesis events in addition to regular events"

      # Add genesis hashes to expected creations for this block
      expected_creation_hashes = (expected[:creations].map { |c| c[:tx_hash].downcase } + genesis_hashes.map(&:downcase)).to_set

      # Also expect transfers for genesis ethscriptions
      # These will be EthscriptionTransferred events from creator to initial owner
      # We'll validate them separately since we don't have full transfer data
    else
      expected_creation_hashes = expected[:creations].map { |c| c[:tx_hash].downcase }.to_set
    end

    actual_creation_hashes = actual[:creations].map { |c| c[:tx_hash].downcase }.to_set

    # Find missing creations
    missing = expected_creation_hashes - actual_creation_hashes
    missing.each do |tx_hash|
      @errors << "Missing creation event: #{tx_hash} in L1 block #{l1_block_num}"
    end

    # Find unexpected creations (but don't warn about genesis events in the L1 block for L2 block 1)
    unexpected = actual_creation_hashes - expected_creation_hashes
    if l1_block_num != l2_block_1_l1_block
      unexpected.each do |tx_hash|
        @warnings << "Unexpected creation event: #{tx_hash} in L1 block #{l1_block_num}"
      end
    end

    # Compare creation details for matching transactions
    expected[:creations].each do |exp_creation|
      act_creation = actual[:creations].find { |a|
        a[:tx_hash]&.downcase == exp_creation[:tx_hash]&.downcase
      }

      next unless act_creation

      if !addresses_match?(exp_creation[:creator], act_creation[:creator])
        @errors << "Creator mismatch for #{exp_creation[:tx_hash]}: expected #{exp_creation[:creator]}, got #{act_creation[:creator]}"
      end

      if !addresses_match?(exp_creation[:initial_owner], act_creation[:initial_owner])
        @errors << "Initial owner mismatch for #{exp_creation[:tx_hash]}: expected #{exp_creation[:initial_owner]}, got #{act_creation[:initial_owner]}"
      end
    end

    # Use protocol transfers for validation (they match Ethscriptions semantics)
    # These have the correct 'from' address (creator/owner, not address(0))
    compare_transfers(expected[:transfers], actual[:protocol_transfers], l1_block_num)
  end

  def compare_transfers(expected, actual, l1_block_num)
    # Calculate the L1 block where L2 block 1 happened
    l2_block_1_l1_block = Integer(ENV.fetch("L1_GENESIS_BLOCK")) + 1

    # Group transfers by token_id for easier comparison
    expected_by_token = expected.group_by { |t| t[:token_id]&.downcase }
    actual_by_token = actual.group_by { |t| t[:token_id]&.downcase }

    # Check for missing transfers
    (expected_by_token.keys - actual_by_token.keys).each do |token_id|
      @errors << "Missing transfer events for token #{token_id} in L1 block #{l1_block_num}"
    end

    # Check for unexpected transfers (but be lenient for the L1 block where L2 block 1 happened due to genesis events)
    if l1_block_num == l2_block_1_l1_block
      # For the L1 block where L2 block 1 happened, we expect genesis transfer events that won't be in the API data
      # Just log them as info instead of warnings
      (actual_by_token.keys - expected_by_token.keys).each do |token_id|
        Rails.logger.info "Genesis transfer event for token #{token_id} (expected for L2 block 1)"
      end
    else
      (actual_by_token.keys - expected_by_token.keys).each do |token_id|
        @warnings << "Unexpected transfer events for token #{token_id}"
      end
    end

    # Compare transfer details
    expected_by_token.each do |token_id, exp_transfers|
      act_transfers = actual_by_token[token_id] || []

      if exp_transfers.size != act_transfers.size
        @errors << "Transfer count mismatch for token #{token_id}: expected #{exp_transfers.size}, got #{act_transfers.size}"
        next
      end

      # Compare each transfer
      exp_transfers.each_with_index do |exp_transfer, i|
        act_transfer = act_transfers[i]
        next unless act_transfer

        # Now using protocol transfers which have correct semantics
        # No special case needed - 'from' should match directly
        if !addresses_match?(exp_transfer[:from], act_transfer[:from])
          @errors << "Transfer 'from' mismatch for token #{token_id}: expected #{exp_transfer[:from]}, got #{act_transfer[:from]}"
        end

        if !addresses_match?(exp_transfer[:to], act_transfer[:to])
          @errors << "Transfer 'to' mismatch for token #{token_id}: expected #{exp_transfer[:to]}, got #{act_transfer[:to]}"
        end
      end
    end
  end

  def verify_storage_state(expected_data, l1_block_num, block_tag)
    # Verify each created ethscription exists in storage with correct data
    expected_data[:creations].each do |creation|
      verify_ethscription_storage(creation, l1_block_num, block_tag)
    end

    # Verify ownership after transfers
    verify_transfer_ownership(expected_data[:transfers], block_tag)
  end

  def verify_ethscription_storage(creation, l1_block_num, block_tag)
    tx_hash = creation[:tx_hash]

    # Use get_ethscription_with_content to fetch both metadata and content
    stored = StorageReader.get_ethscription_with_content(tx_hash, block_tag: block_tag)
    @storage_checks_performed += 1

    if stored.nil?
      @errors << "Ethscription #{tx_hash} not found in contract storage"
      return
    end

    # Verify creator
    if !addresses_match?(stored[:creator], creation[:creator])
      @errors << "Storage creator mismatch for #{tx_hash}: stored=#{stored[:creator]}, expected=#{creation[:creator]}"
    end

    # Verify initial owner
    if !addresses_match?(stored[:initial_owner], creation[:initial_owner])
      @errors << "Storage initial_owner mismatch for #{tx_hash}: stored=#{stored[:initial_owner]}, expected=#{creation[:initial_owner]}"
    end

    # Verify L1 block number
    if stored[:l1_block_number] != l1_block_num
      @errors << "Storage L1 block mismatch for #{tx_hash}: stored=#{stored[:l1_block_number]}, expected=#{l1_block_num}"
    end

    # Verify content - compare the actual content bytes
    if creation[:content]
      # API provides decoded content, contract provides raw bytes
      if stored[:content] != creation[:content]
        @errors << "Storage content mismatch for #{tx_hash}: stored length=#{stored[:content]&.length}, expected length=#{creation[:content]&.length}"
      end
    elsif creation[:b64_content]
      # If we only have b64_content, decode it and compare
      expected_content = Base64.decode64(creation[:b64_content])
      if stored[:content] != expected_content
        @errors << "Storage content mismatch for #{tx_hash}: stored length=#{stored[:content]&.length}, expected length=#{expected_content&.length}"
      end
    end

    # Verify content_uri_hash - this is the hash of the original content URI
    stored_uri_hash = stored[:content_uri_hash]&.downcase&.delete_prefix('0x')
    if creation[:content_uri]
      # Hash the content_uri from the API to compare
      expected_uri_hash = Digest::SHA256.hexdigest(creation[:content_uri]).downcase
      if stored_uri_hash != expected_uri_hash
        @errors << "Storage content_uri_hash mismatch for #{tx_hash}: stored=#{stored_uri_hash}, expected=#{expected_uri_hash}"
      end
    end

    # Verify content_sha - always present in API, must match exactly
    stored_sha = stored[:content_sha]&.downcase&.delete_prefix('0x')
    expected_sha = creation[:content_sha].downcase.delete_prefix('0x')
    if stored_sha != expected_sha
      @errors << "Storage content_sha mismatch for #{tx_hash}: stored=#{stored[:content_sha]}, expected=#{creation[:content_sha]}"
    end

    # Verify mimetype - normalize to binary for comparison (Eth::Abi returns binary for non-ASCII)
    if stored[:mimetype].b != creation[:mimetype].b
      @errors << "Storage mimetype mismatch for #{tx_hash}: stored=#{stored[:mimetype]}, expected=#{creation[:mimetype]}"
    end

    # Verify media_type - normalize to binary for comparison
    if stored[:media_type].b != creation[:media_type].b
      @errors << "Storage media_type mismatch for #{tx_hash}: stored=#{stored[:media_type]}, expected=#{creation[:media_type]}"
    end

    # Verify mime_subtype - normalize to binary for comparison
    if stored[:mime_subtype].b != creation[:mime_subtype].b
      @errors << "Storage mime_subtype mismatch for #{tx_hash}: stored=#{stored[:mime_subtype]}, expected=#{creation[:mime_subtype]}"
    end

    # Verify esip6 flag - must match exactly (API returns boolean)
    if stored[:esip6] != creation[:esip6]
      @errors << "Storage esip6 mismatch for #{tx_hash}: stored=#{stored[:esip6]}, expected=#{creation[:esip6]}"
    end
  end

  def verify_transfer_ownership(transfers, block_tag)
    # Group transfers by token to get final owner
    final_owners = {}

    transfers.each do |transfer|
      token_id = transfer[:token_id]
      final_owners[token_id] = transfer[:to]
    end

    # Verify each token's final owner
    final_owners.each do |token_id, expected_owner|
      # First check if the ethscription exists in storage
      ethscription = StorageReader.get_ethscription(token_id, block_tag: block_tag)

      if ethscription.nil?
        # Token doesn't exist yet - this is expected if it hasn't been created
        # Only warn if we're checking a transfer for a token that should exist
        @warnings << "Token #{token_id} not found in storage (may not be created yet)"
        next
      end

      actual_owner = StorageReader.get_owner(token_id, block_tag: block_tag)
      @storage_checks_performed += 1

      if actual_owner.nil?
        binding.irb
        @warnings << "Could not verify owner of token #{token_id}"
        next
      end

      if !addresses_match?(actual_owner, expected_owner)
        @errors << "Ownership mismatch for token #{token_id}: stored=#{actual_owner}, expected=#{expected_owner}"
      end
    end
  end

  def addresses_match?(addr1, addr2)
    return false if addr1.nil? || addr2.nil?
    addr1.downcase == addr2.downcase
  end
end

class ValidationResult
  attr_reader :success, :errors, :warnings, :l1_block, :stats

  def initialize(success:, errors:, warnings:, l1_block:, stats:)
    @success = success
    @errors = errors
    @warnings = warnings
    @l1_block = l1_block
    @stats = stats
  end

  def log_summary(logger = Rails.logger)
    if success
      if stats[:actual_creations].to_i > 0 || stats[:actual_transfers].to_i > 0 || stats[:storage_checks].to_i > 0
        logger.info "✅ Block #{l1_block} validated successfully: " \
                    "#{stats[:actual_creations]} creations, " \
                    "#{stats[:actual_transfers]} transfers, " \
                    "#{stats[:storage_checks]} storage checks"
      end
    else
      logger.error "❌ Block #{l1_block} validation failed with #{errors.size} errors:"
      errors.first(5).each { |e| logger.error "  - #{e}" }
      logger.error "  ... and #{errors.size - 5} more errors" if errors.size > 5
      binding.irb
      raise "Validation failed"
      exit 1
    end

    if warnings.any?
      logger.warn "⚠️  Block #{l1_block} has #{warnings.size} warnings:"
      warnings.first(3).each { |w| logger.warn "  - #{w}" }
      binding.irb
      raise "Validation failed"
      exit 1
    end
  end

  def to_h
    {
      success: success,
      l1_block: l1_block,
      errors: errors,
      warnings: warnings,
      stats: stats
    }
  end
end

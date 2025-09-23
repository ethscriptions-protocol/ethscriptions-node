class EthBlockImporter
  include SysConfig
  include Memery
  
  # Raised when the next block to import is not yet available on L1
  class BlockNotReadyToImportError < StandardError; end
  # Raised when a re-org is detected (parent hash mismatch)
  class ReorgDetectedError < StandardError; end
  # Raised when validation failure is detected (should stop system permanently)
  class ValidationFailureError < StandardError; end
  
  attr_accessor :ethscriptions_block_cache, :ethereum_client, :eth_block_cache, :geth_driver, :prefetcher

  def initialize
    @ethscriptions_block_cache = {}
    @eth_block_cache = {}

    @ethereum_client ||= EthRpcClient.l1

    @geth_driver = GethDriver

    # L1 prefetcher for blocks/receipts/API data
    @prefetcher = L1RpcPrefetcher.new(
      ethereum_client: @ethereum_client,
      ahead: ENV.fetch('L1_PREFETCH_FORWARD', Rails.env.test? ? 5 : 20).to_i,
      threads: ENV.fetch('L1_PREFETCH_THREADS', Rails.env.test? ? 2 : 2).to_i
    )

    logger.info "EthBlockImporter initialized - Validation: #{ENV.fetch('VALIDATION_ENABLED').casecmp?('true') ? 'ENABLED' : 'disabled'}"

    MemeryExtensions.clear_all_caches!

    set_eth_block_starting_points
    populate_ethscriptions_block_cache

    # Clean up any stale validation records ahead of our starting position
    if ENV.fetch('VALIDATION_ENABLED').casecmp?('true')
      cleanup_stale_validation_records
    end

    unless Rails.env.test?
      max_block = current_max_eth_block_number
      if max_block && max_block > 0
        ImportProfiler.start('prefetch_warmup')
        @prefetcher.ensure_prefetched(max_block + 1)
        ImportProfiler.stop('prefetch_warmup')
      end
    end
  end
  
  def current_max_ethscriptions_block_number
    ethscriptions_block_cache.keys.max
  end
  
  def current_max_eth_block_number
    eth_block_cache.keys.max
  end
  
  def current_max_eth_block
    eth_block_cache[current_max_eth_block_number]
  end
  
  def populate_ethscriptions_block_cache
    epochs_found = 0
    current_block_number = current_max_ethscriptions_block_number - 1
    
    while epochs_found < 64 && current_block_number >= 0
      hex_block_number = "0x#{current_block_number.to_s(16)}"
      ImportProfiler.start("l2_block_fetch")
      block_data = geth_driver.client.call("eth_getBlockByNumber", [hex_block_number, false])
      ImportProfiler.stop("l2_block_fetch")
      current_block = EthscriptionsBlock.from_rpc_result(block_data)

      ImportProfiler.start("l1_attributes_fetch")
      l1_attributes = GethDriver.client.get_l1_attributes(current_block.number)
      ImportProfiler.stop("l1_attributes_fetch")
      current_block.assign_l1_attributes(l1_attributes)
      
      ethscriptions_block_cache[current_block.number] = current_block

      if current_block.sequence_number == 0 || current_block_number == 0
        epochs_found += 1
        logger.info "Found epoch #{epochs_found} at block #{current_block_number}"
      end

      current_block_number -= 1
    end

    logger.info "Populated facet block cache with #{ethscriptions_block_cache.size} blocks from #{epochs_found} epochs"
  end
  
  def logger
    Rails.logger
  end
  
  def blocks_behind
    (current_block_number - next_block_to_import) + 1
  end
  
  def current_block_number
    ethereum_client.get_block_number
  end
  memoize :current_block_number, ttl: 12.seconds
  
  # Removed batch processing - now imports one block at a time
  
  def find_first_l2_block_in_epoch(l2_block_number_candidate)
    l1_attributes = GethDriver.client.get_l1_attributes(l2_block_number_candidate)
    
    if l1_attributes[:sequence_number] == 0
      return l2_block_number_candidate
    end
    
    return find_first_l2_block_in_epoch(l2_block_number_candidate - 1)
  end
  
  def set_eth_block_starting_points
    latest_l2_block = GethDriver.client.call("eth_getBlockByNumber", ["latest", false])
    latest_l2_block_number = latest_l2_block['number'].to_i(16)
    
    if latest_l2_block_number == 0
      l1_block = EthRpcClient.l1.get_block(SysConfig.l1_genesis_block_number)
      eth_block = EthBlock.from_rpc_result(l1_block)
      ethscriptions_block = EthscriptionsBlock.from_rpc_result(latest_l2_block)
      l1_attributes = GethDriver.client.get_l1_attributes(latest_l2_block_number)
      
      ethscriptions_block.assign_l1_attributes(l1_attributes)
      
      ethscriptions_block_cache[0] = ethscriptions_block
      eth_block_cache[eth_block.number] = eth_block
      
      return [eth_block.number, 0]
    end
    
    l1_attributes = GethDriver.client.get_l1_attributes(latest_l2_block_number)
    
    l1_candidate = l1_attributes[:number]
    l2_candidate = latest_l2_block_number
    
    max_iterations = 1000
    iterations = 0
    
    while iterations < max_iterations
      l2_candidate = find_first_l2_block_in_epoch(l2_candidate)
      
      l1_result = ethereum_client.get_block(l1_candidate)
      l1_hash = Hash32.from_hex(l1_result['hash'])
      
      l1_attributes = GethDriver.client.get_l1_attributes(l2_candidate)
      
      l2_block = GethDriver.client.call("eth_getBlockByNumber", ["0x#{l2_candidate.to_s(16)}", false])
      
      # Start from finalization block (use smaller offset for tests)
      retry_offset = Rails.env.test? ? 0 : 63
      blocks_behind = latest_l2_block_number - l2_candidate

      if l1_hash == l1_attributes[:hash] && l1_attributes[:number] == l1_candidate && blocks_behind >= retry_offset
        eth_block_cache[l1_candidate] = EthBlock.from_rpc_result(l1_result)

        ethscriptions_block = EthscriptionsBlock.from_rpc_result(l2_block)
        ethscriptions_block.assign_l1_attributes(l1_attributes)

        ethscriptions_block_cache[l2_candidate] = ethscriptions_block
        logger.info "Found matching block at #{l1_candidate}, #{blocks_behind} blocks behind (minimum #{retry_offset})"
        return [l1_candidate, l2_candidate]
      else
        if l1_hash == l1_attributes[:hash] && l1_attributes[:number] == l1_candidate
          logger.info "Block #{l2_candidate} matches but only #{blocks_behind} blocks behind (need #{retry_offset}), continuing back"
        else
          logger.info "Mismatch on block #{l2_candidate}: #{l1_hash.to_hex} != #{l1_attributes[:hash].to_hex}, decrementing"
        end

        l2_candidate -= 1
        l1_candidate -= 1
      end
      
      iterations += 1
    end
    
    raise "No starting block found after #{max_iterations} iterations"
  end
  
  def import_blocks_until_done
    MemeryExtensions.clear_all_caches!

    # Initialize stats tracking
    stats_start_time = Time.current
    stats_start_block = current_max_eth_block_number
    blocks_imported_count = 0
    total_gas_used = 0
    total_transactions = 0
    imported_l2_blocks = []

    # Track timing for recent batch calculations
    recent_batch_start_time = Time.current

    begin
      loop do
        # Check for validation failures before importing
        if validation_failure_detected?
          failed_block = get_validation_failure_block
          logger.error "Import stopped due to validation failure at block #{failed_block}"
          raise ValidationFailureError.new("Validation failure detected at block #{failed_block}")
        end

        block_number = next_block_to_import

        if block_number.nil?
          raise BlockNotReadyToImportError.new("Block not ready")
        end

        l2_blocks, l1_blocks = import_single_block(block_number)
        blocks_imported_count += 1

        # Collect stats from imported L2 blocks
        if l2_blocks.any?
          imported_l2_blocks.concat(l2_blocks)
          l2_blocks.each do |l2_block|
            total_gas_used += l2_block.gas_used if l2_block.gas_used
            total_transactions += l2_block.ethscription_transactions.length if l2_block.ethscription_transactions
          end
        end

        # Report stats every 25 blocks
        if blocks_imported_count % 25 == 0
          recent_batch_time = Time.current - recent_batch_start_time
          report_import_stats(
            blocks_imported_count: blocks_imported_count,
            stats_start_time: stats_start_time,
            stats_start_block: stats_start_block,
            total_gas_used: total_gas_used,
            total_transactions: total_transactions,
            imported_l2_blocks: imported_l2_blocks,
            recent_batch_time: recent_batch_time
          )
          # Reset recent batch timer
          recent_batch_start_time = Time.current
        end

      rescue ReorgDetectedError => e
        logger.error "Reorg detected: #{e.message}"
        raise e
      rescue => e
        logger.error "Import error: #{e.message}"
        raise e
      end
    end
  end
  
  def fetch_block_from_cache(block_number)
    block_number = [block_number, 0].max
    
    ethscriptions_block_cache.fetch(block_number)
  end
  
  def prune_caches
    eth_block_threshold = current_max_eth_block_number - 65
  
    # Remove old entries from eth_block_cache
    eth_block_cache.delete_if { |number, _| number < eth_block_threshold }
  
    # Find the oldest Ethereum block number we want to keep
    oldest_eth_block_to_keep = eth_block_cache.keys.min
  
    # Remove old entries from ethscriptions_block_cache based on Ethereum block number
    ethscriptions_block_cache.delete_if do |_, ethscriptions_block|
      ethscriptions_block.eth_block_number < oldest_eth_block_to_keep
    end

    # Clean up prefetcher cache
    if oldest_eth_block_to_keep
      @prefetcher.clear_older_than(oldest_eth_block_to_keep)
    end
  end
  
  def current_ethscriptions_block(type)
    case type
    when :head
      fetch_block_from_cache(current_max_ethscriptions_block_number)
    when :safe
      find_block_by_epoch_offset(32)
    when :finalized
      find_block_by_epoch_offset(64)
    else
      raise ArgumentError, "Invalid block type: #{type}"
    end
  end
    
  def find_block_by_epoch_offset(offset)
    current_eth_block_number = current_facet_head_block.eth_block_number
    target_eth_block_number = current_eth_block_number - (offset - 1)

    matching_block = ethscriptions_block_cache.values
      .select { |block| block.eth_block_number <= target_eth_block_number }
      .max_by(&:number)

    matching_block || oldest_known_ethscriptions_block
  end
  
  def oldest_known_ethscriptions_block
    ethscriptions_block_cache.values.min_by(&:number)
  end
  
  def current_facet_head_block
    current_ethscriptions_block(:head)
  end
  
  def current_facet_safe_block
    current_ethscriptions_block(:safe)
  end
  
  def current_facet_finalized_block
    current_ethscriptions_block(:finalized)
  end

  def import_single_block(block_number)
    ImportProfiler.start("import_single_block")

    # Removed noisy per-block logging
    start = Time.current

    # Fetch block data from prefetcher
    ImportProfiler.start("prefetch_fetch")
    response = @prefetcher.fetch(block_number)
    ImportProfiler.stop("prefetch_fetch")

    # Handle cancellation, fetch failure, or block not ready
    if response.nil?
      raise BlockNotReadyToImportError.new("Block #{block_number} fetch was cancelled or failed")
    end

    if response[:error] == :not_ready
      raise BlockNotReadyToImportError.new("Block #{block_number} not yet available on L1")
    end

    eth_block = response[:eth_block]
    ethscriptions_block = response[:ethscriptions_block]
    ethscription_txs = response[:ethscription_txs]

    ethscription_txs.each { |tx| tx.ethscriptions_block = ethscriptions_block }

    # Check for reorg by validating parent hash
    parent_eth_block = eth_block_cache[block_number - 1]
    if parent_eth_block && parent_eth_block.block_hash != eth_block.parent_hash
      logger.error "Reorg detected at block #{block_number}"
      raise ReorgDetectedError.new("Parent hash mismatch at block #{block_number}")
    end

    # Import the L2 block(s)
    ImportProfiler.start("propose_ethscriptions_block")
    imported_ethscriptions_blocks = propose_ethscriptions_block(
      ethscriptions_block: ethscriptions_block,
      ethscription_txs: ethscription_txs
    )
    ImportProfiler.stop("propose_ethscriptions_block")

    logger.debug "Block #{block_number}: Found #{ethscription_txs.length} ethscription txs, created #{imported_ethscriptions_blocks.length} L2 blocks"

    # Update caches
    imported_ethscriptions_blocks.each do |ethscriptions_block|
      ethscriptions_block_cache[ethscriptions_block.number] = ethscriptions_block
    end
    eth_block_cache[eth_block.number] = eth_block
    prune_caches

    # Queue validation job if validation is enabled
    if ENV.fetch('VALIDATION_ENABLED').casecmp?('true')
      l2_block_hashes = imported_ethscriptions_blocks.map { |block| block.block_hash.to_hex }
      ValidationJob.perform_later(block_number, l2_block_hashes)
    end

    # Removed noisy per-block timing logs

    ImportProfiler.stop("import_single_block")

    [imported_ethscriptions_blocks, [eth_block]]
  end
  
  # Legacy batch import method removed - use import_single_block instead
  
  def import_next_block
    block_number = next_block_to_import
    import_single_block(block_number)
  end
  
  def next_block_to_import
    next_blocks_to_import(1).first
  end
  
  def next_blocks_to_import(n)
    max_imported_block = current_max_eth_block_number
    
    start_block = max_imported_block + 1
    
    (start_block...(start_block + n)).to_a
  end
  
  def propose_ethscriptions_block(ethscriptions_block:, ethscription_txs:)
    geth_driver.propose_block(
      transactions: ethscription_txs,
      new_ethscriptions_block: ethscriptions_block,
      head_block: current_facet_head_block,
      safe_block: current_facet_safe_block,
      finalized_block: current_facet_finalized_block
    )
  end
  
  def geth_driver
    @geth_driver
  end

  def validation_failure_detected?
    # Only consider failures BEHIND current import position as critical
    current_position = current_max_eth_block_number
    ValidationResult.failed.where('l1_block <= ?', current_position).exists?
  end

  def get_validation_failure_block
    # Get the earliest failed block that's behind current import
    current_position = current_max_eth_block_number
    ValidationResult.failed.where('l1_block <= ?', current_position).order(:l1_block).first&.l1_block
  end

  def cleanup_stale_validation_records
    # Remove validation records AND pending jobs ahead of our starting position
    # These are from previous runs and may be stale due to reorgs
    starting_position = current_max_eth_block_number
    stale_count = ValidationResult.where('l1_block > ?', starting_position).count

    if stale_count > 0
      logger.info "Cleaning up #{stale_count} stale validation records ahead of block #{starting_position}"
      ValidationResult.where('l1_block > ?', starting_position).delete_all
    end

    # Cancel all pending validation jobs on startup (fresh start)
    pending_jobs = SolidQueue::Job.where(queue_name: 'validation', finished_at: nil)

    if pending_jobs.exists?
      cancelled_count = pending_jobs.count
      logger.info "Cancelling #{cancelled_count} pending validation jobs from previous run"
      pending_jobs.delete_all
    end
  end

  def report_import_stats(blocks_imported_count:, stats_start_time:, stats_start_block:,
                         total_gas_used:, total_transactions:, imported_l2_blocks:, recent_batch_time:)
    elapsed_time = Time.current - stats_start_time
    current_block = current_max_eth_block_number

    # Calculate cumulative metrics (entire session)
    cumulative_blocks_per_second = blocks_imported_count / elapsed_time
    cumulative_transactions_per_second = total_transactions / elapsed_time
    total_gas_millions = (total_gas_used / 1_000_000.0).round(2)
    cumulative_gas_per_second_millions = (total_gas_used / elapsed_time / 1_000_000.0).round(2)

    # Calculate recent batch metrics (last 25 blocks using actual timing)
    recent_l2_blocks = imported_l2_blocks.last(25)
    recent_gas = recent_l2_blocks.sum { |block| block.gas_used || 0 }
    recent_transactions = recent_l2_blocks.sum { |block| block.ethscription_transactions&.length || 0 }

    recent_blocks_per_second = 25 / recent_batch_time
    recent_transactions_per_second = recent_transactions / recent_batch_time
    recent_gas_millions = (recent_gas / 1_000_000.0).round(2)
    recent_gas_per_second_millions = (recent_gas / recent_batch_time / 1_000_000.0).round(2)

    # Build single comprehensive stats message
    stats_message = <<~MSG
      #{"=" * 70}
      📊 IMPORT STATS
      🏁 Blocks: #{stats_start_block + 1} → #{current_block} (#{blocks_imported_count} total)

      ⚡ Speed: #{recent_blocks_per_second.round(1)} bl/s (#{cumulative_blocks_per_second.round(1)} session)
      📝 Transactions: #{recent_transactions} (#{total_transactions} total) | #{recent_transactions_per_second.round(1)}/s (#{cumulative_transactions_per_second.round(1)}/s session)
      ⛽ Gas: #{recent_gas_millions}M (#{total_gas_millions}M total) | #{recent_gas_per_second_millions.round(1)}M/s (#{cumulative_gas_per_second_millions.round(1)}M/s session)
      ⏱️  Time: #{recent_batch_time.round(1)}s recent | #{elapsed_time.round(1)}s total session
    MSG

    # Add validation stats to message
    if ENV.fetch('VALIDATION_ENABLED').casecmp?('true')
      last_validated = ValidationResult.last_validated_block || 0
      validation_lag = current_block - last_validated
      validation_stats = ValidationResult.validation_stats(since: 1.hour.ago)

      lag_status = case validation_lag
      when 0..5 then "✅ CURRENT"
      when 6..25 then "⚠️  BEHIND"
      when 26..100 then "🟡 LAGGING"
      else "🔴 VERY BEHIND"
      end

      if validation_stats[:total] > 0
        validation_line = "🔍 VALIDATION: #{lag_status} (#{validation_lag} behind) | #{validation_stats[:passed]}/#{validation_stats[:total]} passed (#{validation_stats[:pass_rate]}%)"
      else
        validation_line = "🔍 VALIDATION: #{lag_status} (#{validation_lag} behind) | No validations completed yet"
      end
    else
      validation_line = "🔍 Validation: DISABLED"
    end

    # Add prefetcher stats if available
    if blocks_imported_count >= 10
      stats = @prefetcher.stats
      prefetcher_line = "🔄 Prefetcher: #{stats[:promises_fulfilled]}/#{stats[:promises_total]} fulfilled (#{stats[:threads_active]} active, #{stats[:threads_queued]} queued)"
    else
      prefetcher_line = ""
    end

    # Combine validation and prefetcher stats into main message
    stats_message += "\n#{validation_line}"
    stats_message += "\n#{prefetcher_line}" if prefetcher_line.present?
    stats_message += "\n#{"=" * 70}"

    # Output single message to reduce flicker
    logger.info stats_message
    
    if ImportProfiler.enabled?
      logger.info ""
      logger.info "🔍 DETAILED PROFILER STATS:"
      ImportProfiler.report
      ImportProfiler.reset
    end

    logger.info "=" * 70
  end

  public

  def validation_summary
    return nil unless ENV.fetch('VALIDATION_ENABLED').casecmp?('true')

    stats = ValidationResult.validation_stats(since: 1.hour.ago)
    return "No validations completed" if stats[:total] == 0

    "#{stats[:passed]}/#{stats[:total]} passed (#{stats[:pass_rate]}%), #{stats[:failed]} failed"
  end

  def shutdown
    @prefetcher&.shutdown
  end
end

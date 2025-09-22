class GapDetectionJob < ApplicationJob
  queue_as :gap_detection

  def perform
    return unless validation_enabled?

    Rails.logger.info "GapDetectionJob: Starting gap detection scan"

    # Get current import range
    import_range = get_import_range
    return unless import_range

    start_block, end_block = import_range

    # Find validation gaps
    gaps = ValidationResult.validation_gaps(start_block, end_block)

    if gaps.empty?
      Rails.logger.debug "GapDetectionJob: No validation gaps found in range #{start_block}..#{end_block}"
      return
    end

    Rails.logger.info "GapDetectionJob: Found #{gaps.length} validation gaps: #{gaps.first(5).join(', ')}#{gaps.length > 5 ? '...' : ''}"

    # Enqueue validation jobs for gaps
    gaps.each do |block_number|
      begin
        # Get L2 block data for this L1 block
        l2_blocks = get_l2_blocks_for_l1_block(block_number)

        if l2_blocks.any?
          l2_block_hashes = l2_blocks.map { |block| block[:hash] }
          ValidationJob.perform_later(block_number, l2_block_hashes)
          Rails.logger.debug "GapDetectionJob: Enqueued validation for block #{block_number}"
        else
          Rails.logger.warn "GapDetectionJob: No L2 blocks found for L1 block #{block_number}"
        end
      rescue => e
        Rails.logger.error "GapDetectionJob: Failed to enqueue validation for block #{block_number}: #{e.message}"
      end
    end

    Rails.logger.info "GapDetectionJob: Enqueued #{gaps.length} validation jobs for gaps"
  end

  private

  def validation_enabled?
    ENV.fetch('VALIDATION_ENABLED', 'false').casecmp?('true')
  end

  def get_import_range
    begin
      # Get the range of blocks we should have validation for
      # Use the current L2 blockchain state to determine what's been imported
      latest_l2_block = GethDriver.client.call("eth_getBlockByNumber", ["latest", false])
      return nil if latest_l2_block.nil?

      latest_l2_block_number = latest_l2_block['number'].to_i(16)
      return nil if latest_l2_block_number == 0

      # Get L1 attributes to find the corresponding L1 block
      l1_attributes = GethDriver.client.get_l1_attributes(latest_l2_block_number)
      current_l1_block = l1_attributes[:number]

      # Check the last validated block
      last_validated = ValidationResult.last_validated_block || 0

      # We should validate from the oldest reasonable point to current
      # Don't go back more than 1000 blocks to avoid overwhelming the system
      start_block = [last_validated - 100, current_l1_block - 1000].max

      [start_block, current_l1_block]
    rescue => e
      Rails.logger.error "GapDetectionJob: Failed to determine import range: #{e.message}"
      nil
    end
  end

  def get_l2_blocks_for_l1_block(l1_block_number)
    # Query Geth to find L2 blocks that were created from this L1 block
    # This is complex - we need to scan L2 blocks and check their L1 attributes
    begin
      l2_blocks = []

      # Get current L2 tip to know the range to search
      latest_l2_block = GethDriver.client.call("eth_getBlockByNumber", ["latest", false])
      return [] if latest_l2_block.nil?

      latest_l2_block_number = latest_l2_block['number'].to_i(16)

      # Search backwards from current L2 tip to find blocks from this L1 block
      # This is expensive but necessary for gap filling
      (0..latest_l2_block_number).reverse_each do |l2_block_num|
        l1_attributes = GethDriver.client.get_l1_attributes(l2_block_num)

        if l1_attributes[:number] == l1_block_number
          l2_block = GethDriver.client.call("eth_getBlockByNumber", ["0x#{l2_block_num.to_s(16)}", false])
          l2_blocks << { number: l2_block_num, hash: l2_block['hash'] }
        elsif l1_attributes[:number] < l1_block_number
          # We've gone too far back
          break
        end
      end

      l2_blocks
    rescue => e
      Rails.logger.error "GapDetectionJob: Failed to get L2 blocks for L1 block #{l1_block_number}: #{e.message}"
      []
    end
  end
end
class ValidationResult < ApplicationRecord
  self.primary_key = 'l1_block'
  
  scope :successful, -> { where(success: true) }
  scope :failed, -> { where(success: false) }
  scope :recent, -> { order(validated_at: :desc) }
  scope :in_range, ->(start_block, end_block) { where(l1_block: start_block..end_block) }
  scope :with_activity, -> {
    where("JSON_EXTRACT(validation_stats, '$.validation_details.expected_creations') > 0 OR JSON_EXTRACT(validation_stats, '$.validation_details.expected_transfers') > 0 OR JSON_EXTRACT(validation_stats, '$.validation_details.storage_checks') > 0")
  }

  # Class methods for validation management
  def self.last_validated_block
    maximum(:l1_block)
  end

  def self.validation_gaps(start_block, end_block)
    # Use SQL recursive CTE to find gaps efficiently
    sql = <<~SQL
      WITH RECURSIVE expected(n) AS (
        SELECT ? AS n
        UNION ALL
        SELECT n + 1 FROM expected WHERE n < ?
      )
      SELECT n AS missing_block
      FROM expected
      LEFT JOIN validation_results vr ON vr.l1_block = expected.n
      WHERE vr.l1_block IS NULL
      ORDER BY n
    SQL

    connection.execute(sql, [start_block, end_block]).map { |row| row['missing_block'] }
  end

  def self.validation_stats(since: 1.hour.ago)
    results = where('validated_at >= ?', since)
    total = results.count
    passed = results.successful.count
    failed = results.failed.count

    {
      total: total,
      passed: passed,
      failed: failed,
      pass_rate: total > 0 ? (passed.to_f / total * 100).round(2) : 0
    }
  end

  def self.recent_failures(limit: 10)
    failed.recent.limit(limit)
  end

  # Class method to perform validation and save result
  def self.validate_and_save(l1_block_number, l2_block_hashes)
    Rails.logger.info "ValidationResult: Validating L1 block #{l1_block_number}"

    begin
      # Create validator and validate (validator fetches its own API data)
      validator = BlockValidator.new
      block_result = validator.validate_l1_block(l1_block_number, l2_block_hashes)

      # Store comprehensive validation result with full debugging data
      validation_result = create_or_find_by(l1_block: l1_block_number) do |vr|
        vr.success = block_result.success
        vr.error_details = block_result.errors
        vr.validation_stats = {
          # Basic stats
          success: block_result.success,
          l1_block: l1_block_number,
          l2_blocks: l2_block_hashes,
          validated_at: Time.current,

          # Detailed comparison data
          validation_details: block_result.stats,

          # Store the raw data for debugging
          raw_api_data: block_result.respond_to?(:api_data) ? block_result.api_data : nil,
          raw_l2_events: block_result.respond_to?(:l2_events) ? block_result.l2_events : nil,

          # Timing info
          validation_duration: Time.current - Time.current
        }
        vr.validated_at = Time.current
      end

      # Log the result
      validation_result.log_summary

      validation_result
    rescue => e
      Rails.logger.error "ValidationResult: Exception validating block #{l1_block_number}: #{e.message}"

      # Record the validation error
      error_result = create_or_find_by(l1_block: l1_block_number) do |vr|
        vr.success = false
        vr.error_details = [e.message]
        vr.validation_stats = { exception: true, exception_class: e.class.name }
        vr.validated_at = Time.current
      end

      error_result.log_summary
      raise e
    end
  end

  # Instance methods
  def failure_summary
    return nil if success?
    return "No error details" if error_details.blank?

    # error_details is automatically parsed as Array
    error_details.first(3).join('; ')
  end

  def log_summary(logger = Rails.logger)
    if success?
      stats_data = validation_stats || {}
      if stats_data['actual_creations'].to_i > 0 || stats_data['actual_transfers'].to_i > 0 || stats_data['storage_checks'].to_i > 0
        logger.info "✅ Block #{l1_block} validated successfully: " \
                    "#{stats_data['actual_creations']} creations, " \
                    "#{stats_data['actual_transfers']} transfers, " \
                    "#{stats_data['storage_checks']} storage checks"
      end
    else
      errors = error_details || []
      logger.error "❌ Block #{l1_block} validation failed with #{errors.size} errors:"
      errors.first(5).each { |e| logger.error "  - #{e}" }
      logger.error "  ... and #{errors.size - 5} more errors" if errors.size > 5
    end
  end
end

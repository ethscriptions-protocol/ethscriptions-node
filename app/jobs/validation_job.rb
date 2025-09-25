class ValidationJob < ApplicationJob
  queue_as :validation

  # Retry all errors - any exception means we couldn't validate, not that validation failed
  # StandardError catches all normal exceptions (network, RPC, API, etc.)
  retry_on StandardError,
           wait: ENV.fetch('VALIDATION_RETRY_WAIT_SECONDS', 5).to_i.seconds,
           attempts: ENV.fetch('VALIDATION_TRANSIENT_RETRIES', 1000).to_i

  def perform(l1_block_number, l2_block_hashes)
    start_time = Time.current

    # ValidationResult.validate_and_save will:
    # 1. Create ValidationResult with success: true (job succeeds)
    # 2. Create ValidationResult with success: false (job succeeds - real validation failure found)
    # 3. Raise any exception (job retries via retry_on StandardError)
    ValidationResult.validate_and_save(l1_block_number, l2_block_hashes)

    elapsed_time = Time.current - start_time
    Rails.logger.info "ValidationJob: Block #{l1_block_number} validation completed in #{elapsed_time.round(3)}s"
  rescue => e
    Rails.logger.error "ValidationJob failed for L1 #{l1_block_number}: #{e.class}: #{e.message}"
    raise
  end
end

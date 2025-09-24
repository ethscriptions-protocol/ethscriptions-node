class ValidationJob < ApplicationJob
  queue_as :validation

  # Import TransientValidationError from BlockValidator
  TransientValidationError = BlockValidator::TransientValidationError

  # Only retry transient errors, not all StandardError
  retry_on TransientValidationError,
           wait: ENV.fetch('VALIDATION_RETRY_WAIT_SECONDS', 5).to_i.seconds,
           attempts: ENV.fetch('VALIDATION_TRANSIENT_RETRIES', 5).to_i

  def perform(l1_block_number, l2_block_hashes)
    start_time = Time.current

    # ValidationResult.validate_and_save will:
    # 1. Create ValidationResult with success: true (job succeeds)
    # 2. Create ValidationResult with success: false (job succeeds - real validation failure found)
    # 3. Raise TransientValidationError (job retries via retry_on, then fails if exhausted)
    ValidationResult.validate_and_save(l1_block_number, l2_block_hashes)

    elapsed_time = Time.current - start_time
    Rails.logger.info "ValidationJob: Block #{l1_block_number} validation completed in #{elapsed_time.round(3)}s"

    # Job completes successfully for cases 1 & 2
    # TransientValidationError will be handled by retry_on automatically
  end
end

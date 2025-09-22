class ValidationJob < ApplicationJob
  queue_as :validation

  # Retry up to 3 times with fixed delays to avoid the exponentially_longer issue
  retry_on StandardError, wait: 5.seconds, attempts: 3

  def perform(l1_block_number, l2_block_hashes)
    start_time = Time.current

    begin
      # Use the unified ValidationResult model to validate and save
      validation_result = ValidationResult.validate_and_save(l1_block_number, l2_block_hashes)

      elapsed_time = Time.current - start_time
      Rails.logger.info "ValidationJob: Block #{l1_block_number} validation completed in #{elapsed_time.round(3)}s"

    rescue => e
      Rails.logger.error "ValidationJob: Validation failed for block #{l1_block_number}: #{e.message}"

      # Validation failure will be detected by import process via database query

      # Re-raise to trigger retry mechanism
      raise e
    end
  end
end
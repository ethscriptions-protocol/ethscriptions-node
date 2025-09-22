require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # In the development environment your application's code is reloaded any time
  # it changes. This slows down response time but is perfect for development
  # since you don't have to restart the web server when you make code changes.
  config.enable_reloading = true

  # Do not eager load code on boot.
  config.eager_load = true

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing
  config.server_timing = true
  
  # Enable file-based caching for persistent checkpoints
  config.action_controller.perform_caching = true
  config.cache_store = :file_store, Rails.root.join("tmp", "cache", "checkpoints")

  # Output logger to STDOUT for development
  config.logger = ActiveSupport::Logger.new(STDOUT)
  config.logger.formatter = Logger::Formatter.new
  config.log_level = :info

  # Reduce ActiveJob/SolidQueue log noise
  config.active_job.logger = Logger.new(STDOUT)
  config.active_job.logger.level = Logger::WARN
  config.solid_queue.logger = Logger.new(STDOUT)
  config.solid_queue.logger.level = Logger::WARN

  # Use Solid Queue in Development.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raise an error on page load if there are pending migrations.
  # config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  # config.active_record.verbose_query_logs = true

  # Highlight code that enqueued background job in logs.
  config.active_job.verbose_enqueue_logs = true

  # config.active_record.async_query_executor = :global_thread_pool

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions
  config.action_controller.raise_on_missing_callback_actions = true
end

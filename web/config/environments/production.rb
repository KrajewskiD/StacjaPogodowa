Rails.application.configure do
  config.eager_load = true
  config.enable_reloading = false
  config.consider_all_requests_local = false
  config.public_file_server.enabled = true
  config.log_level = :info
  config.log_tags = [:request_id]
  config.cache_store = :memory_store, { size: 32 * 1024 * 1024 }

  if ENV["RAILS_LOG_TO_STDOUT"] == "1"
    logger = ActiveSupport::Logger.new($stdout)
    logger.formatter = config.log_formatter
    config.logger = ActiveSupport::TaggedLogging.new(logger)
  end
end

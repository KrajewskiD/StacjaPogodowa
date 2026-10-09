Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.secret_key_base = "test-only-secret-" * 8
end

require_relative "boot"
require "ipaddr"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)

module StacjaPogodowa
  class Application < Rails::Application
    config.load_defaults 8.1
    config.time_zone = "Warsaw"
    config.active_record.default_timezone = :utc
    config.secret_key_base = ENV["SECRET_KEY_BASE"] || begin
      path = File.expand_path("secret.key", __dir__)
      File.read(path).strip if File.exist?(path)
    end
    config.hosts = ["localhost", "127.0.0.1", "::1", IPAddr.new("192.168.0.0/16"),
                    IPAddr.new("10.0.0.0/8"), IPAddr.new("172.16.0.0/12")]
    # Domeny publiczne (rozdzielone przecinkiem) — na VPS ustaw APP_HOSTS, inaczej
    # ActionDispatch::HostAuthorization zwróci 403 dla domeny.
    extra_hosts = ENV.fetch("APP_HOSTS", "").split(",").map(&:strip).reject(&:empty?)
    config.hosts += extra_hosts

    # Reverse proxy dopisuje realny adres klienta do X-Forwarded-For. Ufamy wyłącznie
    # jawnie podanym adresom (lokalnie pętla; w Dockerze podsieć wewnętrzna przez
    # TRUSTED_PROXIES), więc request.remote_ip zwraca prawdziwy adres, a spoofowany
    # nagłówek od klienta jest ignorowany. Kluczowe dla limitera HTTP.
    proxy_list = ENV.fetch("TRUSTED_PROXIES", "127.0.0.1/32,::1/128")
    config.action_dispatch.trusted_proxies = proxy_list.split(",").map(&:strip).reject(&:empty?).map { |cidr| IPAddr.new(cidr) }
  end
end

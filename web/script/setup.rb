require "fileutils"
require "securerandom"

Dir.chdir(File.expand_path("..", __dir__)) do
  %w[log tmp/pids storage].each { |dir| FileUtils.mkdir_p(dir) }
  unless File.exist?("config/secret.key")
    File.open("config/secret.key", File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.puts SecureRandom.hex(64)
    end
  end
  ENV["RAILS_ENV"] = "production"
  abort "Nie udalo sie przygotowac bazy" unless system("bundle", "exec", "ruby", "bin/rails", "db:prepare")
  abort "Bledna konfiguracja Apache" unless system("httpd", "-t", "-f", File.expand_path("config/apache.conf"))
end

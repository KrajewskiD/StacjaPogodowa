# Middleware nie jest w domyślnych ścieżkach autoload Zeitwerk (katalog app/middleware
# nie jest mapowany), więc ładujemy klasę jawnie, a następnie montujemy limiter.
require Rails.root.join("app/middleware/request_rate_limit").to_s

Rails.application.config.middleware.use RequestRateLimit unless Rails.env.test?
# Lekki limiter HTTP bez zewnętrznej zależności. Wystarcza dla jednego procesu
# Puma; przy skalowaniu na wiele procesów/instancji wymień na Rack::Attack z Redis
# (Redis jest już w tej aplikacji dostępny). Kluczuje po realnym adresie klienta.
class RequestRateLimit
  # ścieżka => [maks. żądań, okno w sekundach]
  LIMITS = {
    "/api/weather" => [120, 60],
    "/export.csv" => [30, 60],
    "/api/measurements" => [120, 60]
  }.freeze

  # Twardy limit rozmiaru mapy chroni przed niekontrolowanym wzrostem przy wielu
  # unikalnych adresach (spoofowane IP). Nadmiar jest usuwany najstarszymi wpisami.
  MAX_ENTRIES = 10_000
  PRUNE_EVERY = 1000

  def initialize(app)
    @app = app
    @hits = Hash.new { |hash, key| hash[key] = [] }
    @calls = 0
    @mutex = Mutex.new
  end

  def call(env)
    request = Rack::Request.new(env)
    limit, window = LIMITS[request.path]
    return @app.call(env) unless limit

    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    key = "#{client_ip(env)}:#{request.path}"

    limited = @mutex.synchronize do
      bucket = @hits[key]
      bucket.delete_if { |at| now - at > window }
      if bucket.size >= limit
        true
      else
        bucket << now
        @calls += 1
        prune!(now) if (@calls % PRUNE_EVERY).zero?
        false
      end
    end

    limited ? rate_limited_response(window) : @app.call(env)
  end

  private

  # Realny adres klienta: RemoteIp (działający przed tym middleware) zapisuje go
  # w env["action_dispatch.remote_ip"] z uwzględnieniem trusted_proxies. W testach
  # jednostkowych (bez RemoteIp) bezpieczny fallback to bezpośredni peer REMOTE_ADDR,
  # bez ufania X-Forwarded-For.
  def client_ip(env)
    env["action_dispatch.remote_ip"] || env["REMOTE_ADDR"]
  end

  def rate_limited_response(window)
    [429, { "Content-Type" => "text/plain; charset=utf-8", "Retry-After" => window.to_s },
     ["Zbyt wiele żądań. Spróbuj za chwilę."]]
  end

  def prune!(now)
    # Usuwa puste kubły (czysta po CGNAT/proxy) i twardo ogranicza liczbę wpisów.
    @hits.delete_if { |_key, bucket| bucket.empty? }
    return if @hits.size <= MAX_ENTRIES
    overflow = @hits.size - MAX_ENTRIES
    @hits.keys.first(overflow).each { |key| @hits.delete(key) }
  end
end
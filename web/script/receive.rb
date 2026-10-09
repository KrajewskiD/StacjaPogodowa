require "socket"

$stdout.sync = true
$stderr.sync = true
settings = StationSetting.current
socket = UDPSocket.new
socket.bind(ENV.fetch("UDP_BIND", "0.0.0.0"), Integer(ENV.fetch("UDP_PORT", "8680")))
puts "StacjaPogodowa: nasluch UDP #{socket.addr[1]}, zapis do #{Rails.env} PostgreSQL"
%w[INT TERM].each { |signal| Signal.trap(signal) { exit } }

# Prosta przepustnica na adres źródłowy: chroni parser i bazę przed zalewem,
# nawet zanim payload zostanie sprawdzony. Osobna weryfikacja czujnika/urządzenia
# odbywa się w Measurement.ingest! i Gateway.observe! (allowlista w station.yml).
rate_limits = Hash.new { |hash, key| hash[key] = [] }
MAX_MESSAGES_PER_MINUTE = 60
MAX_RATE_ENTRIES = 10_000

begin
  last_alert_check = 0
  loop do
    if IO.select([socket], nil, nil, 5)
      raw, sender = socket.recvfrom(8192)
      source = sender[3]
      monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      bucket = rate_limits[source]
      bucket.delete_if { |at| monotonic - at > 60 }
      if bucket.size >= MAX_MESSAGES_PER_MINUTE
        warn "Odrzucono zalew pakietow z #{source}"
        next
      end
      bucket << monotonic
      if raw.bytesize > IngestPolicy::MAX_PAYLOAD_BYTES
        warn "Pominieto pakiet z #{source}: przekroczony rozmiar"
        next
      end
      begin
        data = JSON.parse(raw)
        Measurement.transaction do
          measurement = Measurement.ingest!(data, source_ip: source)
          Gateway.observe!(data, source_ip: source)
          WeatherAlert.evaluate!(measurement, settings: settings) if measurement
          puts "#{measurement.received_at.iso8601} #{measurement.sensor_id} zapisano ##{measurement.id}" if measurement
        end
      rescue JSON::ParserError, ArgumentError, ActiveRecord::RecordInvalid => e
        warn "Pominieto pakiet z #{source}: #{e.message}"
      end
    end
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    if now - last_alert_check >= 5
      Measurement.where(id: Measurement.group(:sensor_id).select("MAX(id)")).each do |reading|
        WeatherAlert.evaluate!(reading, settings: settings)
      end
      ActiveRecord::Base.connection_pool.with_connection(&:clear_query_cache)
      # Porządkuje mapę limitów: usuwa puste kubły i twardo ogranicza rozmiar,
      # aby spoofowane adresy źródłowe nie rosły w nieskończoność.
      rate_limits.delete_if { |_ip, bucket| bucket.empty? }
      rate_limits.clear if rate_limits.size > MAX_RATE_ENTRIES
      last_alert_check = now
    end
  end
ensure
  socket.close
end
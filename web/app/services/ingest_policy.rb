# Polityka bezpieczeństwa przyjmowania pakietów. Źródłem jest station.yml.
# Puste listy oznaczają akceptację wszystkiego — tylko w testach i rozwoju.
# W produkcji listy są jawne, więc obcy czujnik/urządzenie nie trafi do bazy.
class IngestPolicy
  WEATHER_KEYS = %w[schema type sensor_id device_id sensor_type decoder
    channel seq uptime_ms battery_ok complete startup rssi_dbm
    temperature_c humidity_pct wind_avg_ms wind_gust_ms wind_direction_deg
    rain_total_mm uv_index light_klx].freeze

  STATUS_KEYS = %w[schema type device_id seq uptime_ms radio_ok radio_error
    frequency_mhz decoded_packets weather_age_s wifi_connected wifi_rssi_dbm].freeze

  MAX_PAYLOAD_BYTES = 4096
  MAX_KEYS = 40

  def self.config
    @config ||= Rails.application.config_for(:station)
  end

  def self.sensors
    Array(config[:sensors])
  end

  def self.devices
    Array(config[:devices])
  end

  def self.sensor_allowed?(id)
    sensors.empty? || sensors.map { |s| s.to_s.upcase }.include?(id.to_s.upcase)
  end

  def self.device_allowed?(id)
    devices.empty? || devices.map { |d| d.to_s.downcase }.include?(id.to_s.downcase)
  end

  def self.keys_for(type)
    type == "status" ? STATUS_KEYS : WEATHER_KEYS
  end

  # Zwraca symbole nieznanych pól albo pustą tablicę, gdy wszystkie są znane.
  def self.unknown_keys(data)
    return ["(brak obiektu)"] unless data.is_a?(Hash)
    allowed = keys_for(data["type"])
    data.keys.reject { |key| allowed.include?(key) }
  end

  def self.reset!
    @config = nil
  end
end
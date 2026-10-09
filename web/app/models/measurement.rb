class Measurement < ApplicationRecord
  METRICS = %w[temperature_c humidity_pct wind_avg_ms wind_gust_ms
               wind_direction_deg rain_total_mm uv_index light_klx rssi_dbm].freeze
  PUBLIC_METRICS = (METRICS - %w[rssi_dbm]).freeze

  validates :sensor_id, format: { with: /\A[0-9A-F]{8}\z/ }
  validates :device_id, :received_at, :payload, presence: true
  after_create { MeasurementDelivery.create!(measurement: self) }

  def self.ingest!(data, source_ip:)
    raise ArgumentError, "Niepoprawny schemat" unless data.is_a?(Hash) && data["schema"] == 1
    return nil if data["type"] == "status"
    raise ArgumentError, "Nieznany typ" unless data["type"] == "weather"
    raise ArgumentError, "Zbyt duży payload" if data.length > IngestPolicy::MAX_KEYS
    unknown = IngestPolicy.unknown_keys(data)
    raise ArgumentError, "Nieznane pola: #{unknown.join(", ")}" unless unknown.empty?
    raise ArgumentError, "Brak device_id" unless data["device_id"].is_a?(String) && data["device_id"].match?(/\A[0-9a-fA-F]{1,16}\z/)
    raise ArgumentError, "Niepoprawne ID czujnika" unless data["sensor_id"].is_a?(String) && data["sensor_id"].match?(/\A[0-9a-fA-F]{8}\z/)
    raise ArgumentError, "Nieznany czujnik" unless IngestPolicy.sensor_allowed?(data["sensor_id"])
    raise ArgumentError, "Nieznane urządzenie" unless IngestPolicy.device_allowed?(data["device_id"])
    METRICS.each do |key|
      next unless data.key?(key)
      value = data[key]
      raise ArgumentError, "Niepoprawny pomiar #{key}" unless value.is_a?(Numeric) && value.finite?
    end
    if data.key?("battery_ok") && ![true, false].include?(data["battery_ok"])
      raise ArgumentError, "Niepoprawny stan baterii"
    end
    %w[channel seq uptime_ms decoder].each do |key|
      next unless data.key?(key)
      raise ArgumentError, "Niepoprawne #{key}" unless data[key].is_a?(Integer) && data[key] >= 0
    end
    %w[complete startup].each do |key|
      next unless data.key?(key)
      raise ArgumentError, "Niepoprawne #{key}" unless [true, false].include?(data[key])
    end
    attributes = { sensor_id: data["sensor_id"].upcase, device_id: data["device_id"],
                   source_ip: source_ip, received_at: Time.current, payload: data }
    if data.key?("seq") && data.key?("uptime_ms")
      # Odcisk obejmuje cały payload, w tym uptime_ms (zerowany przy restarcie ESP),
      # więc powtórzenie tego samego datagramu jest odróżnialne od identycznego
      # pakietu z innego uruchomienia. Docelowy transport HTTPS powinien dodatkowo
      # jawnie przesyłać identyfikator uruchomienia (boot id), by zachować tę
      # własność niezależnie od szczegółów ramki.
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(data.sort.to_h))
      create_or_find_by!(packet_fingerprint: fingerprint) { |reading| reading.assign_attributes(attributes) }
    else
      create!(attributes)
    end
  end

  def as_reading
    payload.slice(*METRICS, "battery_ok", "decoder", "complete", "channel", "seq", "uptime_ms", "startup").merge(
      "id" => id, "sensor_id" => sensor_id, "device_id" => device_id,
      "source_ip" => source_ip, "received_at" => received_at.iso8601
    )
  end

  def as_public_reading
    payload.slice(*PUBLIC_METRICS).merge("received_at" => received_at.iso8601)
  end
end

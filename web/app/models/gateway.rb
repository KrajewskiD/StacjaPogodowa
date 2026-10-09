class Gateway < ApplicationRecord
  has_many :gateway_events, dependent: :destroy

  def self.observe!(data, source_ip:, now: Time.current)
    raise ArgumentError, "Niepoprawny schemat" unless data.is_a?(Hash) && data["schema"] == 1
    raise ArgumentError, "Zbyt duży payload" if data.length > IngestPolicy::MAX_KEYS
    unknown = IngestPolicy.unknown_keys(data)
    raise ArgumentError, "Nieznane pola: #{unknown.join(", ")}" unless unknown.empty?
    id = data["device_id"]
    raise ArgumentError, "Niepoprawne ID ESP" unless id.is_a?(String) && id.match?(/\A[0-9a-fA-F]{1,16}\z/)
    raise ArgumentError, "Nieznane urządzenie" unless IngestPolicy.device_allowed?(id)
    %w[seq uptime_ms decoded_packets].each do |key|
      next unless data.key?(key)
      raise ArgumentError, "Niepoprawne #{key}" unless data[key].is_a?(Integer) && data[key] >= 0
    end
    if data.key?("wifi_rssi_dbm") && !(data["wifi_rssi_dbm"].is_a?(Numeric) && data["wifi_rssi_dbm"].finite?)
      raise ArgumentError, "Niepoprawne RSSI Wi-Fi"
    end
    transaction do
      gateway = find_or_initialize_by(device_id: id)
      uptime, sequence = data.values_at("uptime_ms", "seq")
      restart = uptime && sequence && gateway.last_uptime && gateway.last_sequence &&
        uptime < gateway.last_uptime && sequence < gateway.last_sequence && sequence <= 5 &&
        gateway.last_uptime < 0xf0000000
      if sequence && gateway.last_sequence && sequence > gateway.last_sequence && !restart
        gateway.missing_packets += sequence - gateway.last_sequence - 1
      end
      gateway.last_seen_at = now
      gateway.source_ip = source_ip
      if data["type"] == "status"
        gateway.payload = data
        gateway.last_status_at = now
      end
      if restart || !gateway.last_sequence || !sequence || sequence > gateway.last_sequence
        gateway.last_uptime = uptime if uptime
        gateway.last_sequence = sequence if sequence
      end
      gateway.save!
      gateway.gateway_events.create!(kind: "possible_restart", occurred_at: now) if restart
      gateway
    end
  end

  def diagnostics(now: Time.current)
    status_fresh = last_status_at && now - last_status_at < 90
    state = if !last_seen_at || now - last_seen_at > 90
      "Brak łączności z ESP"
    elsif status_fresh && payload["radio_ok"] == false
      "Błąd CC1101"
    else
      "ESP online"
    end
    { device_id: device_id, source_ip: source_ip, state: state, last_seen_at: last_seen_at,
      last_status_at: last_status_at, status_fresh: !!status_fresh, status: payload,
      uptime_ms: last_uptime, missing_packets: missing_packets,
      restarts: gateway_events.order(occurred_at: :desc).limit(10).pluck(:occurred_at) }
  end
end

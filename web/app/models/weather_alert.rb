class WeatherAlert < ApplicationRecord
  LABELS = { "missing" => "Brak nowych pomiarów", "cold" => "Temperatura poniżej zera",
    "hot" => "Wysoka temperatura", "gust" => "Zarejestrowano silny poryw wiatru",
    "uv" => "Wysoki indeks UV", "battery" => "Niski stan baterii" }.freeze

  def self.evaluate!(reading, settings: StationSetting.current, now: Time.current)
    transaction do
      missing = find_or_initialize_by(sensor_id: reading.sensor_id, kind: "missing")
      fresh = reading.received_at <= now && now - reading.received_at < settings.missing_seconds
      missing.active = !fresh
      missing.triggered_at = fresh ? nil : (missing.triggered_at || reading.received_at + settings.missing_seconds)
      missing.pending_since = nil
      missing.save! if missing.changed?

      p = reading.payload
      rules = {
        "cold" => [p["temperature_c"], :<, settings.temperature_low, :>, settings.temperature_low_clear, settings.cold_confirm_seconds, 0],
        "hot" => [p["temperature_c"], :>, settings.temperature_high, :<, settings.temperature_high_clear, settings.hot_confirm_seconds, 0],
        "gust" => [p["wind_gust_ms"], :>=, settings.gust_high, :<, settings.gust_clear, 0, settings.gust_clear_seconds],
        "uv" => [p["uv_index"], :>=, settings.uv_high, :<, settings.uv_clear, settings.uv_confirm_seconds, settings.uv_clear_seconds],
        "battery" => [p["battery_ok"], :==, false, :==, true, settings.battery_confirm_seconds, 0]
      }
      rules.each do |kind, (value, comparison, threshold, clear_comparison, clear_threshold, on_delay, off_delay)|
        alert = find_or_initialize_by(sensor_id: reading.sensor_id, kind: kind)
        unless fresh
          alert.pending_since = alert.clear_pending_since = nil
          alert.save! if alert.changed?
          next
        end
        next if value.nil? || alert.last_measurement_id && reading.id <= alert.last_measurement_id
        # Powtórzenie tego samego datagramu nie jest nowym dowodem warunku.
        packet_key = if p["seq"] && p["uptime_ms"]
          [reading.device_id, p["seq"], p["uptime_ms"]].join(":")
        end
        next if packet_key && alert.last_packet_key == packet_key
        next if alert.last_observed_at && reading.received_at <= alert.last_observed_at

        gap = alert.last_observed_at.nil? || reading.received_at - alert.last_observed_at > settings.confirmation_gap_seconds
        alert.pending_since = alert.clear_pending_since = nil if gap
        alert.last_measurement_id = reading.id
        alert.last_packet_key = packet_key
        alert.last_observed_at = reading.received_at
        trigger = value.public_send(comparison, threshold)
        clear = value.public_send(clear_comparison, clear_threshold)

        if trigger
          alert.last_confirmed_at = reading.received_at
          alert.pending_since ||= reading.received_at
          alert.clear_pending_since = nil
          if reading.received_at - alert.pending_since >= on_delay
            alert.active = true
            alert.triggered_at ||= reading.received_at
          end
        else
          alert.pending_since = nil
          if clear && alert.active
            alert.clear_pending_since ||= reading.received_at
            if reading.received_at - alert.clear_pending_since >= off_delay
              alert.active = false
              alert.triggered_at = alert.clear_pending_since = nil
            end
          else
            alert.clear_pending_since = nil
          end
        end
        alert.save! if alert.changed?
      end
    end
  end
end

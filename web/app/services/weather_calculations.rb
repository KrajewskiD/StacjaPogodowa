class WeatherCalculations
  DIRECTIONS = %w[N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW].freeze
  BEAUFORT = [0.3, 1.6, 3.4, 5.5, 8.0, 10.8, 13.9, 17.2, 20.8, 24.5, 28.5, 32.7].freeze

  def self.call(data)
    result = {}
    t, rh, wind, direction, uv = data.values_at("temperature_c", "humidity_pct", "wind_avg_ms", "wind_direction_deg", "uv_index")
    if t && rh && (-80..80).cover?(t) && rh > 0 && rh <= 100
      gamma = Math.log(rh / 100.0) + 17.62 * t / (243.12 + t)
      result[:dew_point_c] = (243.12 * gamma / (17.62 - gamma)).round(2)
    end
    if wind && wind >= 0
      kmh = wind * 3.6
      result.merge!(wind_kmh: kmh.round(2), beaufort: BEAUFORT.count { |limit| wind >= limit }, calm: wind < 0.3)
      if t && (-50..10).cover?(t) && kmh >= 4.8
        result[:feels_like_c] = (13.12 + 0.6215 * t - 11.37 * kmh**0.16 + 0.3965 * t * kmh**0.16).round(2)
        result[:feels_like_method] = "Wind chill"
      end
    end
    if t && rh && (26.7..50).cover?(t) && (40..100).cover?(rh)
      f = t * 1.8 + 32
      index = -42.379 + 2.04901523*f + 10.14333127*rh - 0.22475541*f*rh -
        0.00683783*f*f - 0.05481717*rh*rh + 0.00122874*f*f*rh +
        0.00085282*f*rh*rh - 0.00000199*f*f*rh*rh
      index += ((rh - 85) / 10.0) * ((87 - f) / 5.0) if rh > 85 && f <= 87
      result[:feels_like_c] = ((index - 32) / 1.8).round(2)
      result[:feels_like_method] = "Heat index"
    end
    if !result.key?(:feels_like_c) &&
        [t, rh, wind].all? { |value| value.is_a?(Numeric) && value.finite? } &&
        (-80..80).cover?(t) && rh > 0 && rh <= 100 && wind >= 0
      # Apparent temperature w cieniu: ciśnienie pary w hPa, wiatr w m/s.
      vapour_pressure = rh / 100.0 * 6.105 * Math.exp(17.27 * t / (237.7 + t))
      result[:feels_like_c] = (t + 0.33 * vapour_pressure - 0.70 * wind - 4.0).round(2)
      result[:feels_like_method] = "Odczuwalna w cieniu — szacunek"
    end
    result[:wind_direction] = DIRECTIONS[((direction % 360) / 22.5).round % 16] if direction
    result[:gust_kmh] = (data["wind_gust_ms"] * 3.6).round(2) if data["wind_gust_ms"]
    if uv && uv >= 0
      result[:uv_level] = uv < 3 ? "Niski" : uv < 6 ? "Umiarkowany" : uv < 8 ? "Wysoki" : uv < 11 ? "Bardzo wysoki" : "Ekstremalny"
    end
    result
  end
end

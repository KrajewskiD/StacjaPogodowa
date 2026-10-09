# Prezentacja bieżąca; pomiary źródłowe i reguły alertów pozostają niezależne.
class LiveWeather
  WINDOW = 300
  # Dopuszczalna przerwa między próbkami w oknie 5 minut. Dłuższa oznacza przerwę
  # ciągłości: odcinek jest wyłączany ze średniej ważonej wiatru i z pokrycia.
  # To krótsze okno „na żywo”, inne niż MAX_GAP=120 w agregacji dobowej
  # (DailyWeather/WeatherHistory), dlatego wartość jest celowo osobna.
  MAX_GAP = 60
  MEDIANS = %w[temperature_c humidity_pct uv_index light_klx dew_point_c feels_like_c].freeze

  def initialize(scope, now: Time.current)
    @now = now
    @rows = RecentMeasurements.fetch(scope, from: now - WINDOW, to: now).map do |reading|
      { time: reading.received_at, device: reading.device_id,
        values: reading.payload.merge(WeatherCalculations.call(reading.payload).stringify_keys) }
    end
  end

  def call
    metrics = MEDIANS.to_h { |key| [key, summarize(key, :median)] }
    metrics["wind_avg_ms"] = summarize("wind_avg_ms", :weighted_mean)
    metrics["wind_gust_ms"] = summarize("wind_gust_ms", :maximum)
    values = metrics.transform_values { |metric| metric[:value] }
    values["wind_direction_deg"] = direction
    derived = WeatherCalculations.call(values.slice("wind_avg_ms", "wind_gust_ms", "wind_direction_deg", "uv_index"))
      .merge(dew_point_c: values.delete("dew_point_c"), feels_like_c: values.delete("feels_like_c"),
        feels_like_method: "Mediana odczuwalnej · ostatnie 5 min")
    { values: values, derived: derived, window_seconds: WINDOW,
      from: @now - WINDOW, to: @now, samples: @rows.size, metrics: metrics,
      status: metrics["temperature_c"][:status] }
  end

  private

  def valid?(value)
    value.is_a?(Numeric) && value.finite?
  end

  def pairs(rows)
    rows.each_cons(2).select do |a, b|
      delta = b[:time] - a[:time]
      delta.positive? && delta <= MAX_GAP && a[:device] == b[:device]
    end
  end

  def summarize(key, method)
    rows = @rows.select { |row| valid?(row[:values][key]) }
    numbers = rows.map { |row| row[:values][key] }.sort
    intervals = pairs(rows)
    covered = intervals.sum { |a, b| b[:time] - a[:time] }
    value = unless numbers.empty?
      case method
      when :median
        (numbers[(numbers.size - 1) / 2] + numbers[numbers.size / 2]) / 2.0
      when :maximum
        numbers.last
      when :weighted_mean
        if covered.positive?
          intervals.sum { |a, b| (a[:values][key] + b[:values][key]) / 2.0 * (b[:time] - a[:time]) } / covered
        end
      end
    end
    status = if value.nil?
      "no_data"
    elsif covered >= 240 && rows.size >= 10 && @now - rows.last[:time] <= MAX_GAP
      "ready"
    else
      "preliminary"
    end
    { value: value&.round(2), method: method, samples: rows.size,
      covered_seconds: covered.round, status: status }
  end

  def direction
    rows = @rows.select { |r| %w[wind_avg_ms wind_direction_deg].all? { |key| valid?(r[:values][key]) } }
    x = y = weight = 0.0
    pairs(rows).each do |a, b|
      duration = b[:time] - a[:time]
      [a, b].each do |row|
        speed = row[:values]["wind_avg_ms"]
        next if speed < 0.3
        radians = row[:values]["wind_direction_deg"] * Math::PI / 180
        w = speed * duration / 2.0
        x += Math.cos(radians) * w
        y += Math.sin(radians) * w
        weight += w
      end
    end
    return nil if weight.zero? || Math.hypot(x, y) / weight < 0.1
    ((Math.atan2(y, x) * 180 / Math::PI) % 360).round(1) % 360
  end
end

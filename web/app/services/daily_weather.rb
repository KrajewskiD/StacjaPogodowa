# Statystyki jednej lokalnej doby. Wszystkie średnie używają rzeczywistego
# czasu między pomiarami, z przycięciem na granicach analizowanego przedziału.
class DailyWeather
  # Przerwa powyżej tej wartości przerywa ciągłość serii przy agregacji dobowej
  # (trapezy, pokrycie, suma opadów). Wartość spójna z WeatherHistory::MAX_GAP
  # i celowo dłuższa niż LiveWeather::MAX_GAP (okno 5 minut).
  MAX_GAP = 120
  KEYS = %w[temperature_c humidity_pct wind_avg_ms wind_gust_ms uv_index light_klx dew_point_c feels_like_c].freeze

  def initialize(scope, date:, settings:, now: Time.current)
    @scope, @date, @settings, @now = scope, date, settings, now
    @start = date.in_time_zone
    @finish = (date + 1).in_time_zone
    @end = [@finish, now].min
    # Sąsiednie próbki pozwalają przyciąć trapez dokładnie na północy.
    @rows = RecentMeasurements.fetch(scope, from: @start - MAX_GAP, to: [@finish + MAX_GAP, now].min).map do |r|
        values = r.payload.merge(WeatherCalculations.call(r.payload).stringify_keys)
        { time: r.received_at, values: values, device: r.device_id }
      end
  end

  def call
    metrics = KEYS.to_h { |key| [key, summarize(key, [[@start, @finish]])] }
    rise = sunset = nil
    if @settings.latitude && @settings.longitude
      rise = Astronomy.sun_event(@date, @settings.latitude, @settings.longitude, true)
      sunset = Astronomy.sun_event(@date, @settings.latitude, @settings.longitude, false)
    end
    periods = { full: metrics["temperature_c"] }
    if rise && sunset && @start <= rise && rise < sunset && sunset < @finish
      periods[:before_sunrise] = summarize("temperature_c", [[@start, rise]])
      periods[:daylight] = summarize("temperature_c", [[rise, sunset]])
      periods[:after_sunset] = summarize("temperature_c", [[sunset, @finish]])
      periods[:night] = summarize("temperature_c", [[@start, rise], [sunset, @finish]])
    end
    rain = rainfall
    values = metrics.transform_values { |s| s[:mean] }
    values["wind_gust_ms"] = metrics["wind_gust_ms"][:max]
    values["uv_index"] = metrics["uv_index"][:max]
    values["rain_total_mm"] = rain[:mm]
    # Nie wyznaczamy kierunku ze średniej arytmetycznej kątów.
    values["wind_direction_deg"] = nil
    derived = WeatherCalculations.call(values.slice("wind_avg_ms", "wind_gust_ms", "uv_index"))
      .merge(dew_point_c: metrics["dew_point_c"][:mean], feels_like_c: metrics["feels_like_c"][:mean],
             feels_like_method: "Średnia ważona odczuwalnej z pomiarów")
    { date: @date.iso8601, start_at: @start, end_at: @finish, evaluated_until: @end,
      samples: @rows.count { |r| r[:time] >= @start && r[:time] < @end },
      status: metrics["temperature_c"][:status], metrics: metrics, values: values,
      derived: derived, temperature_periods: periods, rain: rain,
      sunrise: rise, sunset: sunset }
  end

  private

  def summarize(key, periods)
    ranges = periods.map { |from, to| [from, [to, @now].min] }.select { |from, to| to > from }
    expected = ranges.sum { |from, to| to - from }
    integral = covered = 0.0
    extremes = []
    rows = @rows.select { |r| r[:values][key].is_a?(Numeric) }
    rows.each do |r|
      extremes << [r[:values][key], r[:time]] if ranges.any? { |a, b| r[:time] >= a && r[:time] < b }
    end
    rows.each_cons(2) do |a, b|
      interval = b[:time] - a[:time]
      next unless interval.positive? && interval <= MAX_GAP && a[:device] == b[:device]
      ranges.each do |from, to|
        left, right = [a[:time], from].max, [b[:time], to].min
        next unless right > left
        slope = (b[:values][key] - a[:values][key]) / interval
        first = a[:values][key] + slope * (left - a[:time])
        last = a[:values][key] + slope * (right - a[:time])
        integral += (first + last) / 2.0 * (right - left)
        covered += right - left
        extremes.push([first, left], [last, right])
      end
    end
    low, high = extremes.minmax_by(&:first)
    status = if expected.zero?
      "future"
    elsif covered.zero?
      extremes.empty? ? "no_data" : "insufficient"
    elsif covered + 30 < expected
      "partial"
    else
      "complete"
    end
    { mean: covered.positive? ? (integral / covered).round(2) : nil,
      min: low&.first&.round(2), min_at: low&.last, max: high&.first&.round(2), max_at: high&.last,
      covered_seconds: covered.round, covered_minutes: (covered / 60).round(1),
      expected_seconds: expected.round, coverage_pct: expected.positive? ? (100 * covered / expected).round(1) : nil,
      status: status, partial: status != "complete",
      periods: periods.map { |from, to| { from: from, to: to } } }
  end

  def rainfall
    rows = @rows.select { |r| r[:time] <= @end && r[:values]["rain_total_mm"].is_a?(Numeric) }
    amount, gaps, resets, used = 0.0, 0, 0, 0
    partial = !rows.first || rows.first[:time] > @start || !rows.last || @end - rows.last[:time] > MAX_GAP
    rows.each_cons(2) do |a, b|
      next if b[:time] <= @start || b[:time] > @end || b[:time] <= a[:time]
      delta = b[:values]["rain_total_mm"] - a[:values]["rain_total_mm"]
      if delta < 0 || a[:device] != b[:device] || b[:values]["startup"] == true && a[:values]["startup"] != true
        resets += 1
        partial = true
        next
      end
      if b[:time] - a[:time] > MAX_GAP
        gaps += 1
        partial = true
      end
      if a[:time] < @start && delta.positive?
        partial = true
        next
      end
      used += 1
      amount += delta
    end
    { mm: used.positive? ? amount.round(2) : nil, partial: partial || used.zero?,
      status: used.zero? ? "no_data" : partial ? "partial" : "complete", resets: resets, gaps: gaps }
  end
end

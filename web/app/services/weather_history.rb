class WeatherHistory
  # Przerwa powyżej tej wartości przerywa ciągłość przy agregacji (trendy,
  # średnie, opady). Spójna z DailyWeather::MAX_GAP; dłuższa niż LiveWeather::MAX_GAP.
  MAX_GAP = 120

  # Minimalna próbka deszczu; pozwala sumować opady bez materializowania
  # pełnych obiektów AR (i całego payloadu JSON) dla długich okresów.
  RainSample = Data.define(:received_at, :device_id, :rain_mm, :startup)

  def initialize(scope, now: Time.current)
    @scope, @now = scope, now
  end

  # Dla widoku bieżącego: trendy (krótkie okno) i opady (zapytania celowane).
  # Średnie dzienne dostarcza DailyWeather, więc nie są tu powtarzane.
  def live_analytics
    { trends: trends, rain: rainfall }
  end

  # Zachowane dla testów i wstecznej zgodności. Produkcyjna ścieżka live
  # korzysta z live_analytics; daily pochodzi z DailyWeather.
  def summary
    today = @scope.where(received_at: @now.beginning_of_day..@now).order(:received_at, :id)
    { daily: %w[temperature_c humidity_pct wind_gust_ms uv_index light_klx].to_h { |key| [key, statistics(today, key)] },
      trends: trends, rain: rainfall }
  end

  def series(hours, from: @now - hours.hours)
    records = RecentMeasurements.fetch(@scope, from: from, to: @now)
    bucket_seconds = { 1 => 15, 6 => 60, 24 => 300, 168 => 1800 }.fetch(hours)
    groups, current, previous = [], nil, nil
    records.each do |record|
      bucket = record.received_at.to_i / bucket_seconds
      gap = previous && record.received_at - previous > MAX_GAP
      if !current || current[:bucket] != bucket || gap
        current = { bucket: bucket, break_before: !!gap, readings: [] }
        groups << current
      end
      current[:readings] << record
      previous = record.received_at
    end
    groups.map do |group|
      rows = group[:readings]
      values = %w[temperature_c humidity_pct wind_avg_ms wind_gust_ms].to_h do |key|
        numbers = rows.filter_map { |r| r.payload[key] }
        [key, numbers.empty? ? nil : (numbers.sum / numbers.length.to_f).round(3)]
      end
      values.merge("received_at" => rows.last.received_at.iso8601,
                   "rain_total_mm" => rows.last.payload["rain_total_mm"],
                   "break_before" => group[:break_before])
    end
  end

  private

  def trends
    records = RecentMeasurements.fetch(@scope, from: @now - 4.hours, to: @now)
    [30.minutes, 3.hours].to_h { |duration|
      [duration.to_i.to_s, %w[temperature_c humidity_pct].to_h { |key| [key, trend(records, key, duration)] }]
    }
  end

  def rainfall
    { hour: rain_since(@now - 1.hour), today: rain_since(@now.beginning_of_day),
      day: rain_since(@now - 24.hours), week: rain_since(@now.beginning_of_week),
      month: rain_since(@now.beginning_of_month), ten_minutes: rain_since(@now - 10.minutes) }
  end

  def rain_since(since)
    baseline = pluck_rain(@scope.where("received_at < ?", since).order(received_at: :desc, id: :desc).limit(1)).first
    inside = pluck_rain(@scope.where(received_at: since..@now).order(:received_at, :id))
    rain_compute(baseline, inside, since)
  end

  def pluck_rain(relation)
    relation.pluck(:received_at, :device_id,
      Arel.sql("payload->>'rain_total_mm'"), Arel.sql("payload->>'startup'"))
      .filter_map do |received_at, device_id, rain_text, startup_text|
        next if rain_text.nil?
        RainSample.new(received_at, device_id, rain_text.to_f, startup_text == "true")
      end
  end

  def rain_compute(baseline, inside, since)
    rows = baseline ? [baseline, *inside] : inside
    return { mm: nil, partial: true, resets: 0, gaps: 0, since: since, rate_mmh: nil } if rows.size < 2 || inside.empty?
    total, resets, gaps = 0.0, 0, 0
    partial = !baseline || since - baseline.received_at > MAX_GAP || @now - rows.last.received_at > MAX_GAP
    rows.each_cons(2) do |a, b|
      delta = b.rain_mm - a.rain_mm
      if delta < 0 || a.device_id != b.device_id || (b.startup && !a.startup)
        resets += 1
        partial = true
        next
      end
      if b.received_at - a.received_at > MAX_GAP
        gaps += 1
        partial = true
      end
      if a.received_at < since && delta.positive?
        # Nie wiadomo, po której stronie granicy okresu spadł deszcz.
        partial = true
        next
      end
      total += delta
    end
    { mm: total.round(2), partial: partial, resets: resets, gaps: gaps, since: since,
      rate_mmh: partial ? nil : (total * 3600 / (@now - since)).round(2) }
  end

  def statistics(records, key)
    rows = records.select { |r| r.payload[key].is_a?(Numeric) }
    return nil if rows.empty?
    low, high = rows.minmax_by { |r| r.payload[key] }
    integral = seconds = 0.0
    rows.each_cons(2) do |a, b|
      interval = b.received_at - a.received_at
      next unless interval.positive? && interval <= MAX_GAP
      integral += (a.payload[key] + b.payload[key]) / 2.0 * interval
      seconds += interval
    end
    { min: low.payload[key], min_at: low.received_at, max: high.payload[key], max_at: high.received_at,
      mean: seconds.positive? ? (integral / seconds).round(2) : nil,
      covered_minutes: (seconds / 60).round(1), samples: rows.size,
      partial: seconds < (@now - @now.beginning_of_day) * 0.95 }
  end

  def trend(records, key, duration)
    rows = records.select { |r| r.payload[key].is_a?(Numeric) }
    last = rows.last
    return nil unless last && @now - last.received_at <= MAX_GAP
    target = last.received_at - duration
    first = rows.min_by { |r| (r.received_at - target).abs }
    return nil unless first && (first.received_at - target).abs <= MAX_GAP
    window = rows.select { |r| r.received_at >= first.received_at }
    return nil if window.each_cons(2).any? { |a, b| b.received_at - a.received_at > MAX_GAP }
    (last.payload[key] - first.payload[key]).round(2)
  end
end
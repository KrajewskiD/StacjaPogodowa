class WeatherController < ApplicationController
  SENSOR_ID = "0000DE3E".freeze

  def index
  end

  def show
    now = Time.current
    today = now.to_date
    selected = SENSOR_ID
    readings = Measurement.where(sensor_id: selected)
    first_date = readings.minimum(:received_at)&.in_time_zone&.to_date || today
    begin
      date = params[:date].present? ? Date.iso8601(params[:date]) : today
    rescue ArgumentError, TypeError
      return render json: { error: "Niepoprawna data" }, status: :bad_request
    end
    unless (first_date..today).cover?(date)
      return render json: { error: "Wybierz datę od #{first_date.iso8601} do #{today.iso8601}" }, status: :bad_request
    end
    historical = date != today
    latest = readings.order(received_at: :desc, id: :desc).first
    hours = requested_hours
    dated = params[:date].present?
    period = dated ? date.in_time_zone...(date + 1).in_time_zone : hours.hours.ago..now
    history = readings.where(received_at: period).order(received_at: :desc, id: :desc).limit(8).to_a.reverse
    settings = StationSetting.current
    day = Rails.cache.fetch(["daily-weather-v1", selected, date.iso8601, settings.latitude, settings.longitude], expires_in: 30.seconds) {
      DailyWeather.new(readings, date: date, settings: settings, now: now).call
    }
    analytics = if historical
      { daily: day[:metrics], trends: {}, rain: { selected: day[:rain] } }
    else
      Rails.cache.fetch(["live-analytics-v1", selected], expires_in: 30.seconds) { WeatherHistory.new(readings, now: now).live_analytics }
        .merge(daily: day[:metrics])
    end
    chart = Rails.cache.fetch(["weather-series-v2", selected, hours, dated ? date.iso8601 : "rolling"], expires_in: 10.seconds) {
      if dated
        WeatherHistory.new(readings, now: [now, (date + 1).in_time_zone - 0.000001].min).series(24, from: date.in_time_zone)
      else
        WeatherHistory.new(readings, now: now).series(hours)
      end
    }
    astronomy_time = historical ? Time.zone.local(date.year, date.month, date.day, 12) : now
    astronomy = Astronomy.call(settings, now: astronomy_time)
    if historical
      astronomy = astronomy.except(:next_sunrise, :next_sunset).merge(days: astronomy[:days]&.first(1))
    end
    response.headers["Cache-Control"] = "no-store"
    live = historical ? nil : LiveWeather.new(readings, now: now).call
    render json: { latest: historical ? nil : latest&.as_public_reading,
                   display: historical ? day[:values] : live[:values],
                   smoothing: live&.except(:values, :derived),
                   mode: historical ? "historical" : "live", selected_date: date.iso8601,
                   period_mode: dated ? "day" : "rolling",
                   available_dates: (0..7).map { |offset| (today - offset).iso8601 }, day: day,
                   date_bounds: { min: first_date.iso8601, max: today.iso8601 },
                   history: history.map(&:as_public_reading), total: readings.count,
                   stale: !historical && (latest.nil? || latest.received_at <= settings.missing_seconds.seconds.ago),
                   missing_seconds: settings.missing_seconds,
                   server_time: now.iso8601, derived: historical ? day[:derived] : live[:derived],
                   statistics: analytics, chart: chart, range_hours: hours,
                   astronomy: astronomy,
                   alerts: WeatherAlert.where(sensor_id: selected, active: true).where.not(kind: %w[battery missing]).map { |alert|
                     { kind: alert.kind, label: WeatherAlert::LABELS[alert.kind], since: alert.triggered_at,
                       last_confirmed_at: alert.last_confirmed_at,
                       stale: alert.last_observed_at.nil? || alert.last_observed_at <= settings.missing_seconds.seconds.ago }
                   } }
  end

  def export
    require "csv"
    sensor_id = SENSOR_ID
    scope = Measurement.where(sensor_id: sensor_id)
    if params[:date].present?
      begin
        date = Date.iso8601(params[:date])
      rescue ArgumentError, TypeError
        return head :bad_request
      end
      first_date = scope.minimum(:received_at)&.in_time_zone&.to_date || Date.current
      return head :bad_request unless (first_date..Date.current).cover?(date)
      scope = scope.where(received_at: date.in_time_zone...(date + 1).in_time_zone)
    else
      scope = scope.where(received_at: requested_hours.hours.ago..Time.current)
    end
    columns = %w[received_at] + Measurement::PUBLIC_METRICS
    self.response_body = Enumerator.new do |output|
      output << CSV.generate_line(columns)
      scope.find_each do |reading|
        row = reading.as_public_reading
        output << CSV.generate_line(columns.map { |key| row[key] })
      end
    end
    response.headers["Content-Type"] = "text/csv; charset=utf-8"
    response.headers["Content-Disposition"] = "attachment; filename=stacja-prudnik.csv"
    response.headers["Cache-Control"] = "no-store"
  end

  private

  def requested_hours
    value = params[:hours].to_i
    [1, 6, 24, 168].include?(value) ? value : 1
  end
end

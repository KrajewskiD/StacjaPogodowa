require_relative "test_helper"

class FeaturesTest < ActiveSupport::TestCase
  def reading(at, **payload)
    Measurement.create!(sensor_id: "0000DE3E", device_id: "aff734", source_ip: "127.0.0.1",
      received_at: at, payload: payload.transform_keys(&:to_s))
  end

  test "meteorological formulas and applicability" do
    value = WeatherCalculations.call("temperature_c" => 20, "humidity_pct" => 50, "wind_avg_ms" => 0, "wind_direction_deg" => 359)
    assert_in_delta 9.26, value[:dew_point_c], 0.05
    assert_equal "N", value[:wind_direction]
    assert_equal 0, value[:beaufort]
    assert value[:calm]
    assert_in_delta 19.85, value[:feels_like_c], 0.05
    assert_equal "Odczuwalna w cieniu — szacunek", value[:feels_like_method]
    cold = WeatherCalculations.call("temperature_c" => 0, "wind_avg_ms" => 5)
    assert_in_delta(-4.94, cold[:feels_like_c], 0.05)
    hot = WeatherCalculations.call("temperature_c" => 32.2222, "humidity_pct" => 70)
    assert_in_delta 41.1, hot[:feels_like_c], 0.3
    assert_nil WeatherCalculations.call("temperature_c" => 20, "humidity_pct" => 0)[:dew_point_c]
  end

  test "apparent temperature uses metres per second and requires all inputs" do
    data = { "temperature_c" => 13.2, "humidity_pct" => 70, "wind_avg_ms" => 0 }
    calm = WeatherCalculations.call(data)
    assert_in_delta 12.7, calm[:feels_like_c], 0.05
    breezy = WeatherCalculations.call(data.merge("wind_avg_ms" => 2))
    assert_in_delta 1.4, calm[:feels_like_c] - breezy[:feels_like_c], 0.01
    data.each_key do |key|
      assert_nil WeatherCalculations.call(data.except(key))[:feels_like_c]
    end
    [0, -1, 101].each do |humidity|
      assert_nil WeatherCalculations.call(data.merge("humidity_pct" => humidity))[:feels_like_c]
    end
    assert_nil WeatherCalculations.call(data.merge("wind_avg_ms" => -1))[:feels_like_c]
  end

  test "specialised indices take priority over apparent temperature" do
    cold = WeatherCalculations.call("temperature_c" => 0, "humidity_pct" => 70, "wind_avg_ms" => 5)
    assert_equal "Wind chill", cold[:feels_like_method]
    assert_in_delta(-4.94, cold[:feels_like_c], 0.05)
    hot = WeatherCalculations.call("temperature_c" => 32.2222, "humidity_pct" => 70, "wind_avg_ms" => 2)
    assert_equal "Heat index", hot[:feels_like_method]
    assert_in_delta 41.1, hot[:feels_like_c], 0.3
  end

  test "time weighted average excludes long gaps" do
    now = Time.zone.parse("2026-09-23 12:00")
    reading(now - 120, temperature_c: 0)
    reading(now - 60, temperature_c: 10)
    reading(now, temperature_c: 10)
    stats = WeatherHistory.new(Measurement.all, now: now).summary[:daily]["temperature_c"]
    assert_in_delta 7.5, stats[:mean], 0.01
    assert_equal 2, stats[:covered_minutes]
    assert stats[:partial]
  end

  test "rain does not assign reset or cross-midnight increment to today" do
    midnight = Time.zone.parse("2026-09-23 00:00")
    reading(midnight - 30, rain_total_mm: 10)
    reading(midnight + 30, rain_total_mm: 11)
    reading(midnight + 60, rain_total_mm: 11.2)
    reading(midnight + 90, rain_total_mm: 0)
    reading(midnight + 120, rain_total_mm: 0.3)
    result = WeatherHistory.new(Measurement.all, now: midnight + 130).summary[:rain][:today]
    assert_in_delta 0.5, result[:mm], 0.001
    assert result[:partial]
    assert_equal 1, result[:resets]
    assert_nil result[:rate_mmh]
  end

  test "complete rain window gives rate but a gap removes it" do
    now = Time.zone.parse("2026-09-23 12:00")
    (-11..0).each { |minute| reading(now + minute.minutes, rain_total_mm: [0, (minute + 10) * 0.1].max) }
    result = WeatherHistory.new(Measurement.all, now: now).summary[:rain][:ten_minutes]
    assert_not result[:partial]
    assert_in_delta 1, result[:mm], 0.001
    assert_in_delta 6, result[:rate_mmh], 0.001
    Measurement.where(received_at: (now - 8.minutes)..(now - 5.minutes)).delete_all
    result = WeatherHistory.new(Measurement.all, now: now).summary[:rain][:ten_minutes]
    assert result[:partial]
    assert_nil result[:rate_mmh]
  end

  test "chart preserves missing interval and trends need continuous coverage" do
    now = Time.current
    reading(now - 30.minutes, temperature_c: 10)
    reading(now, temperature_c: 12)
    history = WeatherHistory.new(Measurement.all, now: now)
    assert history.series(1).last["break_before"]
    assert_nil history.summary[:trends]["1800"]["temperature_c"]
  end

  test "gateway distinguishes a reboot from 32 bit uptime rollover" do
    packet = { "schema" => 1, "type" => "status", "device_id" => "aff734", "radio_ok" => true, "seq" => 80, "uptime_ms" => 80000 }
    Gateway.observe!(packet, source_ip: "127.0.0.1")
    Gateway.observe!(packet.merge("seq" => 83, "uptime_ms" => 90000), source_ip: "127.0.0.1")
    assert_equal 2, Gateway.first.missing_packets
    Gateway.observe!(packet.merge("seq" => 1, "uptime_ms" => 1000), source_ip: "127.0.0.1")
    assert_equal 1, GatewayEvent.count
    Gateway.first.update!(last_uptime: 0xfffffff0, last_sequence: 900)
    Gateway.observe!(packet.merge("seq" => 901, "uptime_ms" => 100), source_ip: "127.0.0.1")
    assert_equal 1, GatewayEvent.count
  end

  test "astronomy handles missing coordinates and polar day" do
    settings = StationSetting.current
    now = Time.zone.parse("2026-06-21 12:00")
    assert_not Astronomy.call(settings, now: now)[:configured]
    settings.assign_attributes(latitude: 52.23, longitude: 21.01)
    result = Astronomy.call(settings, now: now)
    assert_in_delta 16.8, result[:daylight_hours], 0.3
    assert_equal 4, result[:sunrise].hour
    assert_equal 21, result[:sunset].hour
    settings.assign_attributes(latitude: 80)
    assert Astronomy.call(settings, now: now)[:polar]
  end

  test "astronomy returns today and tomorrow across year and daylight saving boundaries" do
    settings = StationSetting.new(latitude: 51.07, longitude: 17.02)
    ["2026-12-31 23:30", "2026-10-24 23:30"].each do |stamp|
      now = Time.zone.parse(stamp)
      days = Astronomy.call(settings, now: now)[:days]
      assert_equal [now.to_date.iso8601, (now.to_date + 1).iso8601], days.map { |day| day[:date] }
      days.each do |day|
        assert_equal day[:date], day[:sunrise].to_date.iso8601
        assert_equal day[:date], day[:sunset].to_date.iso8601
        assert_operator day[:sunset], :>, day[:sunrise]
        assert_equal ((day[:sunset] - day[:sunrise]) / 60).round, day[:daylight_minutes]
      end
    end
  end
end

class FeatureRoutesTest < ActionDispatch::IntegrationTest
  setup { host! "localhost" }

  test "public pages are read only and have no configuration links" do
    %w[/ /history /alerts].each do |path|
      get path
      assert_response :success
      assert_select "form:not(#date-form)", count: 0
      assert_select '#date-form input[type="date"]', count: 1
      assert_select 'a[href="/settings"], a[href="/devices"]', count: 0
    end
  end

  test "configuration and diagnostics routes are removed for every method" do
    original = StationSetting.current.attributes
    %w[/settings /devices].each do |path|
      %i[get post patch put delete].each do |verb|
        public_send(verb, path, params: { station_setting: { latitude: 52, longitude: 21 } })
        assert_response :not_found
      end
    end
    assert_equal original, StationSetting.current.attributes
  end

  test "public API exposes only weather values even if diagnostics exist" do
    Measurement.create!(sensor_id: "0000DE3E", device_id: "aff734", source_ip: "192.168.100.69",
      received_at: Time.current, payload: { "temperature_c" => 12.3, "rssi_dbm" => -75,
        "seq" => 100, "uptime_ms" => 1000, "channel" => 0, "battery_ok" => true })
    Gateway.observe!({ "schema" => 1, "device_id" => "aff734", "type" => "status", "radio_ok" => true }, source_ip: "192.168.100.69")
    WeatherAlert.create!(sensor_id: "0000DE3E", kind: "battery", active: true)
    WeatherAlert.create!(sensor_id: "0000DE3E", kind: "hot", active: true)
    get "/api/weather"
    assert_response :success
    data = response.parsed_body
    assert_equal %w[received_at temperature_c], data["latest"].keys.sort
    assert_equal data["latest"], data["history"].first
    assert_not data.key?("gateway")
    assert_not data["statistics"].key?("reception")
    assert_equal ["hot"], data["alerts"].map { |alert| alert["kind"] }
    %w[aff734 0000DE3E 192.168.100.69 sensor_id device_id source_ip rssi_dbm uptime_ms].each do |private_value|
      assert_not_includes response.body, private_value
    end
  end

  test "CSV selects sensor and range" do
    require "csv"
    %w[0000DE3E 00001234].each do |id|
      Measurement.create!(sensor_id: id, device_id: "aff734", source_ip: "127.0.0.1",
        received_at: Time.current, payload: { "temperature_c" => id == "0000DE3E" ? 12.3 : 99 })
    end
    get "/export.csv", params: { hours: 24 }
    assert_response :success
    rows = CSV.parse(response.body, headers: true)
    assert_equal 1, rows.size
    assert_equal ["received_at", *Measurement::PUBLIC_METRICS], rows.headers
    assert_equal "12.3", rows.first["temperature_c"]
    get "/export.csv", params: { sensor_id: "00001234", hours: 24 }
    assert_response :success
    assert_equal ["12.3"], CSV.parse(response.body, headers: true).map { |row| row["temperature_c"] }
    assert_not_includes response.headers["Content-Disposition"], "0000DE3E"
  end
end

class ServerSettingsTest < ActiveSupport::TestCase
  test "settings are validated server configuration rather than a database preference" do
    StationSetting.create!(id: 1, latitude: 10, longitude: 20, temperature_high: 40)
    settings = StationSetting.current
    assert_nil settings.latitude
    assert_equal 30, settings.temperature_high
    assert settings.readonly?
    assert_raises(ActiveRecord::ReadOnlyRecord) { settings.save! }
    settings.assign_attributes(latitude: 52, longitude: nil)
    assert_not settings.valid?
    settings.assign_attributes(longitude: 21, temperature_low: 40, temperature_high: 30)
    assert_not settings.valid?
  end
end

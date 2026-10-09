require_relative "test_helper"

class DailyWeatherTest < ActiveSupport::TestCase
  setup do
    @date = Date.new(2026, 9, 24)
    @start = @date.in_time_zone
    @settings = StationSetting.current
    @settings.latitude = 51.07
    @settings.longitude = 17.02
  end

  def sample(time, **values)
    Measurement.create!(sensor_id: "0000DE3E", device_id: "aff734", source_ip: "127.0.0.1",
      received_at: time, payload: values.stringify_keys)
  end

  def summary(date: @date, now: @start + 1.day)
    DailyWeather.new(Measurement.where(sensor_id: "0000DE3E"), date: date, settings: @settings, now: now).call
  end

  test "weights irregular samples and clips the midnight boundary" do
    sample(@start - 30, temperature_c: 0)
    sample(@start + 30, temperature_c: 12)
    sample(@start + 120, temperature_c: 12)
    s = summary[:metrics]["temperature_c"]
    assert_in_delta 11.25, s[:mean], 0.01
    assert_equal 120, s[:covered_seconds]
    assert_equal "partial", s[:status]
    assert_equal 6, s[:min]
  end

  test "long gaps do not become zero or a whole day of coverage" do
    sample(@start, temperature_c: 0)
    sample(@start + 60, temperature_c: 10)
    sample(@start + 3600, temperature_c: 30)
    s = summary[:metrics]["temperature_c"]
    assert_equal 5, s[:mean]
    assert_equal 60, s[:covered_seconds]
    assert_equal 30, s[:max]
    assert_nil summary[:metrics]["humidity_pct"][:mean]
  end

  test "local days have 23 or 25 hours at daylight saving transitions" do
    { Date.new(2026, 3, 29) => 23, Date.new(2026, 10, 25) => 25 }.each do |date, hours|
      result = summary(date: date, now: (date + 1).in_time_zone)
      assert_equal hours * 3600, result[:metrics]["temperature_c"][:expected_seconds]
    end
  end

  test "sunrise splits the integration and future periods remain empty" do
    rise = Astronomy.sun_event(@date, @settings.latitude, @settings.longitude, true)
    sample(rise - 60, temperature_c: 0)
    sample(rise + 60, temperature_c: 12)
    result = summary(now: rise + 60)
    assert_equal 3, result[:temperature_periods][:before_sunrise][:mean]
    assert_equal 9, result[:temperature_periods][:daylight][:mean]
    assert_equal "future", result[:temperature_periods][:after_sunset][:status]
    assert_equal 3, result[:temperature_periods][:night][:mean]
  end

  test "rain reset retains only assignable increments and marks partial data" do
    sample(@start, rain_total_mm: 10)
    sample(@start + 30, rain_total_mm: 11)
    sample(@start + 60, rain_total_mm: 0)
    sample(@start + 90, rain_total_mm: 2)
    result = summary[:rain]
    assert_equal 3, result[:mm]
    assert_equal 1, result[:resets]
    assert result[:partial]
  end

  test "empty day and isolated observation cannot fabricate a mean" do
    assert_equal "no_data", summary[:status]
    sample(@start + 30, temperature_c: 10)
    assert_equal "insufficient", summary[:status]
    assert_nil summary[:values]["temperature_c"]
  end
end

class DailyWeatherPublicTest < ActionDispatch::IntegrationTest
  setup { host! "localhost" }

  test "chart table and CSV use the same local day excluding the next midnight" do
    travel_to Time.zone.local(2026, 9, 26, 12) do
      [Time.zone.local(2026, 9, 24, 23, 59), Time.zone.local(2026, 9, 25, 12), Time.zone.local(2026, 9, 26)].each_with_index do |at, i|
        Measurement.create!(sensor_id: "0000DE3E", device_id: "aff734", source_ip: "127.0.0.1", received_at: at, payload: { "temperature_c" => 10 + i })
      end
      get "/api/weather", params: { date: "2026-09-25" }
      assert_response :success
      assert_equal "day", response.parsed_body["period_mode"]
      assert_equal [11], response.parsed_body["history"].map { |r| r["temperature_c"] }
      assert_equal [11], response.parsed_body["chart"].map { |r| r["temperature_c"] }
      get "/export.csv", params: { date: "2026-09-25" }
      assert_response :success
      assert_equal 2, response.body.lines.count
      assert_includes response.body, "2026-09-25"
      get "/export.csv", params: { date: "2026-09-27" }
      assert_response :bad_request
    end
  end

  test "historical selection is bounded and hides live readings" do
    travel_to Time.zone.local(2026, 9, 25, 12) do
      Measurement.create!(sensor_id: "0000DE3E", device_id: "aff734", source_ip: "127.0.0.1",
        received_at: Time.zone.local(2026, 8, 1, 0, 30), payload: { "temperature_c" => 15 })
      get "/api/weather", params: { date: "2026-09-24" }
      assert_response :success
      data = response.parsed_body
      assert_equal "historical", data["mode"]
      assert_equal 8, data["available_dates"].length
      assert_nil data["latest"]
      assert_nil data["astronomy"]["next_sunrise"]
      assert_equal "2026-09-24", data["day"]["date"]
      assert_equal({ "min" => "2026-08-01", "max" => "2026-09-25" }, data["date_bounds"])
      get "/api/weather", params: { date: "2026-08-01" }
      assert_response :success
      assert_equal 1, response.parsed_body["day"]["samples"]
      get "/api/weather", params: { date: "2026-08-02" }
      assert_response :success
      assert_equal "no_data", response.parsed_body["day"]["status"]
      %w[2026-07-31 2026-09-26 invalid].each do |date|
        get "/api/weather", params: { date: date }
        assert_response :bad_request
      end
    end
  end
end

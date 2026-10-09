require_relative "test_helper"

class WeatherAlertTest < ActiveSupport::TestCase
  setup do
    @start = Time.zone.parse("2026-09-25 12:00")
    @settings = StationSetting.current
  end

  def sample(seconds, **payload)
    reading = Measurement.create!(sensor_id: "0000DE3E", device_id: "aff734",
      source_ip: "127.0.0.1", received_at: @start + seconds,
      payload: payload.transform_keys(&:to_s))
    WeatherAlert.evaluate!(reading, settings: @settings, now: reading.received_at)
    reading
  end

  def alert(kind)
    WeatherAlert.find_by!(sensor_id: "0000DE3E", kind: kind)
  end

  test "timer never activates a temperature alert from one reading" do
    reading = sample(0, temperature_c: -2)
    [30, 60, 120, 179, 180, 300].each do |seconds|
      WeatherAlert.evaluate!(reading, settings: @settings, now: @start + seconds)
      assert_not alert("cold").active
    end
    assert alert("missing").active
  end

  test "cold requires two minutes of new frames and clears only above one degree" do
    (0..90).step(30) { |s| sample(s, temperature_c: -1) }
    assert_not alert("cold").active
    sample(120, temperature_c: -1)
    assert alert("cold").active
    sample(150, temperature_c: 1)
    assert alert("cold").active
    sample(180, temperature_c: 1.1)
    assert_not alert("cold").active
  end

  test "heat needs five minutes and clears below twenty nine" do
    (0..270).step(30) { |s| sample(s, temperature_c: 31) }
    assert_not alert("hot").active
    sample(300, temperature_c: 31)
    assert alert("hot").active
    sample(330, temperature_c: 29)
    assert alert("hot").active
    sample(360, temperature_c: 28.9)
    assert_not alert("hot").active
  end

  test "a gap or interrupted condition starts confirmation again" do
    sample(0, temperature_c: -2)
    sample(30, temperature_c: -2)
    sample(120, temperature_c: -2)
    assert_not alert("cold").active
    assert_equal @start + 120, alert("cold").pending_since
    sample(150, temperature_c: 0)
    assert_nil alert("cold").pending_since
    sample(180, temperature_c: -2)
    sample(210, humidity_pct: 70)
    sample(270, temperature_c: -2)
    assert_equal @start + 270, alert("cold").pending_since
  end

  test "one gust activates immediately and requires ten minutes of observed calm" do
    sample(0, wind_gust_ms: 15)
    assert alert("gust").active
    sample(30, wind_gust_ms: 11)
    (60..300).step(30) { |s| sample(s, wind_gust_ms: 11) }
    sample(330, wind_gust_ms: 12)
    assert_nil alert("gust").clear_pending_since
    (360..930).step(30) { |s| sample(s, wind_gust_ms: 11) }
    assert alert("gust").active
    sample(960, wind_gust_ms: 11)
    assert_not alert("gust").active
  end

  test "UV confirms for two minutes and clears after five below five" do
    (0..120).step(30) { |s| sample(s, uv_index: 6) }
    assert alert("uv").active
    (150..420).step(30) { |s| sample(s, uv_index: 4.9) }
    assert alert("uv").active
    sample(450, uv_index: 4.9)
    assert_not alert("uv").active
  end

  test "stale data preserves the event but cannot clear it using elapsed time" do
    sample(0, wind_gust_ms: 16)
    reading = sample(30, wind_gust_ms: 0)
    WeatherAlert.evaluate!(reading, settings: @settings, now: @start + 1000)
    assert alert("gust").active
    assert_nil alert("gust").clear_pending_since
    assert_equal @start, alert("gust").last_confirmed_at
    assert alert("missing").active
    sample(1010, wind_gust_ms: 0)
    assert_not alert("missing").active
    assert alert("gust").active
  end

  test "duplicate datagrams do not confirm a condition" do
    sample(0, temperature_c: -1, seq: 10, uptime_ms: 1000)
    sample(30, temperature_c: -1, seq: 10, uptime_ms: 1000)
    sample(120, temperature_c: -1, seq: 10, uptime_ms: 1000)
    assert_not alert("cold").active
    assert_equal @start, alert("cold").last_observed_at
    sample(150, temperature_c: -1, seq: 11, uptime_ms: 151000)
    assert_equal @start + 150, alert("cold").pending_since
  end

  test "missing data activates at 180 seconds without additional delay" do
    reading = sample(0, temperature_c: 20)
    WeatherAlert.evaluate!(reading, settings: @settings, now: @start + 179)
    assert_not alert("missing").active
    WeatherAlert.evaluate!(reading, settings: @settings, now: @start + 180)
    assert alert("missing").active
    assert_equal @start + 180, alert("missing").triggered_at
  end
end

class WeatherAlertPublicTest < ActionDispatch::IntegrationTest
  setup { host! "localhost" }

  test "missing is a data status while historical gust includes evidence time" do
    travel_to Time.zone.parse("2026-09-25 12:00") do
      reading = Measurement.create!(sensor_id: "0000DE3E", device_id: "aff734", source_ip: "127.0.0.1",
        received_at: Time.current, payload: { "wind_gust_ms" => 16 })
      WeatherAlert.evaluate!(reading)
      travel 180.seconds
      WeatherAlert.evaluate!(reading)
      get "/api/weather"
      data = response.parsed_body
      assert data["stale"]
      assert_equal 180, data["missing_seconds"]
      assert_equal ["gust"], data["alerts"].map { |a| a["kind"] }
      assert data["alerts"].first["stale"]
      assert_equal reading.received_at.iso8601(3), data["alerts"].first["last_confirmed_at"]
    end
  end
end

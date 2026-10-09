require_relative "test_helper"

class LiveWeatherTest < ActiveSupport::TestCase
  setup { @now = Time.zone.local(2026, 9, 26, 12) }

  def sample(seconds, **payload)
    Measurement.create!(sensor_id: "0000DE3E", device_id: "aff734", source_ip: "127.0.0.1",
      received_at: @now + seconds, payload: payload.stringify_keys)
  end

  def result
    LiveWeather.new(Measurement.where(sensor_id: "0000DE3E"), now: @now).call
  end

  test "median rejects an isolated outlier and ignores expired or future frames" do
    sample(-301, temperature_c: -50)
    [-60, -45, -30, -15, 0].zip([10, 10, 11, 10, 50]).each { |t, v| sample(t, temperature_c: v) }
    sample(1, temperature_c: 70)
    assert_equal 10, result[:values]["temperature_c"]
    assert_equal 5, result[:samples]
    assert_equal "preliminary", result[:status]
  end

  test "wind is weighted by elapsed time while gust retains its maximum" do
    sample(-60, wind_avg_ms: 0, wind_gust_ms: 15)
    sample(-50, wind_avg_ms: 10, wind_gust_ms: 10)
    sample(0, wind_avg_ms: 10, wind_gust_ms: 10)
    assert_in_delta 9.17, result[:values]["wind_avg_ms"], 0.01
    assert_equal 15, result[:values]["wind_gust_ms"]
  end

  test "direction wraps north and opposite vectors do not invent a direction" do
    sample(-30, wind_avg_ms: 2, wind_direction_deg: 359)
    sample(0, wind_avg_ms: 2, wind_direction_deg: 1)
    assert_equal 0, result[:values]["wind_direction_deg"]
    Measurement.delete_all
    sample(-30, wind_avg_ms: 2, wind_direction_deg: 0)
    sample(0, wind_avg_ms: 2, wind_direction_deg: 180)
    assert_nil result[:values]["wind_direction_deg"]
  end

  test "gaps are excluded and a lone wind observation has no time weighted mean" do
    sample(-200, wind_avg_ms: 80)
    sample(-30, wind_avg_ms: 2)
    sample(0, wind_avg_ms: 2)
    assert_equal 2, result[:values]["wind_avg_ms"]
    assert_equal 30, result[:metrics]["wind_avg_ms"][:covered_seconds]
    assert_nil result[:values]["temperature_c"]
    Measurement.delete_all
    sample(0, wind_avg_ms: 5)
    assert_nil result[:values]["wind_avg_ms"]
  end

  test "covered window is ready and derived medians use individual calculations" do
    (-300..0).step(15) { |s| sample(s, temperature_c: 10, humidity_pct: 80, wind_avg_ms: 1) }
    assert_equal "ready", result[:status]
    expected = WeatherCalculations.call({ "temperature_c" => 10, "humidity_pct" => 80, "wind_avg_ms" => 1 })
    assert_equal expected[:feels_like_c], result[:derived][:feels_like_c]
    assert_equal expected[:dew_point_c], result[:derived][:dew_point_c]
    assert_equal "no_data", LiveWeather.new(Measurement.all, now: @now + 301).call[:status]
  end
end

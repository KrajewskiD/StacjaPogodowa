require_relative "test_helper"

class LiveAnalyticsTest < ActiveSupport::TestCase
  def reading(at, **payload)
    Measurement.create!(sensor_id: "0000DE3E", device_id: "aff734", source_ip: "127.0.0.1",
      received_at: at, payload: payload.transform_keys(&:to_s))
  end

  test "live analytics returns lean trends and rain for every period" do
    now = Time.zone.parse("2026-10-09 12:00")
    reading(now - 40.days, rain_total_mm: 5)
    reading(now - 1.day, rain_total_mm: 6)
    reading(now - 30.minutes, rain_total_mm: 7, temperature_c: 10)
    reading(now, rain_total_mm: 9, temperature_c: 12)

    analytics = WeatherHistory.new(Measurement.all, now: now).live_analytics

    assert_equal %i[rain trends], analytics.keys.sort
    # Opad dzienny nie przypisuje przyrostu z przed północy.
    assert_equal 2.0, analytics[:rain][:today][:mm]
    # Miesiąc sumuje dodatnie przyrosty licznika od początku miesiąca;
    # odległy baseline nie jest liczony jako część okresu.
    assert_equal 3.0, analytics[:rain][:month][:mm]
    assert analytics[:rain][:month][:partial]
    # Brak średnich dziennych — te dostarcza DailyWeather.
    refute analytics.key?(:daily)
  end

  test "trend reflects a 30 minute change when coverage is continuous" do
    now = Time.zone.parse("2026-10-09 12:00")
    (-30..0).each do |minute|
      reading(now + minute.minutes, temperature_c: minute.zero? ? 12 : 10, humidity_pct: 50)
    end
    trends = WeatherHistory.new(Measurement.all, now: now).live_analytics[:trends]
    assert_equal 2.0, trends["1800"]["temperature_c"]
    assert_equal 0.0, trends["1800"]["humidity_pct"]
  end

  test "rain survives a counter reset inside the month" do
    now = Time.zone.parse("2026-10-09 12:00")
    reading(now - 40.minutes, rain_total_mm: 50)
    reading(now - 20.minutes, rain_total_mm: 0)
    reading(now, rain_total_mm: 2)
    result = WeatherHistory.new(Measurement.all, now: now).live_analytics[:rain][:month]
    # Reset licznika (50 → 0) nie jest liczony; do okresu daje się przypisać
    # wyłącznie przyrost po resecie, a przy braku baseline okres jest niepełny.
    assert_equal 2.0, result[:mm]
    assert_equal 1, result[:resets]
    assert result[:partial]
  end
end
require_relative "test_helper"

class WeatherTest < ActionDispatch::IntegrationTest
  setup { host! "localhost" }

  test "Apache can forward a request from the local network" do
    get "/", headers: { "X-Forwarded-Host" => "192.168.100.65:8080" }
    assert_response :success
  end

  def packet(**attributes)
    { "schema" => 1, "type" => "weather", "sensor_id" => "0000DE3E",
      "device_id" => "aff734", "temperature_c" => 23.6,
      "humidity_pct" => 56, "battery_ok" => true }.merge(attributes.transform_keys(&:to_s))
  end

  test "ingestion and dashboard expose actual readings" do
    Measurement.ingest!(packet, source_ip: "192.168.100.69")
    get "/api/weather"
    assert_response :success
    result = response.parsed_body
    assert_equal 23.6, result.dig("latest", "temperature_c")
    assert_not result.key?("selected_sensor")
    assert_equal false, result["stale"]
    assert_equal 1, result["history"].size
    assert_equal "no-store", response.headers["Cache-Control"]
    get "/"
    assert_response :success
    assert_select "h1", text: "Pogoda na żywo."
  end

  test "missing readings and outdated data are not live" do
    get "/api/weather"
    assert_nil response.parsed_body["latest"]
    assert_equal true, response.parsed_body["stale"]
    reading = Measurement.ingest!(packet, source_ip: "127.0.0.1")
    reading.update!(received_at: 2.hours.ago)
    get "/api/weather"
    assert_equal true, response.parsed_body["stale"]
    assert_empty response.parsed_body["history"]
  end

  test "dashboard stays on the assigned sensor even with another ID in the URL" do
    Measurement.ingest!(packet, source_ip: "127.0.0.1")
    Measurement.ingest!(packet(sensor_id: "00001234", temperature_c: -4), source_ip: "127.0.0.1")
    get "/api/weather", params: { sensor_id: "00001234" }
    assert_equal 23.6, response.parsed_body.dig("latest", "temperature_c")
    assert_not response.parsed_body.key?("selected_sensor")
    assert_equal 1, response.parsed_body["total"]
  end

  test "dashboard does not fall back to another sensor" do
    Measurement.ingest!(packet(sensor_id: "00001234"), source_ip: "127.0.0.1")
    get "/api/weather"
    assert_nil response.parsed_body["latest"]
    assert_equal 0, response.parsed_body["total"]
    get "/"
    assert_select "select#sensor", count: 0
  end

  test "malformed radio values do not enter database" do
    [packet(temperature_c: "23"), packet(temperature_c: Float::NAN),
     packet(sensor_id: "<script>"), packet(battery_ok: "yes"), []].each do |invalid|
      assert_no_difference "Measurement.count" do
        assert_raises(ArgumentError) { Measurement.ingest!(invalid, source_ip: "127.0.0.1") }
      end
    end
    assert_nil Measurement.ingest!({ "schema" => 1, "type" => "status" }, source_ip: "127.0.0.1")
  end

  test "partial packet preserves absence of measurements" do
    partial = packet.except("temperature_c", "battery_ok")
    reading = Measurement.ingest!(partial, source_ip: "127.0.0.1")
    assert_not reading.as_reading.key?("temperature_c")
    assert_not reading.as_reading.key?("battery_ok")
  end
end

require_relative "test_helper"

class IngestSecurityTest < ActiveSupport::TestCase
  teardown { IngestPolicy.reset! }

  def weather(**attributes)
    { "schema" => 1, "type" => "weather", "sensor_id" => "0000DE3E",
      "device_id" => "aff734", "temperature_c" => 20 }.merge(attributes.transform_keys(&:to_s))
  end

  test "weather and status reject unknown fields and oversized payloads" do
    error = assert_raises(ArgumentError) { Measurement.ingest!(weather("nieznane" => 1), source_ip: "127.0.0.1") }
    assert_match(/Nieznane pola/, error.message)
    error = assert_raises(ArgumentError) do
      Gateway.observe!({ "schema" => 1, "type" => "status", "device_id" => "aff734", "surprise" => true }, source_ip: "127.0.0.1")
    end
    assert_match(/Nieznane pola/, error.message)
    bulky = weather.merge((1..50).to_h { |i| ["extra_#{i}", i] })
    error = assert_raises(ArgumentError) { Measurement.ingest!(bulky, source_ip: "127.0.0.1") }
    assert_match(/Zbyt duży payload/, error.message)
  end

  test "allowlist rejects foreign sensor and device and is case insensitive" do
    IngestPolicy.instance_variable_set(:@config, { sensors: ["0000DE3E"], devices: ["aff734"] })
    error = assert_raises(ArgumentError) { Measurement.ingest!(weather("sensor_id" => "00001234"), source_ip: "127.0.0.1") }
    assert_match(/Nieznany czujnik/, error.message)
    error = assert_raises(ArgumentError) { Measurement.ingest!(weather("device_id" => "ffffff"), source_ip: "127.0.0.1") }
    assert_match(/Nieznane urządzenie/, error.message)
    error = assert_raises(ArgumentError) do
      Gateway.observe!({ "schema" => 1, "type" => "status", "device_id" => "ffffff" }, source_ip: "127.0.0.1")
    end
    assert_match(/Nieznane urządzenie/, error.message)
    assert Measurement.ingest!(weather("sensor_id" => "0000de3e", "device_id" => "AFF734"), source_ip: "127.0.0.1")
  end
end

class RequestRateLimitTest < ActiveSupport::TestCase
  def build_env(path, ip)
    Rack::MockRequest.env_for(path, "REMOTE_ADDR" => ip)
  end

  test "limits requests per path and ip and leaves other paths unlimited" do
    limiter = RequestRateLimit.new(->(_env) { [200, { "Content-Type" => "text/plain" }, ["ok"]] })
    limit = RequestRateLimit::LIMITS["/api/weather"][0]
    last = nil
    (limit + 2).times { last = limiter.call(build_env("/api/weather", "10.9.9.9")) }
    assert_equal 429, last[0]

    assert_equal 200, limiter.call(build_env("/api/weather", "10.9.9.10"))[0]
    assert_equal 200, limiter.call(build_env("/export.csv", "10.9.9.9"))[0]
  end
end
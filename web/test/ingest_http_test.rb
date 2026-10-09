require_relative "test_helper"

class IngestHttpTest < ActionDispatch::IntegrationTest
  TOKEN = "sekret-urzadzenia".freeze

  setup do
    host! "localhost"
    @previous_token = ENV["INGEST_TOKEN"]
    ENV["INGEST_TOKEN"] = TOKEN
  end

  teardown do
    ENV["INGEST_TOKEN"] = @previous_token
  end

  def auth_headers
    { "Authorization" => "Bearer #{TOKEN}" }
  end

  def weather_hash(overrides = {})
    { schema: 1, type: "weather", sensor_id: "0000DE3E", device_id: "aff734",
      seq: 1, uptime_ms: 1000, temperature_c: 20, humidity_pct: 50, battery_ok: true }
      .merge(overrides)
  end

  test "accepts weather with a valid token and persists it" do
    assert_difference "Measurement.count", 1 do
      post "/api/measurements", params: weather_hash, as: :json, headers: auth_headers
      assert_response :created
    end
    body = response.parsed_body
    assert_equal "0000DE3E", body["sensor_id"]
    assert_not_nil body["id"]
    assert_equal 1, MeasurementDelivery.count
  end

  test "already ingested datagram is idempotent" do
    payload = weather_hash
    post "/api/measurements", params: payload, as: :json, headers: auth_headers
    assert_response :created
    assert_no_difference "Measurement.count" do
      post "/api/measurements", params: payload, as: :json, headers: auth_headers
      assert_response :created
    end
  end

  test "accepts status message and records gateway without a measurement" do
    status = { schema: 1, type: "status", device_id: "aff734", seq: 2, uptime_ms: 2000, radio_ok: true }
    assert_no_difference "Measurement.count" do
      post "/api/measurements", params: status, as: :json, headers: auth_headers
      assert_response :accepted
    end
    assert_equal 1, Gateway.count
  end

  test "rejects missing or invalid token" do
    post "/api/measurements", params: weather_hash, as: :json
    assert_response :unauthorized

    post "/api/measurements", params: weather_hash, as: :json,
         headers: { "Authorization" => "Bearer nieprawidlowy" }
    assert_response :unauthorized
    assert_equal 0, Measurement.count
  end

  test "rejects malformed JSON and malformed measurement" do
    post "/api/measurements", params: "{nie json",
         headers: { "Authorization" => "Bearer #{TOKEN}", "Content-Type" => "application/json" }
    assert_response :bad_request

    assert_no_difference "Measurement.count" do
      post "/api/measurements", params: weather_hash(sensor_id: "<script>"), as: :json, headers: auth_headers
      assert_response :unprocessable_entity
    end
  end

  test "returns 503 when ingestion is not configured" do
    ENV.delete("INGEST_TOKEN")
    post "/api/measurements", params: weather_hash, as: :json, headers: auth_headers
    assert_response :service_unavailable
  end
end
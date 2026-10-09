require_relative "test_helper"

class RecentMeasurementsTest < ActiveSupport::TestCase
  setup do
    ENV["TEST_REDIS"] = "1"
    @redis = RecentMeasurements.redis
    @redis.scan_each(match: "#{RecentMeasurements::PREFIX}:*") { |key| @redis.del(key) }
    @scope = Measurement.where(sensor_id: "0000DE3E")
  end

  teardown do
    @redis.scan_each(match: "#{RecentMeasurements::PREFIX}:*") { |key| @redis.del(key) }
    @redis.close
    RecentMeasurements.reset_client!
    ENV.delete("TEST_REDIS")
  end

  def reading(at = Time.current)
    Measurement.create!(sensor_id: "0000DE3E", device_id: "aff734", source_ip: "127.0.0.1", received_at: at, payload: { "temperature_c" => 12 })
  end

  test "outbox is atomic and Redis retry is idempotent" do
    item = reading
    assert_equal 1, MeasurementDelivery.count
    2.times { RecentMeasurements.write(@redis, item) }
    assert_equal 1, @redis.zcard(RecentMeasurements.key(item.sensor_id))
    RecentMeasurements.drain!(@redis)
    assert_equal 0, MeasurementDelivery.count
    cached = RecentMeasurements.fetch(@scope, from: 1.hour.ago)
    assert_equal [item.id], cached.map(&:id)
    assert_equal 12, cached.first.payload["temperature_c"]
    assert_in_delta item.received_at.to_f, cached.first.received_at.to_f, 0.001
    assert_no_difference ["Measurement.count", "MeasurementDelivery.count"] do
      Measurement.transaction { reading; raise ActiveRecord::Rollback }
    end
  end

  test "repeated datagrams produce one durable record and one outbox entry" do
    data = { "schema" => 1, "type" => "weather", "sensor_id" => "0000DE3E", "device_id" => "aff734",
             "seq" => 12, "uptime_ms" => 3000, "temperature_c" => 12 }
    first = Measurement.ingest!(data, source_ip: "127.0.0.1")
    second = Measurement.ingest!(data, source_ip: "127.0.0.1")
    assert_equal first.id, second.id
    assert_equal 1, Measurement.count
    assert_equal 1, MeasurementDelivery.count
  end

  test "rebuild includes only 72 hours while historical queries read PostgreSQL" do
    old = reading(73.hours.ago)
    fresh = reading(1.hour.ago)
    RecentMeasurements.rebuild!(@redis)
    RecentMeasurements.drain!(@redis)
    assert_equal 1, @redis.zcard(RecentMeasurements.key(fresh.sensor_id))
    assert_equal [fresh.id], RecentMeasurements.fetch(@scope, from: 2.hours.ago).map(&:id)
    assert_equal [old.id, fresh.id], RecentMeasurements.fetch(@scope, from: 74.hours.ago).map(&:id)
  end

  test "missing readiness and failed Redis read fall back to durable measurements" do
    item = reading
    assert_equal [item.id], RecentMeasurements.fetch(@scope, from: 1.hour.ago).map(&:id)
    previous = ENV["REDIS_URL"]
    begin
      ENV["REDIS_URL"] = "redis://127.0.0.1:1/0"
      assert_equal [item.id], RecentMeasurements.fetch(@scope, from: 1.hour.ago).map(&:id)
      assert_raises(Redis::BaseError) { RecentMeasurements.drain!(RecentMeasurements.redis) }
      assert_equal 1, MeasurementDelivery.count
    ensure
      ENV["REDIS_URL"] = previous
    end
    RecentMeasurements.rebuild!(@redis)
    RecentMeasurements.drain!(@redis)
    assert_equal 0, MeasurementDelivery.count
  end

  test "expired measurements are removed without new sensor traffic" do
    item = reading
    RecentMeasurements.drain!(@redis)
    travel 73.hours do
      RecentMeasurements.drain!(@redis)
      assert_equal 0, @redis.zcard(RecentMeasurements.key(item.sensor_id))
      assert Measurement.exists?(item.id)
    end
  end

  test "compact Redis member decodes to a light sample without full AR columns" do
    item = reading(Time.current)
    RecentMeasurements.drain!(@redis)
    raw = @redis.zrange(RecentMeasurements.key(item.sensor_id), 0, -1).first
    refute_includes raw, '"source_ip"'
    refute_includes raw, '"packet_fingerprint"'
    sample = RecentMeasurements.decode(raw)
    assert_equal item.id, sample.id
    assert_equal item.sensor_id, sample.sensor_id
    assert_equal item.device_id, sample.device_id
    assert_equal 12, sample.payload["temperature_c"]
    assert_in_delta item.received_at.to_f, sample.received_at.to_f, 0.001
  end

  test "sync lock is exclusive and renewed only by its owner" do
    a, b = RecentMeasurements.redis, RecentMeasurements.redis
    assert RecentMeasurements.acquire_lock!(a, token: "owner")
    refute RecentMeasurements.acquire_lock!(b, token: "intruder")
    assert RecentMeasurements.renew_lock!(a, token: "owner")
    refute RecentMeasurements.renew_lock!(b, token: "intruder")
    assert_equal 1, RecentMeasurements.release_lock!(a, token: "owner")
    assert RecentMeasurements.acquire_lock!(b, token: "intruder")
    RecentMeasurements.release_lock!(b, token: "intruder")
    a.close
    b.close
  end

  # Zapis poza adapterem AR nie unieważnia jego query cache, tak jak zapis
  # z osobnego procesu odbiornika. Pozostaje w transakcji testowej do rollbacku.
  def external_reading
    connection = ActiveRecord::Base.connection.raw_connection
    row = connection.exec_params(
      "INSERT INTO measurements (sensor_id, device_id, source_ip, received_at, payload) VALUES ($1,$2,$3,$4,$5) RETURNING id",
      ["0000DE3E", "aff734", "127.0.0.1", Time.current.utc.iso8601(6), '{"temperature_c":21}'])
    id = row.first.fetch("id").to_i
    connection.exec_params("INSERT INTO measurement_deliveries (measurement_id) VALUES ($1)", [id])
    id
  end

  test "worker notices new deliveries after caching an empty queue" do
    ActiveRecord::Base.cache do
      assert_empty MeasurementDelivery.order(:id).limit(1000).includes(:measurement).to_a
      assert_not MeasurementDelivery.exists?
      id = external_reading
      # Dowód odtworzenia pierwotnej usterki: cache nadal wskazuje pustą kolejkę.
      assert_not MeasurementDelivery.exists?
      RecentMeasurements.drain!(@redis)
      assert_equal [id], RecentMeasurements.fetch(@scope, from: 1.hour.ago).map(&:id)
      assert_equal 0, MeasurementDelivery.uncached { MeasurementDelivery.count }
    end
  end

  test "readiness cannot hide committed deliveries behind cached empty state" do
    old = reading
    RecentMeasurements.drain!(@redis)
    ActiveRecord::Base.cache do
      assert_not MeasurementDelivery.exists?
      id = external_reading
      assert @redis.exists?("#{RecentMeasurements::PREFIX}:ready")
      assert_equal 1, @redis.zcard(RecentMeasurements.key(old.sensor_id))
      assert_equal [old.id, id], RecentMeasurements.fetch(@scope, from: 1.hour.ago).map(&:id)
      RecentMeasurements.drain!(@redis)
      assert_equal 2, @redis.zcard(RecentMeasurements.key(old.sensor_id))
    end
  end
end

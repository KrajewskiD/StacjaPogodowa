# Redis jest odtwarzalną kopią. PostgreSQL i transakcyjny outbox są źródłem prawdy.
class RecentMeasurements
  RETENTION = 72.hours.to_i
  PREFIX = "stacja:#{Rails.env}:recent:v1".freeze

  # Lekki rekord odczytu z Redis; konsumenci czytają tylko received_at, device_id
  # i payload, więc nie materializujemy pełnych obiektów AR ani wszystkich kolumn.
  Sample = Data.define(:id, :sensor_id, :received_at, :device_id, :payload)

  # Fabryka świeżych klientów dla skryptu synchronizacji i testów,
  # które zarządzają własnym cyklem życia (close).
  def self.redis
    Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6380/0"), connect_timeout: 0.3, read_timeout: 1, write_timeout: 1)
  end

  # Współdzielony, bezpieczny dla wątków klient na ścieżce żądań webowych.
  # redis-client utrzymuje wewnętrzną pulę połączeń, więc jedno wystąpienie
  # wystarcza dla wielowątkowego Puma i nie otwiera nowego połączenia per fetch.
  @client = nil
  @client_mutex = Mutex.new

  def self.client
    @client || @client_mutex.synchronize { @client ||= redis }
  end

  def self.reset_client!
    @client_mutex.synchronize do
      @client&.close
      @client = nil
    end
  end

  def self.key(sensor)
    "#{PREFIX}:sensor:#{sensor}"
  end

  def self.fetch(scope, from:, to: Time.current)
    sensor = scope.where_values_hash["sensor_id"]
    if !Rails.env.test? || ENV["TEST_REDIS"] == "1"
      if sensor && from >= Time.current - RETENTION
        client = self.client
        pending = MeasurementDelivery.uncached { MeasurementDelivery.exists? }
        if !pending && client.exists?("#{PREFIX}:ready") && client.exists?("#{PREFIX}:loaded:#{sensor}")
          return client.zrangebyscore(key(sensor), from.to_f, to.to_f).map { |json|
            decode(json)
          }.sort_by { |r| [r.received_at, r.id] }
        end
      end
    end
    scope.where(received_at: from..to).order(:received_at, :id).to_a
  rescue Redis::BaseError, JSON::ParserError => e
    Rails.logger.warn("Redis read fallback: #{e.class}")
    scope.where(received_at: from..to).order(:received_at, :id).to_a
  end

  def self.write(client, reading, target: key(reading.sensor_id))
    return if reading.received_at < Time.current - RETENTION
    member = JSON.generate(id: reading.id, sensor_id: reading.sensor_id,
                           received_at: reading.received_at.iso8601(6),
                           device_id: reading.device_id, payload: reading.payload)
    client.zadd(target, reading.received_at.to_f, member)
    client.expire(target, RETENTION + 60)
  end

  def self.decode(json)
    data = JSON.parse(json)
    Sample.new(id: data["id"], sensor_id: data["sensor_id"],
               received_at: Time.zone.parse(data["received_at"]),
               device_id: data["device_id"], payload: data["payload"])
  end

  def self.rebuild!(client)
    client.del("#{PREFIX}:ready")
    client.del("#{PREFIX}:built")
    client.scan_each(match: "#{PREFIX}:loaded:*") { |key| client.del(key) }
    sensors = Measurement.distinct.pluck(:sensor_id)
    sensors.each do |sensor|
      temp = "#{key(sensor)}:rebuild"
      client.del(temp)
      Measurement.where(sensor_id: sensor, received_at: (Time.current - RETENTION)..).find_each do |reading|
        write(client, reading, target: temp)
      end
      present = client.exists?(temp)
      client.multi do |tx|
        tx.del(key(sensor))
        tx.rename(temp, key(sensor)) if present
        tx.set("#{PREFIX}:loaded:#{sensor}", "1", ex: RETENTION)
      end
    end
    client.set("#{PREFIX}:built", "1")
  end

  def self.drain!(client)
    MeasurementDelivery.uncached do
      drain_uncached!(client)
    end
  end

  def self.drain_uncached!(client)
    # Kolejka powstaje w tej samej transakcji co pomiar. Usunięcie dopiero po ZADD.
    MeasurementDelivery.order(:id).limit(1000).includes(:measurement).each do |delivery|
      write(client, delivery.measurement)
      client.set("#{PREFIX}:loaded:#{delivery.measurement.sensor_id}", "1", ex: RETENTION)
      delivery.destroy!
    end
    client.scan_each(match: "#{PREFIX}:sensor:*") do |key|
      next if key.end_with?(":rebuild")
      client.zremrangebyscore(key, "-inf", "(#{(Time.current - RETENTION).to_f}")
    end
    # Brak heartbeat wymusza odczyt z PG; zaległa kolejka nie jest kompletna.
    if MeasurementDelivery.exists?
      client.del("#{PREFIX}:ready")
    else
      client.set("#{PREFIX}:ready", "1", ex: 10)
    end
  end

  # ---- Blokada jednej instancji synchronizatora ---------------------------
  LOCK_KEY = "#{PREFIX}:sync:lock".freeze
  LOCK_TTL = 60
  RENEW_LUA = "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('pexpire', KEYS[1], ARGV[2]) else return 0 end".freeze

  def self.acquire_lock!(client, token:)
    client.set(LOCK_KEY, token, nx: true, ex: LOCK_TTL)
  end

  def self.renew_lock!(client, token:)
    client.eval(RENEW_LUA, keys: [LOCK_KEY], argv: [token, LOCK_TTL * 1000]) == 1
  end

  def self.release_lock!(client, token:)
    client.eval("if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
                keys: [LOCK_KEY], argv: [token])
  end

  private_class_method :drain_uncached!
end
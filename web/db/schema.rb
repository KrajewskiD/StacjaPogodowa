# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_09_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "gateway_events", force: :cascade do |t|
    t.integer "gateway_id", null: false
    t.string "kind", null: false
    t.datetime "occurred_at", null: false
    t.index ["gateway_id"], name: "index_gateway_events_on_gateway_id"
  end

  create_table "gateways", force: :cascade do |t|
    t.string "device_id", null: false
    t.datetime "last_seen_at"
    t.bigint "last_sequence"
    t.datetime "last_status_at"
    t.bigint "last_uptime"
    t.integer "missing_packets", default: 0, null: false
    t.json "payload", default: {}, null: false
    t.string "source_ip"
    t.index ["device_id"], name: "index_gateways_on_device_id", unique: true
  end

  create_table "measurement_deliveries", force: :cascade do |t|
    t.bigint "measurement_id", null: false
    t.index ["measurement_id"], name: "index_measurement_deliveries_on_measurement_id", unique: true
  end

  create_table "measurements", force: :cascade do |t|
    t.string "device_id", null: false
    t.string "packet_fingerprint"
    t.json "payload", null: false
    t.datetime "received_at", null: false
    t.string "sensor_id", null: false
    t.string "source_ip", null: false
    t.index ["packet_fingerprint"], name: "index_measurements_on_packet_fingerprint", unique: true
    t.index ["received_at"], name: "index_measurements_on_received_at"
    t.index ["sensor_id", "received_at", "id"], name: "index_measurements_on_sensor_id_received_at_id"
  end

  create_table "station_settings", force: :cascade do |t|
    t.integer "alert_delay_seconds", default: 30, null: false
    t.float "gust_high", default: 15.0, null: false
    t.float "latitude"
    t.float "longitude"
    t.integer "missing_seconds", default: 120, null: false
    t.float "temperature_high", default: 35.0, null: false
    t.float "temperature_low", default: 0.0, null: false
    t.float "uv_high", default: 6.0, null: false
  end

  create_table "weather_alerts", force: :cascade do |t|
    t.boolean "active", default: false, null: false
    t.datetime "clear_pending_since"
    t.string "kind", null: false
    t.datetime "last_confirmed_at"
    t.bigint "last_measurement_id"
    t.datetime "last_observed_at"
    t.string "last_packet_key"
    t.datetime "pending_since"
    t.string "sensor_id", null: false
    t.datetime "triggered_at"
    t.index ["sensor_id", "kind"], name: "index_weather_alerts_on_sensor_id_and_kind", unique: true
  end

  add_foreign_key "gateway_events", "gateways"
  add_foreign_key "measurement_deliveries", "measurements", on_delete: :cascade
end

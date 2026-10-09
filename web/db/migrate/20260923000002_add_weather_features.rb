class AddWeatherFeatures < ActiveRecord::Migration[8.1]
  def change
    create_table :gateways do |t|
      t.string :device_id, null: false
      t.string :source_ip
      t.datetime :last_seen_at
      t.datetime :last_status_at
      t.json :payload, default: {}, null: false
      t.bigint :last_uptime
      t.bigint :last_sequence
      t.integer :missing_packets, default: 0, null: false
    end
    add_index :gateways, :device_id, unique: true
    create_table :gateway_events do |t|
      t.references :gateway, null: false, foreign_key: true
      t.datetime :occurred_at, null: false
      t.string :kind, null: false
    end
    create_table :station_settings do |t|
      t.float :latitude
      t.float :longitude
      t.float :temperature_low, default: 0, null: false
      t.float :temperature_high, default: 35, null: false
      t.float :gust_high, default: 15, null: false
      t.float :uv_high, default: 6, null: false
      t.integer :missing_seconds, default: 120, null: false
      t.integer :alert_delay_seconds, default: 30, null: false
    end
    create_table :weather_alerts do |t|
      t.string :sensor_id, null: false
      t.string :kind, null: false
      t.boolean :active, default: false, null: false
      t.datetime :pending_since
      t.datetime :triggered_at
    end
    add_index :weather_alerts, [:sensor_id, :kind], unique: true
    add_index :measurements, :received_at
  end
end

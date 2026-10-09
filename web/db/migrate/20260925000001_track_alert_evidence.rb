class TrackAlertEvidence < ActiveRecord::Migration[8.1]
  def change
    add_column :weather_alerts, :last_measurement_id, :bigint
    add_column :weather_alerts, :last_packet_key, :string
    add_column :weather_alerts, :last_observed_at, :datetime
    add_column :weather_alerts, :last_confirmed_at, :datetime
    add_column :weather_alerts, :clear_pending_since, :datetime
  end
end

class AddSensorTimelineIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :measurements, [:sensor_id, :received_at, :id],
      name: "index_measurements_on_sensor_id_received_at_id"
    remove_index :measurements, name: "index_measurements_on_sensor_id_and_received_at"
  end
end
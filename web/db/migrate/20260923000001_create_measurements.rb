class CreateMeasurements < ActiveRecord::Migration[8.1]
  def change
    create_table :measurements do |t|
      t.string :sensor_id, null: false
      t.string :device_id, null: false
      t.string :source_ip, null: false
      t.datetime :received_at, null: false
      t.json :payload, null: false
    end
    add_index :measurements, [:sensor_id, :received_at]
  end
end

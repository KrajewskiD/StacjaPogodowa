class DeduplicateMeasurementPackets < ActiveRecord::Migration[8.1]
  def change
    add_column :measurements, :packet_fingerprint, :string
    add_index :measurements, :packet_fingerprint, unique: true
  end
end

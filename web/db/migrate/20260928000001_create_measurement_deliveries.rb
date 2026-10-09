class CreateMeasurementDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :measurement_deliveries do |t|
      t.references :measurement, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
    end
  end
end

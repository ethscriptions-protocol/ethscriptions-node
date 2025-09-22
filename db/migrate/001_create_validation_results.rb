class CreateValidationResults < ActiveRecord::Migration[8.0]
  def change
    create_table :validation_results, id: false do |t|
      t.integer :l1_block, null: false, primary_key: true
      t.boolean :success, null: false
      t.json :error_details
      t.json :validation_stats
      t.datetime :validated_at, null: false

      t.timestamps
    end

    add_index :validation_results, :success
    add_index :validation_results, :validated_at
    add_index :validation_results, [:success, :l1_block]
  end
end
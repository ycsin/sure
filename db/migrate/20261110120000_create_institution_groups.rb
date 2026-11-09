class CreateInstitutionGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :institution_groups, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :key, null: false
      t.string :name
      t.string :institution_domain
      t.string :currency
      t.references :logo_account, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.timestamps
    end

    add_index :institution_groups, [ :family_id, :key ], unique: true
  end
end

class AddOwnSecuritiesToEtoroItems < ActiveRecord::Migration[8.1]
  def change
    add_column :etoro_items, :own_securities, :boolean, default: false, null: false
  end
end

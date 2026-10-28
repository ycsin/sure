# Each currency of a moomoo trading account split by currency is a cash row
# and, when it has positions or trades, a stocks row, each linked to its own
# Sure account. An account that isn't split stays one combined row.
class AddRoleToMoomooAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :moomoo_accounts, :role, :string, null: false, default: "combined"

    remove_index :moomoo_accounts, %i[moomoo_item_id moomoo_account_id currency],
                 name: "index_moomoo_accounts_on_item_account_id_and_currency", unique: true, where: "moomoo_account_id IS NOT NULL"
    add_index :moomoo_accounts, %i[moomoo_item_id moomoo_account_id currency role],
              name: "index_moomoo_accounts_on_item_account_id_currency_and_role", unique: true,
              where: "moomoo_account_id IS NOT NULL"
  end
end

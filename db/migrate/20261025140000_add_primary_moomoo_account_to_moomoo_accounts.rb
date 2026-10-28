# A moomoo trading account that holds more than one currency becomes one row
# per currency: the primary row, in the account's home currency, holds
# moomoo's data, and each other currency's row points at it.
class AddPrimaryMoomooAccountToMoomooAccounts < ActiveRecord::Migration[8.1]
  def change
    add_reference :moomoo_accounts, :primary_moomoo_account, type: :uuid, foreign_key: { to_table: :moomoo_accounts }

    remove_index :moomoo_accounts, %i[moomoo_item_id moomoo_account_id],
                 name: "index_moomoo_accounts_on_item_and_account_id", unique: true, where: "moomoo_account_id IS NOT NULL"
    add_index :moomoo_accounts, %i[moomoo_item_id moomoo_account_id],
              name: "index_moomoo_accounts_on_item_and_account_id", unique: true,
              where: "moomoo_account_id IS NOT NULL AND primary_moomoo_account_id IS NULL"
    add_index :moomoo_accounts, %i[moomoo_item_id moomoo_account_id currency],
              name: "index_moomoo_accounts_on_item_account_id_and_currency", unique: true,
              where: "moomoo_account_id IS NOT NULL"
  end
end

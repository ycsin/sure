class EtoroAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  if encryption_ready?
    encrypts :raw_positions_payload
    encrypts :raw_trades_payload
    encrypts :raw_balance_history_payload
  end

  belongs_to :etoro_item

  # How the account shows in Sure. As holdings, each security eToro holds is
  # a holding and each position's opening and closes are trades. As totals,
  # the account follows eToro's daily total and cash, and whatever is not cash
  # is one holding (see EtoroAccount::TotalsProcessor). A change takes effect
  # on the next sync, which rebuilds the account from the stored payloads.
  enum :display_mode, { holdings: "holdings", totals: "totals" }, prefix: :shown_as, default: :holdings, validate: true

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :currency, presence: true
  validates :etoro_account_id, uniqueness: { scope: :etoro_item_id, allow_nil: true }

  def current_account
    account || linked_account
  end

  def ensure_account_provider!(account = nil)
    if account_provider.present?
      account_provider.update!(account: account) if account && account_provider.account_id != account.id
      return account_provider
    end

    acct = account || current_account
    return nil unless acct

    provider = AccountProvider
      .find_or_initialize_by(provider_type: "EtoroAccount", provider_id: id)
      .tap do |record|
        record.account = acct
        record.save!
      end

    reload_account_provider
    provider
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "warn",
      message: "EtoroAccount##{id}: failed to ensure AccountProvider link: #{e.class} - #{e.message}",
      source: "etoro",
      family: etoro_item.family,
      provider_key: "etoro"
    )
    nil
  end

  def instruments_map
    etoro_item.instruments_map
  end
end

# frozen_string_literal: true

class TricountAccount < ApplicationRecord
  include CurrencyNormalizable
  include TricountAccount::DataHelpers

  belongs_to :tricount_item

  # Association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  # A sharing token grants write access to its tricount, so it stays in the
  # encrypted TricountItem#sharing_tokens and out of the stored snapshots.
  CREDENTIAL_KEYS = %w[public_identifier_token].freeze

  validates :name, :currency, presence: true

  # Scopes
  scope :with_linked, -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :ordered, -> { order(created_at: :desc) }

  # Callbacks
  after_destroy :enqueue_connection_cleanup

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Idempotently create or update AccountProvider link
  # CRITICAL: After creation, reload association to avoid stale nil
  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    # Reload to clear cached nil value
    reload_account_provider
    account_provider
  end

  # Stores a tricount (a registry payload, memberships and entries included).
  # The entries are kept whole, so an expense deleted in Tricount leaves the
  # snapshot and its transactions with it.
  def upsert_from_tricount!(registry)
    entries = Array(registry["all_registry_entry"]).map { |entry| TricountAccount::Ledger.unwrap(entry) }

    assign_attributes(
      tricount_account_id: (registry["uuid"].presence || registry["id"]).to_s,
      name: registry["title"].presence || registry["uuid"].to_s,
      currency: parse_currency(registry["currency"]) || currency || "EUR",
      account_status: registry["status"],
      account_type: "tricount",
      provider: "tricount",
      institution_metadata: TricountItem::INSTITUTION.transform_keys(&:to_s),
      raw_payload: without_credentials(registry.except("all_registry_entry")),
      raw_transactions_payload: without_credentials(entries)
    )
    self.member_uuid = nil if member_uuid.present? && members.none? { |member| member.uuid == member_uuid }
    self.current_balance = member_uuid.present? ? ledger.balance_for(member_uuid) : nil
    save!
  end

  # The tricount's members, for choosing which one is the account's owner.
  def members
    TricountAccount::Ledger.members_from(raw_payload)
  end

  def member
    members.find { |candidate| candidate.uuid == member_uuid }
  end

  def ledger
    TricountAccount::Ledger.new(raw_transactions_payload)
  end

  # Expenses, incomes and transfers still in the tricount (deleted ones left out).
  def active_entry_count
    ledger.active_entries.size
  end

  # Chooses the member whose position this account follows.
  def assign_member!(uuid)
    raise ArgumentError, "Unknown Tricount member" unless members.any? { |candidate| candidate.uuid == uuid }

    update!(member_uuid: uuid, current_balance: ledger.balance_for(uuid))
  end

  private

    def without_credentials(value)
      case value
      when Hash then value.except(*CREDENTIAL_KEYS).transform_values { |nested| without_credentials(nested) }
      when Array then value.map { |nested| without_credentials(nested) }
      else value
      end
    end

    def enqueue_connection_cleanup
      return unless tricount_item

      TricountConnectionCleanupJob.perform_later(
        tricount_item_id: tricount_item.id,
        account_id: id
      )
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Tricount account #{id}, keeping #{currency || "EUR"}")
    end
end

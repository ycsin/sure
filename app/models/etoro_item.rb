class EtoroItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable, DestroyableLater

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :user_key
    encrypts :raw_instruments_payload
  end

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later
  has_many :etoro_accounts, dependent: :destroy

  validates :api_key, presence: true, on: :create
  validates :user_key, presence: true, on: :create

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active.where.not(api_key: [ nil, "" ]) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }

  def credentials_configured?
    api_key.present? && user_key.present?
  end

  def import_latest_data
    provider = etoro_provider
    raise StandardError, "eToro provider is not configured" unless provider

    EtoroItem::Importer.new(self, provider: provider).import
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "EtoroItem #{id} - Failed to import data: #{e.message}",
      source: "etoro",
      family: family,
      provider_key: "etoro"
    )
    raise
  end

  def process_accounts
    return [] if etoro_accounts.empty?

    linked_etoro_accounts.includes(account_provider: :account).each_with_object([]) do |etoro_account, results|
      account = etoro_account.current_account
      next unless account
      next if account.pending_deletion? || account.disabled?

      begin
        result = EtoroAccount::Processor.new(etoro_account).process
        results << { etoro_account_id: etoro_account.id, success: true, result: result }
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "EtoroItem #{id} - Failed to process account #{etoro_account.id}: #{e.message}",
          source: "etoro",
          family: family,
          provider_key: "etoro",
          account_provider_id: etoro_account.account_provider&.id
        )
        results << { etoro_account_id: etoro_account.id, success: false, error: e.message }
      end
    end
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    accounts.reject { |account| account.pending_deletion? || account.disabled? }.each_with_object([]) do |account, results|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "EtoroItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}",
          source: "etoro",
          family: family,
          provider_key: "etoro",
          account_id: account.id
        )
        results << { account_id: account.id, success: false, error: e.message }
      end
    end
  end

  def accounts
    etoro_accounts.includes(account_provider: :account).filter_map(&:current_account).uniq
  end

  def linked_etoro_accounts
    etoro_accounts.joins(:account_provider)
  end

  def linked_accounts_count
    etoro_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    etoro_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    etoro_accounts.count
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total.zero?
      I18n.t("etoro_items.sync_status.no_accounts")
    elsif unlinked.zero?
      I18n.t("etoro_items.sync_status.all_linked", count: linked)
    else
      I18n.t("etoro_items.sync_status.partial", linked: linked, unlinked: unlinked)
    end
  end

  def institution_display_name
    I18n.t("etoro_items.defaults.name")
  end

  # eToro instrument metadata keyed by instrument ID (as a string).
  def instruments_map
    raw_instruments_payload.is_a?(Hash) ? raw_instruments_payload : {}
  end
end

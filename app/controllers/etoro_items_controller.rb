class EtoroItemsController < ApplicationController
  before_action :set_etoro_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]
  before_action :require_admin!, only: [ :create, :select_accounts, :select_existing_account, :link_existing_account, :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  def create
    @etoro_item = Current.family.etoro_items.build(etoro_item_params)
    @etoro_item.name ||= t("settings.providers.etoro_panel.default_account_name")

    if @etoro_item.save
      @etoro_item.sync_later

      redirect_to accounts_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("etoro", alert: @etoro_item.errors.full_messages.join(", "))
    end
  end

  def update
    attrs = etoro_item_params.to_h
    attrs["api_key"] = @etoro_item.api_key if attrs["api_key"].blank?
    attrs["user_key"] = @etoro_item.user_key if attrs["user_key"].blank?

    if @etoro_item.update(attrs.merge(status: :good))
      @etoro_item.sync_later unless @etoro_item.syncing?

      render_provider_panel("etoro", notice: t(".success"), fallback_path: accounts_path)
    else
      render_provider_panel("etoro", alert: @etoro_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @etoro_item.unlink_all!(dry_run: false)
    @etoro_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    @etoro_item.sync_later unless @etoro_item.syncing?
    return render_provider_panel("etoro", notice: t("settings.providers.sync_provider_in_progress")) if provider_panel_form?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def select_accounts
    item = current_etoro_item
    unless item
      frame_redirect_to settings_providers_path, alert: t(".not_configured")
      return
    end

    redirect_to setup_accounts_etoro_item_path(item)
  end

  def select_existing_account
    @account = Current.user.accessible_accounts.find(params[:account_id])
    # require_admin! checks the family role, not this account: an admin who
    # neither owns it nor holds full_control must not link it.
    return unless require_account_permission!(@account, :write, redirect_path: accounts_path)

    @available_etoro_accounts = Current.family.etoro_items
      .includes(etoro_accounts: { account_provider: :account })
      .flat_map(&:etoro_accounts)
      .select { |etoro_account| etoro_account.account_provider.nil? }
      .sort_by { |etoro_account| etoro_account.updated_at || etoro_account.created_at }
      .reverse

    render :select_existing_account, layout: false
  end

  def link_existing_account
    account = Current.user.accessible_accounts.find_by(id: params[:account_id])
    etoro_account = Current.family.etoro_items
      .joins(:etoro_accounts)
      .where(etoro_accounts: { id: params[:etoro_account_id] })
      .first
      &.etoro_accounts
      &.find_by(id: params[:etoro_account_id])

    if account.blank? || etoro_account.blank?
      redirect_to settings_providers_path, alert: t(".not_found")
      return
    end

    # Same guard as select_existing_account, ahead of the link it would create.
    return unless require_account_permission!(account, :write, redirect_path: accounts_path)

    if account.accountable_type != "Investment" || account.account_providers.any? || account.plaid_account_id.present? || account.simplefin_account_id.present?
      redirect_to account_path(account), alert: t(".only_manual_investment")
      return
    end

    provider = nil

    etoro_account.with_lock do
      if etoro_account.current_account.present?
        redirect_to account_path(account), alert: t(".already_linked")
        return
      end

      provider = etoro_account.ensure_account_provider!(account)
    end

    raise "Failed to create AccountProvider link" unless provider

    begin
      EtoroAccount::Processor.new(etoro_account.reload).process
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "Failed to process linked eToro account #{etoro_account.id}: #{e.class} - #{e.message}",
        source: "etoro",
        family: Current.family,
        account_provider: etoro_account.account_provider,
        provider_key: "etoro"
      )
    end

    etoro_account.etoro_item.sync_later unless etoro_account.etoro_item.syncing?
    redirect_to account_path(account), notice: t(".success"), status: :see_other
  rescue => e
    DebugLogEntry.capture(
      category: "sync",
      level: "error",
      message: "Failed to link existing eToro account: #{e.class} - #{e.message}",
      source: "etoro",
      family: Current.family,
      provider_key: "etoro"
    )
    redirect_to settings_providers_path, alert: t(".failed"), status: :see_other
  end

  def setup_accounts
    @etoro_accounts = @etoro_item.etoro_accounts.includes(account_provider: :account)
    @linked_accounts = @etoro_accounts.select { |a| a.current_account.present? }
    @unlinked_accounts = @etoro_accounts.reject { |a| a.current_account.present? }

    no_accounts = @linked_accounts.blank? && @unlinked_accounts.blank?
    latest_sync = @etoro_item.syncs.ordered.first
    should_sync = latest_sync.nil? || !latest_sync.completed?

    if no_accounts && !@etoro_item.syncing? && should_sync
      @etoro_item.sync_later
    end

    # Linking manages the account, so only the ones this user may write to.
    @linkable_accounts = Current.family.accounts
      .visible_manual
      .writable_by(Current.user)
      .where(accountable_type: "Investment")
      .order(:name)

    @syncing = @etoro_item.syncing?
    @waiting_for_sync = no_accounts && @syncing
    @no_accounts_found = no_accounts && !@syncing && @etoro_item.last_synced_at.present?
  end

  def complete_account_setup
    selected_accounts = Array(params[:account_ids]).reject(&:blank?)
    created_accounts = []

    selected_accounts.each do |etoro_account_id|
      etoro_account = @etoro_item.etoro_accounts.find_by(id: etoro_account_id)
      next unless etoro_account

      etoro_account.with_lock do
        next if etoro_account.current_account.present?

        account = Account.create_from_etoro_account(etoro_account)
        etoro_account.ensure_account_provider!(account)
        created_accounts << account
      end

      begin
        EtoroAccount::Processor.new(etoro_account.reload).process
      rescue => e
        DebugLogEntry.capture(
          category: "sync",
          level: "error",
          message: "Failed to process eToro account #{etoro_account.id} after setup: #{e.class} - #{e.message}",
          source: "etoro",
          family: Current.family,
          account_provider: etoro_account.account_provider,
          provider_key: "etoro"
        )
      end
    end

    @etoro_item.update!(pending_account_setup: @etoro_item.unlinked_accounts_count.positive?)
    @etoro_item.sync_later if created_accounts.any?

    if created_accounts.any?
      redirect_to accounts_path, notice: t(".success", count: created_accounts.count), status: :see_other
    elsif selected_accounts.empty?
      redirect_to setup_accounts_etoro_item_path(@etoro_item), alert: t(".none_selected"), status: :see_other
    else
      redirect_to setup_accounts_etoro_item_path(@etoro_item), alert: t(".none_created"), status: :see_other
    end
  end

  private

    def set_etoro_item
      @etoro_item = Current.family.etoro_items.find(params[:id])
    end

    def current_etoro_item
      active_items = Current.family.etoro_items.active
      active_items.syncable.ordered.first || active_items.ordered.first
    end

    def etoro_item_params
      params.require(:etoro_item).permit(:api_key, :user_key)
    end
end

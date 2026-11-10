# frozen_string_literal: true

class TricountItemsController < ApplicationController
  before_action :require_admin!
  before_action :set_tricount_item, only: [ :update, :destroy, :sync, :setup_accounts, :complete_account_setup ]

  # Starts following the tricounts behind the links given. A family has one
  # Tricount connection; adding more links later goes through #update.
  def create
    @tricount_item = Current.family.tricount_items.build(name: t(".default_name"))
    unreadable = @tricount_item.add_sharing_links(sharing_links_param)

    if unreadable.any? || @tricount_item.sharing_token_list.empty?
      render_provider_panel("tricount", alert: t(".invalid_links"))
    elsif @tricount_item.save
      @tricount_item.sync_later
      redirect_to settings_providers_path, notice: t(".success"), status: :see_other
    else
      render_provider_panel("tricount", alert: @tricount_item.errors.full_messages.join(", "))
    end
  end

  def update
    unreadable = @tricount_item.add_sharing_links(sharing_links_param)

    if unreadable.any?
      render_provider_panel("tricount", alert: t(".invalid_links"))
    elsif @tricount_item.save
      @tricount_item.sync_later unless @tricount_item.syncing?
      render_provider_panel("tricount", notice: t(".success"))
    else
      render_provider_panel("tricount", alert: @tricount_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @tricount_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success"), status: :see_other
  end

  def sync
    @tricount_item.sync_later unless @tricount_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  # Adding a Tricount account from the accounts page: every tricount needs its
  # member chosen, so all of these lead to the setup page.

  def preload_accounts
    tricount_item = configured_item
    return frame_redirect_to(settings_providers_path, alert: t(".no_credentials_configured")) unless tricount_item

    tricount_item.sync_later unless tricount_item.syncing?
    frame_redirect_to setup_accounts_tricount_item_path(tricount_item)
  end

  def select_accounts
    tricount_item = configured_item
    return frame_redirect_to(settings_providers_path, alert: t(".no_credentials_configured")) unless tricount_item

    frame_redirect_to setup_accounts_tricount_item_path(tricount_item)
  end

  def link_accounts
    tricount_item = configured_item
    return redirect_to(settings_providers_path, alert: t(".no_credentials_configured")) unless tricount_item

    redirect_to setup_accounts_tricount_item_path(tricount_item)
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    # Family scoping alone would let an admin link a co-member's account they
    # only hold read_write on.
    return unless require_account_permission!(@account, :write, redirect_path: accounts_path)

    @tricount_item = configured_item
    return frame_redirect_to(settings_providers_path, alert: t(".no_credentials_configured")) unless @tricount_item

    @tricount_accounts = @tricount_item.unlinked_tricount_accounts.order(:name)
  end

  def link_existing_account
    account = Current.family.accounts.find(params[:account_id])
    return unless require_account_permission!(account, :write, redirect_path: accounts_path)

    tricount_item = configured_item
    return redirect_to(settings_providers_path, alert: t(".no_credentials_configured")) unless tricount_item

    tricount_account = tricount_item.tricount_accounts.find(params[:tricount_account_id])
    if tricount_account.account_provider.present?
      return redirect_to(account_path(account), alert: t(".provider_account_already_linked"))
    end
    unless account.accountable_type.in?(Provider::TricountAdapter.supported_account_types)
      return redirect_to(account_path(account), alert: t(".unsupported_account_type"))
    end

    tricount_account.assign_member!(params[:member_uuid])
    tricount_account.ensure_account_provider!(account)
    account.update!(institution_domain: TricountItem::INSTITUTION[:domain]) if account.read_attribute(:institution_domain).blank?
    tricount_item.sync_later unless tricount_item.syncing?

    redirect_to account_path(account), notice: t(".success", account_name: account.name)
  rescue ArgumentError
    redirect_to account_path(account), alert: t(".member_required")
  end

  def setup_accounts
    @unlinked_accounts = @tricount_item.unlinked_tricount_accounts.order(:name)

    redirect_to accounts_path, notice: t(".all_accounts_linked") if @unlinked_accounts.empty? && !@tricount_item.syncing?
  end

  # Creates a cash account for each tricount chosen, following the member
  # chosen for it.
  def complete_account_setup
    configs = params.fetch(:accounts, {}).to_unsafe_h
    chosen = configs.select { |_id, config| config["import"] == "1" }
    return redirect_to(setup_accounts_tricount_item_path(@tricount_item), alert: t(".no_accounts")) if chosen.empty?

    if chosen.any? { |_id, config| config["member_uuid"].blank? }
      return redirect_to(setup_accounts_tricount_item_path(@tricount_item), alert: t(".member_required"))
    end

    @tricount_item.update!(prefix_account_names: params[:prefix_account_names] == "1")

    created = 0
    chosen.each do |tricount_account_id, config|
      tricount_account = @tricount_item.unlinked_tricount_accounts.find_by(id: tricount_account_id)
      next unless tricount_account

      TricountAccount.transaction do
        tricount_account.assign_member!(config["member_uuid"])
        account = Current.family.accounts.create!(
          name: @tricount_item.account_name_for(tricount_account),
          balance: tricount_account.current_balance || 0,
          currency: tricount_account.currency,
          institution_name: TricountItem::INSTITUTION[:name],
          institution_domain: TricountItem::INSTITUTION[:domain],
          accountable: Depository.new
        )
        tricount_account.ensure_account_provider!(account)
      end
      created += 1
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      Rails.logger.error "TricountItemsController#complete_account_setup - #{e.class}"
    end

    if created.positive?
      @tricount_item.sync_later unless @tricount_item.syncing?
      redirect_to accounts_path, notice: t(".success", count: created)
    else
      redirect_to setup_accounts_tricount_item_path(@tricount_item), alert: t(".creation_failed")
    end
  end

  private

    def set_tricount_item
      @tricount_item = Current.family.tricount_items.find(params[:id])
    end

    def configured_item
      Current.family.tricount_items.active.find(&:credentials_configured?)
    end

    def sharing_links_param
      params.require(:tricount_item).permit(:sharing_links)[:sharing_links]
    end
end

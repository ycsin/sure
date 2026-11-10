# The page of an institution bundle: the accounts the sidebar shows as one
# entry, with their combined balance chart and their activity merged, and the
# settings (InstitutionGroup) of its name, domain, icon and currency.
class InstitutionGroupsController < ApplicationController
  include Periodable

  before_action :require_non_guest!, only: %i[edit update]
  before_action :set_bundle

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.accounts"), accounts_path ],
      [ @bundle.name, nil ]
    ]
    @chart_period = chart_period
    @series = @bundle.balance_series(period: @chart_period)
    # A range dragged on the chart (a custom period) narrows the activity too;
    # a preset period only changes the chart.
    @activity_range = @period if @period.key.blank?

    entries = Entry.where(account_id: @bundle.accounts.map(&:id))
      .excluding_split_parents
      .reverse_chronological
      .includes(:account, :entryable)
    entries = entries.where(date: @activity_range.date_range) if @activity_range

    @pagy, @entries = pagy(entries, limit: safe_per_page)
    preload_entry_rows
  end

  # The bundle's sidebar sparkline, like an account's (AccountsController#sparkline):
  # a URL carrying the current version can't go stale, so the browser may reuse it.
  def sparkline
    version = @bundle.sparkline_version
    expires_in 1.day if params[:v] == version
    if stale?(etag: [ "institution_group_sparkline", version, Date.current ])
      @sparkline_series = @bundle.sparkline_series
      render layout: false
    end
  end

  def edit
    @institution_group = settings
  end

  def update
    @institution_group = settings
    @institution_group.assign_attributes(institution_group_params)
    @institution_group.member_accounts = @bundle.accounts

    if @institution_group.save
      flash[:notice] = t(".success")
      respond_to do |format|
        format.html { redirect_to institution_group_path(@bundle) }
        format.turbo_stream { render turbo_stream: turbo_stream.action(:redirect, institution_group_path(@bundle)) }
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private
    # Only a bundle among the accounts the user can see: the balance sheet is
    # built from them.
    def set_bundle
      @bundle = Current.family.balance_sheet.institution_bundle(params[:slug].to_s)
      raise ActiveRecord::RecordNotFound unless @bundle
    end

    def settings
      Current.family.institution_groups.find_or_initialize_by(key: @bundle.key)
    end

    def institution_group_params
      params.require(:institution_group).permit(:name, :institution_domain, :currency, :logo_account_id)
    end

    # "All" starts where the oldest of the accounts' histories does, as on an
    # account's chart.
    def chart_period
      start_date = @bundle.history_start_date if @period.key == "all_time"
      return @period unless start_date && start_date > @period.start_date

      Period.new(key: "all_time", start_date: start_date, end_date: @period.end_date)
    end

    # What the entry rows read, loaded for the page at once (as on an account's activity).
    def preload_entry_rows
      @accessible_account_ids = Current.user.accessible_accounts.pluck(:id).to_set

      transactions = @entries.filter_map { |entry| entry.entryable if entry.transaction? }
      if transactions.any?
        ActiveRecord::Associations::Preloader.new(
          records: transactions,
          associations: [
            :category, :tags, { merchant: { logo_attachment: :blob } },
            { transfer_as_outflow: { inflow_transaction: { entry: :account } } },
            { transfer_as_inflow: { inflow_transaction: { entry: :account }, outflow_transaction: [ :category, { entry: :account } ] } }
          ]
        ).call
      end

      trades = @entries.filter_map { |entry| entry.entryable if entry.entryable_type == "Trade" }
      ActiveRecord::Associations::Preloader.new(records: trades, associations: [ :security ]).call if trades.any?

      Transaction::ActivitySecurityPreloader.new(@entries).preload
      @transfer_hint_transaction_ids = Current.family.transaction_ids_with_transfer_candidates(transactions, user: Current.user)
      @split_parent_entry_ids = Entry.split_parent_ids_among(@entries.map(&:id))

      split_parent_ids = Current.user.show_split_grouped? ? @entries.filter_map(&:parent_entry_id).uniq : []
      @split_parents = if split_parent_ids.any?
        Entry.where(id: split_parent_ids)
             .includes(:account, entryable: [ :category, { merchant: { logo_attachment: :blob } } ])
             .index_by(&:id)
      else
        {}
      end
    end
end

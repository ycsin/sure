class TransferMatchesController < ApplicationController
  before_action :set_entry

  def new
    # Preloaded for the logo selects, which call Account#logo_url per option.
    @accounts = Current.family.accounts.writable_by(Current.user).visible.alphabetically.where.not(id: @entry.account_id)
      .includes(:account_providers, logo_attachment: :blob)
    @candidate_entries = writable_candidate_entries
  end

  def create
    return unless require_account_permission!(@entry.account, redirect_path: transactions_path)

    target_account = resolve_target_account
    return unless require_account_permission!(target_account, redirect_path: transactions_path)

    @transfer = build_transfer
    unless @transfer
      redirect_back_or_to transactions_path, alert: t(".invalid_target_amount", currency: target_account.currency)
      return
    end

    Transfer.transaction do
      @transfer.save!
      @transfer.confirm!
    end

    @transfer.sync_account_later

    redirect_back_or_to transactions_path, notice: t(".success")
  end

  # "Not a transfer" on the list's transfer hint.
  def destroy
    return unless require_account_permission!(@entry.account, redirect_path: transactions_path)

    Current.family.dismiss_transfer_hint!(@entry.transaction, user: Current.user)

    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove(helpers.dom_id(@entry.transaction, :transfer_hint)) }
      format.html { redirect_back_or_to transactions_path }
    end
  end

  private
    def set_entry
      @entry = Current.accessible_entries.find(params[:transaction_id])
    end

    # Counterpart entries of the family-wide candidates, in candidate order and
    # limited to accounts the user can write to (create would reject the others
    # anyway).
    def writable_candidate_entries
      counterpart_ids = @entry.transaction.transfer_match_candidates.map do |candidate|
        @entry.amount.negative? ? candidate.outflow_transaction_id : candidate.inflow_transaction_id
      end

      entries_by_transaction_id = Entry
        .where(entryable_type: "Transaction", entryable_id: counterpart_ids, account_id: @accounts.map(&:id))
        .includes(account: [ :account_providers, { logo_attachment: :blob } ])
        .index_by(&:entryable_id)

      counterpart_ids.filter_map { |id| entries_by_transaction_id[id] }
    end

    def transfer_match_params
      params.require(:transfer_match).permit(:method, :matched_entry_id, :target_account_id, :use_target_currency, :target_amount)
    end

    def resolve_target_account
      if transfer_match_params[:method] == "new"
        accessible_accounts.find(transfer_match_params[:target_account_id])
      else
        Current.accessible_entries.find(transfer_match_params[:matched_entry_id]).account
      end
    end

    def build_transfer
      if transfer_match_params[:method] == "new"
        target_account = accessible_accounts.find(transfer_match_params[:target_account_id])
        amount, currency = new_counterpart_amount_and_currency(target_account)
        return nil unless amount

        missing_transaction = Transaction.new(
          entry: target_account.entries.build(
            amount: amount,
            currency: currency,
            date: @entry.date,
            name: "Transfer to #{@entry.amount.negative? ? @entry.account.name : target_account.name}",
            user_modified: true,
          )
        )

        transfer = Transfer.find_or_initialize_by(
          inflow_transaction: @entry.amount.positive? ? missing_transaction : @entry.transaction,
          outflow_transaction: @entry.amount.positive? ? @entry.transaction : missing_transaction
        )
        transfer.status = "confirmed"
        transfer
      else
        target_transaction = Current.accessible_entries.find(transfer_match_params[:matched_entry_id])

        transfer = Transfer.find_or_initialize_by(
          inflow_transaction: @entry.amount.negative? ? @entry.transaction : target_transaction.transaction,
          outflow_transaction: @entry.amount.negative? ? target_transaction.transaction : @entry.transaction
        )
        transfer.status = "confirmed"
        transfer
      end
    end

    # The new counterpart mirrors the transaction being matched. In an account
    # of another currency it is recorded, if asked, in that account's currency
    # at the amount given (what actually arrived or left there), the way a
    # transfer between accounts of different currencies is, rounded to that
    # currency's precision. Nil when that amount is missing or not positive
    # once rounded.
    def new_counterpart_amount_and_currency(target_account)
      in_target_currency = target_account.currency != @entry.currency &&
        ActiveModel::Type::Boolean.new.cast(transfer_match_params[:use_target_currency])
      return [ @entry.amount * -1, @entry.currency ] unless in_target_currency

      target_amount = BigDecimal(transfer_match_params[:target_amount].to_s.strip, exception: false)
      target_amount = target_amount&.round(Money::Currency.new(target_account.currency).default_precision)
      return nil unless target_amount&.positive?

      [ @entry.amount.positive? ? -target_amount : target_amount, target_account.currency ]
    end
end

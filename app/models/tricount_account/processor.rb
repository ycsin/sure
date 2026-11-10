# frozen_string_literal: true

class TricountAccount::Processor
  include TricountAccount::DataHelpers

  attr_reader :tricount_account

  def initialize(tricount_account)
    @tricount_account = tricount_account
  end

  def process
    account = tricount_account.current_account
    return unless account

    Rails.logger.info "TricountAccount::Processor - Processing account #{tricount_account.id} -> Sure account #{account.id}"

    # Update account balance FIRST (before processing transactions/holdings/activities)
    update_account_balance(account)

    # Run even when the tricount has no entries left, so transactions of
    # entries deleted in Tricount are removed.
    result = TricountAccount::Transactions::Processor.new(tricount_account).process

    # Trigger immediate UI refresh so entries appear in the activity feed
    account.broadcast_sync_complete
    Rails.logger.info "TricountAccount::Processor - Broadcast sync complete for account #{account.id}"

    { transactions_processed: result[:total].positive?, transactions_removed: result[:removed], transactions_failed: result[:failed] }
  end

  private

    def update_account_balance(account)
      # What the group owes the owner; negative when the owner owes the group.
      balance = tricount_account.current_balance || 0

      Rails.logger.info "TricountAccount::Processor - Balance update: #{balance}"

      account.assign_attributes(
        balance: balance,
        cash_balance: balance,
        currency: tricount_account.currency || account.currency
      )
      account.save!

      # Create or update the current balance anchor valuation for linked accounts
      # This is critical for reverse sync to work correctly
      account.set_current_balance(balance)
    end
end

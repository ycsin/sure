# frozen_string_literal: true

# Brings in the tricounts a connection follows: synchronises its sharing tokens
# to the connection's device, then reads each tricount whole (members and
# entries). Tricounts are small, so every sync reads every entry, and an entry
# deleted in Tricount drops out of the stored snapshot.
class TricountItem::Importer
  include SyncStats::Collector

  attr_reader :tricount_item, :tricount_provider, :sync

  def initialize(tricount_item, tricount_provider:, sync: nil)
    @tricount_item = tricount_item
    @tricount_provider = tricount_provider
    @sync = sync
  end

  def import
    tokens = tricount_item.sharing_token_list
    tricount_provider.synchronize!(tokens)
    count_request

    seen_ids = tokens.filter_map { |token| import_tricount(token) }
    prune_unfollowed_accounts(seen_ids) if stats.fetch("errors", []).empty?

    persist_stats!
    tricount_item.update!(status: :good) if tricount_item.requires_update?
    tricount_item.upsert_tricount_snapshot!(stats)
  rescue Provider::Tricount::AuthenticationError
    tricount_item.update!(status: :requires_update)
    raise
  end

  private

    def stats
      @stats ||= {}
    end

    def count_request
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1
    end

    def persist_stats!
      return unless sync&.respond_to?(:sync_stats)

      sync.update_columns(sync_stats: (sync.sync_stats || {}).merge(stats))
    end

    # Returns the tricount's id, or nil when it could not be read.
    def import_tricount(token)
      registry = tricount_provider.registry(token)
      count_request

      if registry.blank?
        stats["tricounts_missing"] = stats.fetch("tricounts_missing", 0) + 1
        return nil
      end

      tricount_id = (registry["uuid"].presence || registry["id"]).to_s
      tricount_account = tricount_item.tricount_accounts.find_or_initialize_by(tricount_account_id: tricount_id)
      tricount_account.upsert_from_tricount!(registry)

      stats["tricounts_imported"] = stats.fetch("tricounts_imported", 0) + 1
      stats["entries_found"] = stats.fetch("entries_found", 0) + tricount_account.raw_transactions_payload.size
      tricount_id
    rescue Provider::Tricount::AuthenticationError
      raise
    rescue => e
      Rails.logger.error "TricountItem::Importer - Failed to import a tricount for item #{tricount_item.id}: #{e.class}"
      register_error(e)
      nil
    end

    # A tricount whose link was removed from the connection is dropped, unless
    # an account is linked to it: that account keeps the history it has.
    def prune_unfollowed_accounts(seen_ids)
      tricount_item.unlinked_tricount_accounts.where.not(tricount_account_id: seen_ids).destroy_all
    end

    def register_error(error)
      stats["errors"] ||= []
      stats["errors"] << { message: error.message, context: "tricount", timestamp: Time.current.iso8601 }
    end
end

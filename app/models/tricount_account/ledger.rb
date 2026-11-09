# frozen_string_literal: true

# One member's view of a tricount: their balance and the transactions that
# explain it in Sure.
#
# Tricount signs amounts from the group's side: an expense is negative, money
# the group receives (INCOME) is positive, and each allocation carries the same
# sign as its entry. A member's balance is what the group owes them: their
# allocations less what they paid. Paying 100 for a dinner shared four ways
# leaves +75; a friend paying 40 for a taxi shared four ways takes 10 off.
#
# Each entry becomes up to two transactions in the member's Sure account, whose
# balance is that position:
# - what the member paid, as a transfer leg: the money left one of their own
#   accounts (a card, a bank), and Sure's transfer matching pairs the two;
# - the member's share, as their spending (or income), categorised. A transfer
#   between members (a settle-up, BALANCE in Tricount) is a transfer leg too.
# Paying 100 of which 25 is yours shows 25 of spending, not 100, and the 75
# the others owe you as the account's balance.
class TricountAccount::Ledger
  Member = Data.define(:uuid, :name, :status)
  Entry = Data.define(:uuid, :date, :description, :category, :type_transaction, :amount, :currency, :payer_uuid, :allocations)
  Leg = Data.define(:external_id, :amount, :currency, :date, :name, :kind, :category, :entry)

  ACTIVE = "ACTIVE".freeze
  SETTLE_UP = "BALANCE".freeze
  UNCATEGORIZED = "UNCATEGORIZED".freeze

  # The memberships of a registry payload, wrapped or not.
  def self.members_from(registry)
    Array(registry && registry["memberships"]).filter_map do |wrapper|
      membership = unwrap(wrapper)
      next unless membership.is_a?(Hash) && membership["uuid"].present?

      Member.new(
        uuid: membership["uuid"],
        name: membership.dig("alias", "display_name").presence || membership["display_name"].presence || membership["uuid"],
        status: membership["status"]
      )
    end
  end

  # API objects come wrapped in their type ({"RegistryEntry" => {...}}).
  def self.unwrap(object)
    return object unless object.is_a?(Hash) && object.size == 1

    inner = object.values.first
    inner.is_a?(Hash) ? inner : object
  end

  def initialize(entries_payload)
    @entries = Array(entries_payload).filter_map { |raw| parse_entry(self.class.unwrap(raw)) }
  end

  def entries
    @entries
  end

  def active_entries
    entries.select { |entry| entry_active?(entry) }
  end

  def balance_for(member_uuid)
    return BigDecimal("0") if member_uuid.blank?

    active_entries.sum(BigDecimal("0")) do |entry|
      entry.allocations.fetch(member_uuid, BigDecimal("0")) - (entry.payer_uuid == member_uuid ? entry.amount : BigDecimal("0"))
    end
  end

  # The member's transactions, in Sure's sign (positive is money out of the
  # account). Entries the member neither paid nor shares in give none.
  def legs_for(member_uuid)
    return [] if member_uuid.blank?

    active_entries.flat_map do |entry|
      legs = []

      if entry.payer_uuid == member_uuid && entry.amount.nonzero?
        legs << Leg.new(
          external_id: "#{entry.uuid}:paid", amount: entry.amount, currency: entry.currency, date: entry.date,
          name: entry.description, kind: "funds_movement", category: nil, entry: entry
        )
      end

      share = entry.allocations.fetch(member_uuid, BigDecimal("0"))
      if share.nonzero?
        settle_up = entry.type_transaction == SETTLE_UP
        legs << Leg.new(
          external_id: "#{entry.uuid}:share", amount: -share, currency: entry.currency, date: entry.date,
          name: entry.description, kind: settle_up ? "funds_movement" : "standard",
          category: settle_up ? nil : entry.category, entry: entry
        )
      end

      legs
    end
  end

  private

    def entry_active?(entry)
      entry.uuid.present? && entry.date.present? && (entry.allocations.any? || entry.payer_uuid.present?)
    end

    def parse_entry(raw)
      return nil unless raw.is_a?(Hash)
      return nil if raw["status"].present? && raw["status"] != ACTIVE

      amount = decimal(raw.dig("amount", "value"))
      return nil if amount.nil?

      allocations = Array(raw["allocations"]).each_with_object({}) do |allocation, by_member|
        member_uuid = membership_uuid(allocation["membership"]) || allocation["membership_uuid"]
        value = decimal(allocation.dig("amount", "value"))
        next if member_uuid.blank? || value.nil?

        by_member[member_uuid] = by_member.fetch(member_uuid, BigDecimal("0")) + value
      end

      Entry.new(
        uuid: raw["uuid"].presence || raw["id"]&.to_s,
        date: parse_date(raw["date"]),
        description: raw["description"].to_s.strip,
        category: entry_category(raw),
        type_transaction: raw["type_transaction"].presence,
        amount: amount,
        currency: raw.dig("amount", "currency"),
        payer_uuid: membership_uuid(raw["membership_owned"]) || raw["membership_uuid_owner"],
        allocations: allocations
      )
    end

    # A custom label the member typed wins over Tricount's own category
    # (GROCERIES, TRANSPORT, FOOD_AND_DRINK, ...); UNCATEGORIZED is none.
    def entry_category(raw)
      category = raw["category_custom"].presence || raw["category"].presence
      category == UNCATEGORIZED ? nil : category
    end

    def membership_uuid(membership)
      return nil unless membership.is_a?(Hash)

      self.class.unwrap(membership)["uuid"].presence
    end

    def decimal(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def parse_date(value)
      Date.iso8601(value.to_s[0, 10])
    rescue ArgumentError
      nil
    end
end

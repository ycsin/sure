class BalanceSheet::AccountGroup
  include Monetizable

  monetize :total, as: :total_money

  attr_reader :name, :color, :accountable_type, :accounts

  # Several accounts of the group held at one institution (the currency
  # balances of a Wise account, say), shown in the sidebar as one entry with
  # their combined total in the family's currency.
  InstitutionBundle = Data.define(:key, :name, :accounts, :total, :currency) do
    include Monetizable

    monetize :total, as: :total_money

    # The account whose icon stands for the institution: one with a logo of
    # its own, else the first.
    def logo_account
      accounts.find { |account| account.logo.attached? } || accounts.first
    end

    def syncing?
      accounts.any?(&:syncing?)
    end

    def dom_id(prefix)
      "#{prefix}_institution_#{Digest::MD5.hexdigest(key)[0, 12]}"
    end
  end

  def initialize(name:, color:, accountable_type:, accounts:, classification_group:)
    @name = name
    @color = color
    @accountable_type = accountable_type
    @accounts = accounts
    @classification_group = classification_group
  end

  # A stable DOM id for this group.
  # Example outputs:
  #   dom_id(tab: :asset)               # => "asset_depository"
  #   dom_id(tab: :all, mobile: true)   # => "mobile_all_depository"
  #
  # Keeping all of the logic here means the view layer and broadcaster only
  # need to ask the object for its DOM id instead of rebuilding string
  # fragments in multiple places.
  def dom_id(tab: nil, mobile: false)
    parts = []
    parts << "mobile" if mobile
    parts << (tab ? tab.to_s : classification.to_s)
    parts << key
    parts.compact.join("_")
  end

  def key
    accountable_type.to_s.underscore
  end

  # Counts the same accounts as the classification total and net worth, so the
  # group weights add up and the sidebar sparkline matches this figure.
  def total
    BalanceSheet::ClassificationGroup.counted_accounts(accounts).sum(&:converted_balance)
  end

  def weight
    return 0 if classification_group.total.zero?

    total / classification_group.total.to_d * 100
  end

  def syncing?
    accounts.any?(&:syncing?)
  end

  # The group's sidebar rows, in order: an account, or a bundle where two or
  # more accounts share an institution (by name, else domain, ignoring case
  # and spacing). A bundle takes the place of its first account.
  def sidebar_entries
    by_institution = accounts.group_by { |account| institution_key(account) }
    bundled = Set.new

    accounts.filter_map do |account|
      key = institution_key(account)
      members = key ? by_institution[key] : []
      next account if members.size < 2
      next if bundled.include?(key)

      bundled << key
      InstitutionBundle.new(
        key: key,
        name: account.institution_name.presence || account.institution_domain,
        accounts: members,
        total: BalanceSheet::ClassificationGroup.counted_accounts(members).sum(&:converted_balance),
        currency: currency
      )
    end
  end

  # "asset" or "liability"
  def classification
    classification_group.classification
  end

  def currency
    classification_group.currency
  end

  private
    attr_reader :classification_group

    def institution_key(account)
      (account.institution_name.presence || account.institution_domain).to_s.downcase.squish.presence
    end
end

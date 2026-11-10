class BalanceSheet::AccountGroup
  include Monetizable

  monetize :total, as: :total_money

  attr_reader :name, :color, :accountable_type, :accounts

  # Several accounts of the group held at one institution (the currency
  # balances of a Wise account, say), shown in the sidebar as one entry with
  # their combined total: in their own currency when they all share one, else
  # in the family's, unless the institution's settings (an InstitutionGroup)
  # choose a currency, a name or an icon.
  InstitutionBundle = Data.define(:key, :group_key, :name, :accounts, :total, :currency, :converted_total, :settings) do
    include Monetizable

    monetize :total, as: :total_money

    # Names the bundle in URLs and DOM ids: the key itself can hold any
    # character, and an institution can have a bundle in more than one group.
    def slug
      "#{group_key}-#{Digest::MD5.hexdigest(key)[0, 12]}"
    end

    def to_param
      slug
    end

    # The account whose icon stands for the institution: the one picked in
    # its settings, else one with a logo of its own, else the first.
    def logo_account
      chosen_logo_account || accounts.find { |account| account.logo.attached? } || accounts.first
    end

    # With a domain set and no account picked, the icon is the domain's: the
    # logo stored on an account at that domain, as that account shows it, or
    # else Brandfetch's icon for the domain, the two places an account's icon
    # for a domain comes from.
    def logo_url
      return logo_account.logo_url if chosen_logo_account || domain.blank?

      accounts.find { |account| account.institution_domain == domain && account.logo.attached? }&.logo_url ||
        Account.brandfetch_logo_url_for(domain) ||
        logo_account.logo_url
    end

    def domain
      settings&.institution_domain
    end

    def syncing?
      accounts.any?(&:syncing?)
    end

    # The accounts' combined balance history in the bundle's currency, over
    # the accounts its total counts.
    # Changes whenever the bundle's sparkline does: with any of its accounts'
    # sparklines (Account#sparkline_version), the accounts in it, or the
    # currency it is shown in. The sidebar passes the versions it already has.
    def sparkline_version(account_versions = Account.sparkline_versions(accounts.map(&:account)))
      Digest::SHA256.hexdigest([ slug, currency, *accounts.map { |account| account_versions[account.id] }.sort ].join("|")).first(16)
    end

    def sparkline_series
      balance_series(period: Period.last_30_days)
    end

    def balance_series(period:)
      Balance::ChartSeriesBuilder.new(
        account_ids: BalanceSheet::ClassificationGroup.counted_accounts(accounts).map(&:id),
        currency: currency,
        period: period,
        favorable_direction: accounts.first.favorable_direction
      ).balance_series
    end

    # When the earliest of the accounts' histories starts, or nil.
    def history_start_date
      accounts.filter_map(&:history_start_date).min
    end

    def dom_id(prefix)
      "#{prefix}_institution_#{Digest::MD5.hexdigest(key)[0, 12]}"
    end

    private
      def chosen_logo_account
        accounts.find { |account| account.id == settings.logo_account_id } if settings&.logo_account_id
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

  # The group's sidebar rows: an account, or a bundle where two or more
  # accounts share an institution (by name, else domain, ignoring case and
  # spacing). With a name or balance order the rows sort by what each shows,
  # a bundle by its institution's name or its total (balances compared in the
  # family's currency); otherwise a bundle takes its first account's place.
  # A bundle's accounts keep the group's order.
  # `institution_groups` holds the family's saved bundle settings by key.
  def sidebar_entries(order: nil, institution_groups: {})
    entries = sidebar_rows(institution_groups)
    case order&.key
    when "name_asc", "name_desc"
      sorted = entries.each_with_index.sort_by { |entry, index| [ entry_name(entry).downcase, index ] }.map(&:first)
      order.key == "name_desc" ? sorted.reverse : sorted
    when "balance_asc", "balance_desc"
      sorted = entries.each_with_index.sort_by { |entry, index| [ entry_balance(entry), index ] }.map(&:first)
      order.key == "balance_desc" ? sorted.reverse : sorted
    else
      entries
    end
  end

  def institution_bundles(institution_groups: {})
    sidebar_rows(institution_groups).grep(InstitutionBundle)
  end

  private def sidebar_rows(institution_groups)
    by_institution = accounts.group_by { |account| institution_key(account) }
    bundled = Set.new

    accounts.filter_map do |account|
      key = institution_key(account)
      members = key ? by_institution[key] : []
      next account if members.size < 2
      next if bundled.include?(key)

      bundled << key
      institution_bundle(key, account, members, institution_groups[key])
    end
  end

  private def institution_bundle(key, first_account, members, settings)
    counted = BalanceSheet::ClassificationGroup.counted_accounts(members)
    shared_currency = members.map(&:currency).uniq.one? ? members.first.currency : nil
    display_currency = settings&.currency || shared_currency || currency

    InstitutionBundle.new(
      key: key,
      group_key: self.key,
      name: settings&.name || first_account.institution_name.presence || first_account.institution_domain,
      accounts: members,
      total: total_in(counted, display_currency),
      currency: display_currency,
      converted_total: counted.sum(&:converted_balance),
      settings: settings
    )
  end

  # The accounts' balances summed in `target`: each account's own balance in
  # that currency, the balance sheet's conversion in the family's, and today's
  # rates (fetched together) in any other.
  private def total_in(counted, target)
    return counted.sum(&:converted_balance) if target == currency

    rates = ExchangeRate.rates_for(counted.map(&:currency) - [ target ], to: target)
    counted.sum { |account| account.currency == target ? account.balance : account.balance * rates.fetch(account.currency) }
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

    def entry_name(entry)
      entry.name.to_s
    end

    def entry_balance(entry)
      entry.is_a?(InstitutionBundle) ? entry.converted_total : entry.converted_balance
    end

    def institution_key(account)
      (account.institution_name.presence || account.institution_domain).to_s.downcase.squish.presence
    end
end

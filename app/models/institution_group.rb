# What the user set for the accounts the sidebar bundles at one institution
# (BalanceSheet::AccountGroup::InstitutionBundle): a name, the institution's
# domain, the account whose icon stands for it, and the currency its total
# shows in. `key` is the bundle's institution key, so the settings apply
# wherever that institution's accounts are bundled. A row exists only once
# something was saved, and a blank field keeps the bundle's default.
class InstitutionGroup < ApplicationRecord
  belongs_to :family
  belongs_to :logo_account, class_name: "Account", optional: true

  normalizes :name, with: ->(name) { name.squish.presence }
  normalizes :institution_domain, with: ->(domain) { Account.normalize_institution_domain(domain) }
  normalizes :currency, with: ->(currency) { currency.strip.upcase.presence }

  validates :key, presence: true
  validates :key, uniqueness: { scope: :family_id }, if: -> { DatabaseTextValidator.acceptable?(key) }
  validates :name, :institution_domain, length: { maximum: 255 }, if: -> { DatabaseTextValidator.acceptable?([ name, institution_domain ]) }
  validates_with DatabaseTextValidator, attributes: %i[key name institution_domain currency]
  validates :currency, inclusion: { in: ->(_) { Money::Currency.as_options.map(&:iso_code) } }, allow_nil: true
  validate :logo_account_is_a_member

  # The accounts the settings are edited for. The icon can only be one of
  # theirs; without them, any account of the family's.
  attr_accessor :member_accounts

  private
    def logo_account_is_a_member
      return if logo_account_id.blank?

      member_ids = member_accounts ? member_accounts.map(&:id) : family.accounts.pluck(:id)
      errors.add(:logo_account, :inclusion) unless member_ids.include?(logo_account_id)
    end
end

require "test_helper"

class InstitutionGroupTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "blank fields are saved as nothing set, and the domain is normalized" do
    settings = @family.institution_groups.create!(key: "wise", name: "  ", currency: " ", institution_domain: "https://www.wise.com/gb")

    assert_nil settings.name
    assert_nil settings.currency
    assert_equal "wise.com", settings.institution_domain
  end

  test "the currency must be a supported one" do
    assert_not @family.institution_groups.new(key: "wise", currency: "XYZ").valid?
    assert @family.institution_groups.new(key: "wise", currency: "eur").valid?
  end

  test "the icon must come from one of the accounts the settings are edited for" do
    member = @family.accounts.create!(name: "Wise A", balance: 1, currency: "USD", accountable: Depository.new)
    other = @family.accounts.create!(name: "Savings", balance: 1, currency: "USD", accountable: Depository.new)

    settings = @family.institution_groups.new(key: "wise", logo_account: other, member_accounts: [ member ])
    assert_not settings.valid?
    assert settings.errors.of_kind?(:logo_account, :inclusion)

    settings.logo_account = member
    assert settings.valid?

    settings = @family.institution_groups.new(key: "wise", logo_account: accounts(:depository))
    assert_not settings.valid?, "another family's account"
  end

  test "an institution has one row of settings per family" do
    @family.institution_groups.create!(key: "wise")

    assert_not @family.institution_groups.new(key: "wise").valid?
    assert families(:dylan_family).institution_groups.new(key: "wise").valid?
  end
end

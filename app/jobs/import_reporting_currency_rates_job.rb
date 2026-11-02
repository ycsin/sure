# Fetches the exchange rates a family's reporting currencies need, for every
# account in its history (disabled ones included, as the net-worth series
# counts them up to when they were disabled), after a currency is added to
# them in preferences.
class ImportReportingCurrencyRatesJob < ApplicationJob
  queue_as :medium_priority

  def perform(family)
    return unless ExchangeRate.provider

    family.accounts.historical.find_each do |account|
      Account::MarketDataImporter.new(account).import_exchange_rates
    end
  end
end

import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="transfer-match"
//
// Switches between matching an existing transaction and creating a new one.
// When the new transaction's account is in another currency than the
// transaction being matched, it offers to record the new one in that account's
// currency, with the amount prefilled from the exchange rate on the
// transaction's date (editable: what actually arrived usually differs).
export default class extends Controller {
  static targets = [
    "newSelect",
    "existingSelect",
    "currencySection",
    "currencyCode",
    "useTargetCurrency",
    "targetAmountField",
    "targetAmount",
    "rateHint",
  ];

  static values = {
    accountCurrencies: Object,
    currencyPrecisions: Object,
    entryCurrency: String,
    entryAmount: String,
    date: String,
    exchangeRateUrl: String,
  };

  connect() {
    this.targetChanged();
  }

  update(event) {
    const creating = event.target.value === "new";
    this.newSelectTarget.classList.toggle("hidden", !creating);
    if (this.hasExistingSelectTarget) {
      this.existingSelectTarget.classList.toggle("hidden", creating);
    }
    this.#applyTargetCurrency();
  }

  // The new transaction's account changed (DS::Select dispatches change on
  // its hidden input).
  targetChanged() {
    if (!this.hasCurrencySectionTarget) return;

    const currency = this.#targetCurrency();
    const otherCurrency = Boolean(currency) && currency !== this.entryCurrencyValue;
    this.currencySectionTarget.classList.toggle("hidden", !otherCurrency);
    this.currencyCodeTargets.forEach((element) => {
      element.textContent = currency || "";
    });

    if (otherCurrency && currency !== this.prefilledCurrency) {
      this.prefilledCurrency = currency;
      this.targetAmountTarget.value = "";
      this.#prefill(currency);
    }
    this.#applyTargetCurrency();
  }

  toggleTargetCurrency() {
    this.#applyTargetCurrency();
  }

  // The amount is needed only while it will be used: creating, in another
  // currency, with the option on.
  #applyTargetCurrency() {
    if (!this.hasCurrencySectionTarget) return;

    const creating = !this.newSelectTarget.classList.contains("hidden");
    const shown = !this.currencySectionTarget.classList.contains("hidden");
    const inTargetCurrency = this.useTargetCurrencyTarget.checked;
    this.targetAmountFieldTarget.classList.toggle("hidden", !inTargetCurrency);
    this.targetAmountTarget.required = creating && shown && inTargetCurrency;
    this.targetAmountTarget.disabled = !(creating && shown && inTargetCurrency);
  }

  #targetCurrency() {
    const input = this.newSelectTarget.querySelector(
      "input[type='hidden'][name$='[target_account_id]']",
    );
    return input ? this.accountCurrenciesValue[input.value] : null;
  }

  async #prefill(currency) {
    this.rateHintTarget.textContent = "";
    const url = new URL(this.exchangeRateUrlValue, window.location.origin);
    url.searchParams.set("from", this.entryCurrencyValue);
    url.searchParams.set("to", currency);
    url.searchParams.set("date", this.dateValue);

    let rate = null;
    try {
      const response = await fetch(url, { headers: { Accept: "application/json" } });
      if (response.ok) rate = Number((await response.json()).rate);
    } catch {
      rate = null;
    }

    // The account was changed again while the rate was on its way: drop the
    // answer, and if nothing has been prefilled for this currency since,
    // forget it so that choosing it again asks anew.
    if (currency !== this.#targetCurrency()) {
      if (this.prefilledCurrency === currency) this.prefilledCurrency = null;
      return;
    }

    if (rate && Number.isFinite(rate) && rate > 0) {
      if (!this.targetAmountTarget.value) {
        // At the currency's own precision (three decimals for KWD, none for JPY).
        const precision = this.currencyPrecisionsValue[currency] ?? 2;
        this.targetAmountTarget.value = (Number(this.entryAmountValue) * rate).toFixed(precision);
      }
      this.rateHintTarget.textContent = this.rateHintTarget.dataset.rateText
        .replace("%{from}", this.entryCurrencyValue)
        .replace("%{rate}", String(Number(rate.toPrecision(6))))
        .replace("%{to}", currency);
    } else {
      this.rateHintTarget.textContent = this.rateHintTarget.dataset.missingText;
    }
  }
}

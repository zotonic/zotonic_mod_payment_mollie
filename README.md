Mollie payments for Zotonic
===========================

This is a Payment Service Provider (PSP) module for [mod_payment](https://github.com/zotonic/zotonic_mod_payment).

This module interfaces mod_payment to the PSP Mollie (https://mollie.com/)


Configuration
-------------

The following configuration keys can be set:

 * `mod_payment_mollie.api_key` the secret API key for Mollie API requests. Be
   sure to use the *test* key when developing.
 * `mod_payment_mollie.recurring_payment_interval` the payment interval at 
   which recurring payments will follow. Possible values: `monthly` and `yearly`.
   Defaults to `yearly`.

Development configuration
-------------------------

 * `mod_payment_mollie.webhook_host` this should be the host (with `http:` prefix)
   where Mollie should send the webhook messages. Only use this if your (development)
   site is reachable from the outside via a different URL than the configured hostnames.

Missed payments can also be discovered every four hours when
`mod_payment.accept_unknown_payments` is enabled. This uses the API key's profile
and does not require a local webhook URL. The shared
`mod_payment.disable_unknown_payment_polling` switch disables this discovery;
the existing daily recurring-payment synchronization is unchanged.

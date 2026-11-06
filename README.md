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

Discovery also scans the [refund list](https://docs.mollie.com/reference/list-all-refunds)
by refund creation date, retrieving the current payment for each recent refund.
This can find refunds of payments created before the discovery window. There is
no general modified-since payment filter; refunds settling after the overlap
window can still be missed.

### Payment profiles

The payment response's `profileId` is stored as `psp_profile_id` for checkout,
recurring payments, synchronization and discovery. No additional Mollie API call
is required. Installation upgrades recover profile IDs from saved Mollie payment
responses, without extending payment retention. Older payments whose stored
response lacks a profile remain unset until synchronized with Mollie.

### Profile lookup

`m.payment_mollie_profiles.list` is administrator-only. With the existing API key,
`GET /v2/profiles/me` returns its profile. Configure the optional secret
`profiles_access_token` in the payment configuration with an advanced access token
having `profiles.read` permission to list all profiles accessible to that token.
The lookup follows Mollie's pagination and returns profile names and IDs.
This token is only used for profile lookup: payment creation and discovery keep
using the existing API key and its profile.

Lists are cached for 15 minutes. If Mollie is unavailable or denies access, the
last successful list remains available for up to one day with `is_stale = true`.
Changing credentials starts a separate cache. WomensWallet supplements the list
with profile IDs from received payments and saved selections, so lookup failures
do not remove those selections. No additional request is made per payment.

### Local development without webhooks

New payments and subscriptions omit `webhookUrl` when `disable_webhooks` is enabled,
or when the effective webhook hostname ends in `.test` or is `localhost`.
The payment configuration shows a notice when webhooks are omitted. A public
`webhook_host` override (for example a development tunnel) allows webhooks on a
local site. This is a hostname heuristic, not a network reachability probe.
Existing Mollie payments and subscriptions are not modified by this setting.

Mollie accepts requests without a webhook URL. Status updates then depend on
existing synchronization; immediate webhook updates are unavailable. Payment
metadata and the PSP payment ID allow synchronization without a webhook URL.
Subscription metadata carries the original payment number to generated payments.

When webhooks are disabled (explicitly or by the local-host heuristic), a GET of
the payment ready page synchronizes an accessible Mollie payment before rendering
its status. The page is not cached. API failures leave the stored status in place;
a payment that Mollie still considers pending is still shown as pending.

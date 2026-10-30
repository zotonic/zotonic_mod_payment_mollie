%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2018-2026 Driebit BV
%% @doc Payment PSP module for Mollie
%% @end

%% Copyright 2018-2026 Driebit BV
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(mod_payment_mollie).
-moduledoc(#{
    zotonic_keywords => [
        "reference", "backend_developer", "site_administrator", "module",
        "payments", "configuration", "api_and_integration"
    ]
}).
-moduledoc("
Provide Mollie payments and recurring subscriptions through `mod_payment`.

Enable `mod_payment_mollie` with its `mod_payment` and `mod_admin` dependencies.
Configure the site under **System → Payment configuration** with
`use.mod_admin_config`. Select this adapter with
`#payment_request{preferred_psp_module = mod_payment_mollie}`. Checkout creation
supports EUR and USD.

## Site configuration

- `api_key`: secret Mollie API key. A `test_` key selects test payments; a `live_`
  key selects live payments.
- `recurring_payment_interval`: `monthly` or `yearly`, defaulting to `yearly`.
- `webhook_host`: optional public origin, including protocol and without a trailing
  slash. Defaults to the site's absolute URL.
- `sync_periodic`: automatically maintained synchronization cursor; leave unset
  when configuring the module.

The adapter generates `/mollie/webhook/:payment_nr` callback URLs. Callbacks identify
an existing local payment and retrieve payment data from the authenticated Mollie
API before updating it. Recurring payments have a daily synchronization path.

Four-hour discovery of previously unknown payments uses the shared mod_payment
options and retention cutoff. This polls the configured Mollie profile's payments;
it does not turn the existing payment-specific callback into a generic webhook.
").


-mod_title("Payments using Mollie").
-mod_description("Payments using Payment Service Provider Mollie").
-mod_author("Driebit").
-mod_depends([ mod_payment, mod_admin ]).

-mod_config([
    #{
        key => api_key,
        is_secret => true,
        type => binary,
        default => <<>>,
        description => "Required secret Mollie API key. Use a test_ key for test payments or a live_ key for live payments."
    },
    #{
        key => recurring_payment_interval,
        type => binary,
        default => <<"yearly">>,
        options => [<<"monthly">>, <<"yearly">>],
        description => "Interval for new recurring subscriptions: monthly or yearly. Defaults to yearly."
    },
    #{
        key => webhook_host,
        type => binary,
        default => <<>>,
        description => "Optional webhook origin, including http:// or https:// and without a trailing slash. Defaults to the site's absolute URL. Useful for testing through a public host."
    },
    #{
        key => sync_periodic,
        is_readonly => true,
        type => binary,
        default => <<>>,
        description => "Internal synchronization cursor: the newest Mollie createdAt timestamp processed by the periodic payment sync. Updated automatically; normally leave unset."
    }
]).

-export([
    observe_payment_psp_request/2,
    observe_payment_psp_view_url/2,
    observe_payment_psp_status_sync/2,
    observe_payment_psp_poll/2,
    observe_cancel_recurring_psp_request/2,
    observe_tick_24h/2
]).

-include_lib("zotonic_mod_payment/include/payment.hrl").

%% @doc Payment request, make new payment with Mollie, return
%%      payment (mollie) details and a redirect uri for the user
%%      to handle the payment.
observe_payment_psp_request(#payment_psp_request{
        payment_id = PaymentId,
        currency = Currency,
        preferred_psp_module = PreferredPspModule
    }, Context) when (Currency =:= <<"EUR">> orelse Currency =:= <<"USD">>)
        andalso (PreferredPspModule =:= undefined orelse PreferredPspModule =:= ?MODULE) ->
    m_payment_mollie_api:create(PaymentId, Context);
observe_payment_psp_request(#payment_psp_request{}, _Context) ->
    undefined.

observe_payment_psp_view_url(#payment_psp_view_url{ psp_module = ?MODULE, psp_external_id = MollieId }, _Context) ->
    {ok, m_payment_mollie_api:payment_url(MollieId)};
observe_payment_psp_view_url(#payment_psp_view_url{}, _Context) ->
    undefined.

%% @doc Used to fetch the status of all payments in a non-final state. Called manually or periodically.
observe_payment_psp_status_sync(#payment_psp_status_sync{
        payment_id = PaymentId,
        psp_module = ?MODULE
    }, Context) ->
    m_payment_mollie_api:payment_sync(PaymentId, Context);
observe_payment_psp_status_sync(#payment_psp_status_sync{}, _Context) ->
    undefined.

%% @doc Cancel the subscription at Mollie
observe_cancel_recurring_psp_request(#cancel_recurring_psp_request{ user_id = UserId }, Context) ->
    m_payment_mollie_api:cancel_subscription(UserId, Context).


%% @doc Periodic poll for recurring payments. The recurring payments could be missed because
%% they are newly created by the PSP and then pushed to the webhook.
%% Non-recurring payments are synced using the psp_status_sync.
observe_tick_24h(tick_24h, Context) ->
    m_payment_mollie_api:payment_sync_periodic(Context),
    m_payment_mollie_api:payment_sync_recent_pending(Context).

%% Discovery pages are imported and checkpointed by mod_payment.
observe_payment_psp_poll(#payment_psp_poll{psp_module = undefined}, _Context) ->
    ?MODULE;
observe_payment_psp_poll(#payment_psp_poll{psp_module = ?MODULE} = Request, Context) ->
    payment_mollie_poll:page(Request, Context);
observe_payment_psp_poll(#payment_psp_poll{}, _Context) ->
    undefined.

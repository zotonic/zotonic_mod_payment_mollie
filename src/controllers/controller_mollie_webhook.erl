%% @copyright 2018-2025 Driebit BV
%% @doc Webhook for callbacks by Mollie.
%% @end

%% Copyright 2018-2025 Driebit BV
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

-module(controller_mollie_webhook).
-moduledoc(#{
    zotonic_keywords => [
        "reference", "backend_developer", "integrator", "controller",
        "payments", "api_and_integration", "security", "send_and_receive"
    ]
}).
-moduledoc("
Handle Mollie checkout callbacks.

Accept POST callbacks at `/mollie/webhook/:payment_nr`. The posted `id` is
retrieved through the authenticated Mollie API before a known local payment is
updated. The callback body alone is not proof of payment. Unknown local references
return 404; other synchronization failures return 500 so delivery can be retried.

Generate the endpoint through its dispatch rule, for example:

```django
{% url mollie_payment_webhook payment_nr=payment_nr %}
```

This provider-facing endpoint uses the verification described above rather than
an administrator login.
").


-export([
    allowed_methods/1,
    process/4
]).

allowed_methods(Context) ->
    {[ <<"POST">> ], Context}.

process(<<"POST">>, _AcceptedCT, _ProvidedCT, Context) ->
    ExtPaymentId = z_convert:to_binary(z_context:get_q(<<"id">>, Context)),
    FirstPaymentNr = z_convert:to_binary(z_context:get_q(<<"payment_nr">>, Context)),
    case m_payment_mollie_api:payment_sync_webhook(FirstPaymentNr, ExtPaymentId, Context) of
        ok ->
            {true, Context};
        {error, notfound} ->
            {{halt, 404}, Context};
        {error, _} ->
            {{halt, 500}, Context}
    end.

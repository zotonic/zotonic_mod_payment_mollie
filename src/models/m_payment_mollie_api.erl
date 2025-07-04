%% @copyright 2018-2025 Driebit BV
%% @doc API interface for Mollie PSP
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

-module(m_payment_mollie_api).

-export([
    create/2,

    payment_sync_webhook/3,
    payment_sync_periodic/1,
    payment_sync_recent_pending/1,
    payment_sync/2,

    is_test/1,
    api_key/1,
    webhook_url/2,
    payment_url/1,
    list_subscriptions/2,
    list_subscriptions_from_email/2,
    has_subscription/2,
    has_subscription_from_email/2,
    cancel_subscription/2
    ]).

% Testing
-export([
    ]).


-include_lib("zotonic_core/include/zotonic.hrl").
-include_lib("zotonic_mod_payment/include/payment.hrl").

-define(MOLLIE_API_URL, "https://api.mollie.nl/v2/").

-define(TIMEOUT_REQUEST, 10000).
-define(TIMEOUT_CONNECT, 5000).

%% @doc Create a new payment with Mollie (https://www.mollie.com/nl/docs/reference/payments/create)
create(PaymentId, Context) ->
    {ok, Payment} = m_payment:get(PaymentId, Context),
    case maps:get(<<"currency">>, Payment) of
        <<"EUR">> ->
            RedirectUrl = z_context:abs_url(
                z_dispatcher:url_for(
                    payment_psp_done,
                    [ {payment_nr, maps:get(<<"payment_nr">>, Payment)} ],
                    Context),
                Context),
            WebhookUrl = webhook_url(maps:get(<<"payment_nr">>, Payment), Context),
            Metadata = #{
                <<"payment_id">> => maps:get(<<"id">>, Payment),
                <<"payment_nr">> => maps:get(<<"payment_nr">>, Payment)
            },
            Recurring = case maps:get(<<"is_recurring_start">>, Payment, false) of
                            true -> [{sequenceType, <<"first">>}];
                            false -> []
                        end,
            Args = [
                {'amount[value]', filter_format_price:format_price(maps:get(<<"amount">>, Payment), Context)},
                {'amount[currency]', maps:get(<<"currency">>, Payment, <<"EUR">>)},
                {description, valid_description( maps:get(<<"description">>, Payment) )},
                {webhookUrl, WebhookUrl},
                {redirectUrl, RedirectUrl},
                {metadata, iolist_to_binary([ z_json:encode(Metadata) ])}
                | Recurring ],
            case maybe_add_custid(Payment, Args, Context) of
                {ok, ArgsCust} ->
                    case payment_pre_flight_check(Payment, Context) of
                        ok ->
                            do_payment(PaymentId, ArgsCust, Context);
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        Currency ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Mollie payment request with non EUR currency">>,
                result => error,
                reason => currency,
                payment => PaymentId,
                data => Currency
            }),
            {error, {currency, only_eur}}
    end.

payment_pre_flight_check(#{ <<"is_recurring_start">> := true, <<"user_id">> := UserId }, Context) when is_integer(UserId) ->
    check_subscriptions(list_subscriptions(UserId, Context));
payment_pre_flight_check(#{ <<"is_recurring_start">> := true }=Payment, Context) ->
    case maps:get(<<"email">>, Payment, undefined) of
        undefined ->
            {error, no_email};
        Email ->
            check_subscriptions(list_subscriptions_from_email(Email, Context))
    end;
payment_pre_flight_check(_Payment, _Context) ->
    ok.

% Checks if there are any subscription. If a user already has a subscription Mollie does
% not allow the creation of another subscription with the same description. The description
% for the subscription is currently pre defined.
check_subscriptions({ok, []}) -> ok;
check_subscriptions({ok, _}) -> {error, already_subscribed}.


maybe_add_custid(#{ <<"is_recurring_start">> := true, <<"user_id">> := undefined }=Payment, Args, Context) ->
    Email = maps:get(<<"email">>, Payment, undefined),
    case mollie_customer_id_from_email(Email, false, Context) of
        {ok, CustomerId} ->
            {ok, [ {customerId, CustomerId} | Args ]};
        {error, enoent} ->
            {Name, _Context} = z_template:render_to_iolist("_mollie_payment_to_name.tpl", [ {payment, Payment} ], Context),
            case create_mollie_customer_id(Name, Email, Context) of
                {ok, CustomerId} ->
                    {ok, [ {customerId, CustomerId} | Args ]};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
maybe_add_custid(#{ <<"user_id">> := undefined }, Args, _Context) ->
    {ok, Args};
maybe_add_custid(#{ <<"user_id">> := UserId }, Args, Context) ->
    case ensure_mollie_customer_id(UserId, Context) of
        {ok, CustomerId} ->
            {ok, [ {customerId, CustomerId} | Args ]};
        {error, _} = Error ->
            Error
    end.

valid_description(<<>>) -> <<"Payment">>;
valid_description(undefined) -> <<"Payment">>;
valid_description(D) when is_binary(D) -> D.

do_payment(PaymentId, Args, Context) ->
    case api_call(post, "payments", Args, Context) of
        {ok, #{
               <<"resource">> := <<"payment">>,
               <<"id">> := MollieId,
               <<"_links">> := #{
                                 <<"checkout">> := #{
                                                     <<"href">> := PaymentUrl
                                                    }
                                }
              } = JSON} ->
            m_payment_log:log(
              PaymentId,
              <<"CREATED">>,
              [
               {psp_module, mod_payment_mollie},
               {psp_external_log_id, MollieId},
               {description, <<"Created Mollie payment ", MollieId/binary>>},
               {request_result, JSON}
              ],
              Context),
            {ok, #payment_psp_handler{
                    psp_module = mod_payment_mollie,
                    psp_external_id = MollieId,
                    psp_data = JSON,
                    redirect_uri = PaymentUrl
                   }};
        {ok, JSON} ->
            m_payment_log:log(
              PaymentId,
              <<"ERROR">>,
              [
               {psp_module, mod_payment_mollie},
               {description, "API Unexpected result creating payment with Mollie"},
               {request_json, JSON},
               {request_args, Args}
              ],
              Context),
            ?LOG_ERROR(#{
                         in => zotonic_mod_payment_mollie,
                         text => <<"API unexpected result creating mollie payment">>,
                         result => error,
                         reason => unexpected_result,
                         payment => PaymentId,
                         data => JSON
                        }),
            {error, unexpected_result};
        {error, Error} ->
            m_payment_log:log(
              PaymentId,
              <<"ERROR">>,
              [
               {psp_module, mod_payment_mollie},
               {description, "API Error creating payment with Mollie"},
               {request_result, Error},
               {request_args, Args}
              ],
              Context),
            ?LOG_ERROR(#{
                         in => zotonic_mod_payment_mollie,
                         text => <<"API error creating mollie payment">>,
                         result => error,
                         reason => Error,
                         payment => PaymentId
                        }),
                            {error, Error}
    end.


%% @doc Allow special hostname for the webhook, useful for testing.
webhook_url(PaymentNr, Context) ->
    Path = z_dispatcher:url_for(mollie_payment_webhook, [ {payment_nr, PaymentNr} ], Context),
    case z_convert:to_binary(m_config:get_value(mod_payment_mollie, webhook_host, Context)) of
        <<"http:", _/binary>> = Host -> <<Host/binary, Path/binary>>;
        <<"https:", _/binary>> = Host -> <<Host/binary, Path/binary>>;
        _ -> z_context:abs_url(Path, Context)
    end.

%% @doc Split payment nr from the webhook url.
webhook_url2payment(undefined) ->
    undefined;
webhook_url2payment(WebhookUrl) ->
    [ WebhookUrl1 | _ ] = binary:split(WebhookUrl, <<"?">>),
    case lists:last( binary:split(WebhookUrl1, <<"/">>, [ global ])) of
        <<>> -> undefined;
        PaymentNr -> PaymentNr
    end.

-spec payment_url(binary()|string()) -> binary().
payment_url(MollieId) ->
    <<"https://www.mollie.com/dashboard/payments/", (z_convert:to_binary(MollieId))/binary>>.


%% @doc Fetch the payment info from Mollie, to ensure that a specific payment is synchronized with
%% the information at Mollie.  Useful for pending/new payments where the webhook call failed.
-spec payment_sync(integer(), z:context()) -> ok | {error, term()}.
payment_sync(PaymentId, Context) when is_integer(PaymentId) ->
    case m_payment:get(PaymentId, Context) of
        {ok, #{ <<"psp_module">> := mod_payment_mollie } = Payment} ->
            ExtPaymentId = maps:get(<<"psp_external_id">>, Payment),
            case api_call(get, "payments/" ++ z_convert:to_list(ExtPaymentId), [], Context) of
                {ok, #{
                        <<"resource">> := <<"payment">>
                    } = ThisPaymentJSON} ->
                    handle_payment_sync(ThisPaymentJSON, Context);
                {error, Error} ->
                    %% Log an error with the payment
                    m_payment_log:log(
                        PaymentId,
                        <<"ERROR">>,
                        [
                            {psp_module, mod_payment_mollie},
                            {description, "API Error fetching status from Mollie"},
                            {request_result, Error}
                        ],
                        Context),
                    ?LOG_ERROR(#{
                        in => zotonic_mod_payment_mollie,
                        text => <<"API error creating mollie payment">>,
                        result => error,
                        reason => Error,
                        payment => PaymentId
                    }),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.


%% @doc Update all 'pending' and 'new' payments in our payments table that were created in the
%% last month. This to ensure that pending/new payments are updated within an acceptable
%% period, even when the webhook call is missed.
-spec payment_sync_recent_pending(z:context()) -> ok | {error, term()}.
payment_sync_recent_pending(Context) ->
    Payments = z_db:q("
        select id
        from payment
        where psp_module = 'mod_payment_mollie'
          and status in ('new', 'pending')
          and created > now() - interval '1 month'
        ", Context),
    lists:foreach(
        fun({PaymentId}) ->
            payment_sync(PaymentId, Context)
        end,
        Payments).

%% @doc Pull all payments from Mollie (since the previous pull) and sync them to our payment table.
-spec payment_sync_periodic(z:context()) -> ok | {error, term()}.
payment_sync_periodic(Context) ->
    Oldest = z_convert:to_binary( m_config:get_value(mod_payment_mollie, sync_periodic, Context) ),
    case fetch_payments_since_loop(Oldest, undefined, [], Context) of
        {ok, []} ->
            ok;
        {ok, ExtPayments} ->
            lists:foreach(
                fun(ExtPayment) ->
                    handle_payment_sync(ExtPayment, Context)
                end,
                lists:reverse(ExtPayments)),
            CreationDates = lists:map(
                fun(#{ <<"createdAt">> := C }) -> C end,
                ExtPayments),
            Newest = lists:max(CreationDates),
            m_config:set_value(mod_payment_mollie, sync_periodic, Newest, Context),
            ok;
        {error, _} = Error ->
            Error
    end.

fetch_payments_since_loop(Oldest, NextLink, Acc, Context) ->
    Url = case NextLink of
        undefined -> "payments?limit=250";
        _ -> NextLink
    end,
    case api_call(get, Url, [], Context) of
        {ok, #{ <<"_embedded">> := #{ <<"payments">> := Payments } } = JSON} ->
            Newer = lists:filter(
                fun(P) ->
                    status_date(P) >= Oldest
                end,
                Payments),
            Acc1 = Acc ++ Newer,
            case Newer of
                [] ->
                    {ok, Acc1};
                _ ->
                    case maps:get(<<"_links">>, JSON, undefined) of
                        #{ <<"next">> := #{ <<"href">> := Next } } when is_binary(Next) ->
                            fetch_payments_since_loop(Oldest, Next, Acc1, Context);
                        _ ->
                            {ok, Acc1}
                    end
            end;
        {error, _} = Error ->
            Error
    end.

handle_payment_sync(ThisPaymentJSON, Context) ->
    % Payments have the webhook which has the payment-number of the first payment starting a sequence
    % or of the oneoff payment.
    #{
        <<"id">> := ExtId,
        <<"webhookUrl">> := WebhookUrl
    } = ThisPaymentJSON,
    FirstPaymentNr = webhook_url2payment(WebhookUrl),
    case m_payment:get(FirstPaymentNr, Context) of
        {ok, FirstPayment} ->
            % This is the original payment starting the sequence
            case maps:get(<<"psp_module">>, FirstPayment) of
                mod_payment_mollie ->
                    % Fetch the status from Mollie
                    FirstPaymentId = maps:get(<<"id">>, FirstPayment),
                    m_payment_log:log(
                        FirstPaymentId,
                        <<"SYNC">>,
                        [
                           {psp_module, mod_payment_mollie},
                           {description, "Sync of payment info"},
                           {payment, ThisPaymentJSON}
                        ],
                        Context),
                    % Simulate the webhook call
                    handle_payment_update(FirstPaymentId, FirstPayment, ThisPaymentJSON, Context);
                PSP ->
                    ?LOG_ERROR(#{
                        in => zotonic_mod_payment_mollie,
                        text => <<"Payment PSP Mollie webhook call for unknown PSP">>,
                        result => error,
                        reason => notfound,
                        first_payment => FirstPaymentNr,
                        psp => PSP
                    }),
                    {error, notfound}
            end;
        {error, notfound} ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Payment PSP Mollie webhook call with unknown id">>,
                result => error,
                reason => notfound,
                first_payment => FirstPaymentNr,
                ext_id => ExtId
            }),
            {error, notfound};
        {error, Reason} = Error ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Payment PSP Mollie webhook call with id, error fetching payment">>,
                result => error,
                reason => Reason,
                first_payment => FirstPaymentNr,
                ext_id => ExtId
            }),
            Error
    end.


%% @doc Pull the payment status from Mollie. Used to synchronize a payment with the data
%% at Mollie. This is only a pull for update, not for fetching missing payments at Mollie.
%% Used for fetching information about new and pending payments.
-spec payment_sync_webhook(binary(), binary(), z:context()) -> ok | {error, notfound|term()}.
payment_sync_webhook(FirstPaymentNr, ExtPaymentId, Context) when is_binary(FirstPaymentNr) ->
    case m_payment:get(FirstPaymentNr, Context) of
        {ok, #{ <<"psp_module">> := mod_payment_mollie } = FirstPayment} ->
            % Fetch the status from Mollie
            FirstPaymentId = maps:get(<<"id">>, FirstPayment),
            ?LOG_INFO(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Payment PSP Mollie webhook call for payment">>,
                first_payment => FirstPaymentId
            }),
            case api_call(get, "payments/" ++ z_convert:to_list(ExtPaymentId), [], Context) of
                {ok, #{
                        <<"resource">> := <<"payment">>
                    } = ThisPaymentJSON} ->
                    m_payment_log:log(
                        FirstPaymentId,
                        <<"WEBHOOK">>,
                        [
                           {psp_module, mod_payment_mollie},
                           {description, "New webhook payment info"},
                           {payment, ThisPaymentJSON}
                        ],
                        Context),
                    handle_payment_update(FirstPaymentId, FirstPayment, ThisPaymentJSON, Context);
                {error, Error} ->
                    %% Log an error with the payment
                    m_payment_log:log(
                        FirstPaymentId,
                        <<"ERROR">>,
                        [
                            {psp_module, mod_payment_mollie},
                            {description, "API Error fetching status from Mollie"},
                            {request_result, Error}
                        ],
                        Context),
                    ?LOG_ERROR(#{
                        in => zotonic_mod_payment_mollie,
                        text => <<"API error creating mollie payment">>,
                        result => error,
                        reason => Error,
                        first_payment => FirstPaymentId
                    }),
                    Error
            end;
        {ok, #{ <<"psp_module">> := PSP }} ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Payment PSP Mollie webhook call for unknown PSP">>,
                result => error,
                reason => notfound,
                first_payment => FirstPaymentNr,
                psp => PSP
            }),
            {error, notfound};
        {error, notfound} ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Payment PSP Mollie webhook call with unknown id">>,
                result => error,
                reason => notfound,
                first_payment => FirstPaymentNr,
                ext_id => ExtPaymentId
            }),
            {error, notfound};
        {error, Reason} = Error ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Payment PSP Mollie webhook call with id, error fetching payment">>,
                result => error,
                reason => Reason,
                first_payment => FirstPaymentNr,
                ext_id => ExtPaymentId
            }),
            Error
    end.


handle_payment_update(FirstPaymentId, _FirstPayment, #{ <<"sequenceType">> := <<"recurring">> } = JSON, Context) ->
    % A recurring payment for an existing (first) payment.
    % The given (first) Payment MUST have 'recurring' set.
    #{
        <<"id">> := ExtId,
        <<"status">> := Status,
        <<"subscriptionId">> := _SubscriptionId,
        <<"amount">> := #{
            <<"currency">> := Currency,
            <<"value">> := Amount
        },
        <<"description">> := Description
    } = JSON,
    % Create a new payment, referring to the PaymentId
    AmountNr = z_convert:to_float(Amount),
    DateTime = z_convert:to_datetime( status_date(JSON) ),
    case m_payment:get_by_psp(mod_payment_mollie, ExtId, Context) of
        {ok, RecurringPayment} ->
            % Update the status of an already imported recurring payment.
            % This payment is linked to the first payment.
            RecurringPaymentId = maps:get(<<"id">>, RecurringPayment),
            PrevStatus = maps:get(<<"status">>, RecurringPayment),
            case is_status_equal(Status, PrevStatus) of
                true -> ok;
                false -> update_payment_status(RecurringPaymentId, Status, DateTime, Context)
            end;
        {error, notfound} ->
            % New recurring payment for an existing first payment.
            % Insert a new payment in our tables and the update that payment with
            % the newly received status.
            case m_payment:insert_recurring_payment(FirstPaymentId, DateTime, Currency, AmountNr, Context) of
                {ok, NewPaymentId} ->
                    PSPHandler = #payment_psp_handler{
                        psp_module = mod_payment_mollie,
                        psp_external_id = ExtId,
                        psp_payment_description = Description,
                        redirect_uri = <<>>, % there is no redirect uri
                        psp_data = JSON
                    },
                    ok = m_payment:update_psp_handler(NewPaymentId, PSPHandler, Context),
                    update_payment_status(NewPaymentId, Status, DateTime, Context);
                {error, Reason} = Error ->
                    ?LOG_ERROR(#{
                        in => zotonic_mod_payment_mollie,
                        text => <<"Payment PSP Mollie could not insert recurring payment">>,
                        result => error,
                        reason => Reason,
                        first_payment => FirstPaymentId,
                        data => JSON
                    }),
                    Error
            end
    end;
handle_payment_update(FirstPaymentId, FirstPayment, #{ <<"sequenceType">> := <<"first">> } = JSON, Context) ->
    % First recurring payment for an existing payment - if moved to paid then start the subscription
    #{
        <<"status">> := Status
    } = JSON,
    DateTime = z_convert:to_datetime( status_date(JSON) ),
    PrevStatus = maps:get(<<"status">>, FirstPayment),
    case is_status_equal(Status, PrevStatus) of
        true ->
            ok;
        false ->
            case update_payment_status(FirstPaymentId, Status, DateTime, Context) of
                ok when Status =:= <<"paid">> -> maybe_create_subscription(FirstPayment, Context);
                ok -> ok;
                {error, _} = Error -> Error
            end
    end;
handle_payment_update(OneOffPaymentId, _OneOffPayment, JSON, Context) ->
    #{
        <<"status">> := Status
    } = JSON,
    ?LOG_INFO(#{
        in => zotonic_mod_payment_mollie,
        text => <<"Payment PSP Mollie webhook call for one-off payment">>,
        oneoff_payment => OneOffPaymentId
    }),
    m_payment_log:log(
        OneOffPaymentId,
        <<"STATUS">>,
        [
            {psp_module, mod_payment_mollie},
            {description, "New payment status"},
            {status, JSON}
        ],
        Context),
    % UPDATE OUR ORDER STATUS
    DateTime = z_convert:to_datetime( status_date(JSON) ),
    update_payment_status(OneOffPaymentId, Status, DateTime, Context).


status_date(#{ <<"status">> := <<"charged_back">> }) -> calendar:universal_time();
status_date(#{ <<"expiredAt">> := Date }) when is_binary(Date), Date =/= <<>> -> Date;
status_date(#{ <<"failedAt">> := Date }) when is_binary(Date), Date =/= <<>> -> Date;
status_date(#{ <<"canceledAt">> := Date }) when is_binary(Date), Date =/= <<>> -> Date;
status_date(#{ <<"paidAt">> := Date }) when is_binary(Date), Date =/= <<>> -> Date;
status_date(#{ <<"createdAt">> := Date }) when is_binary(Date), Date =/= <<>> -> Date.

% Status is one of: open cancelled expired failed pending paid paidout refunded charged_back
update_payment_status(PaymentId, <<"open">>, Date, Context) ->         mod_payment:set_payment_status(PaymentId, new, Date, Context);
update_payment_status(PaymentId, <<"cancelled">>, Date, Context) ->    mod_payment:set_payment_status(PaymentId, cancelled, Date, Context);
update_payment_status(PaymentId, <<"canceled">>, Date, Context) ->     mod_payment:set_payment_status(PaymentId, cancelled, Date, Context);
update_payment_status(PaymentId, <<"expired">>, Date, Context) ->      mod_payment:set_payment_status(PaymentId, failed, Date, Context);
update_payment_status(PaymentId, <<"failed">>, Date, Context) ->       mod_payment:set_payment_status(PaymentId, failed, Date, Context);
update_payment_status(PaymentId, <<"pending">>, Date, Context) ->      mod_payment:set_payment_status(PaymentId, pending, Date, Context);
update_payment_status(PaymentId, <<"paid">>, Date, Context) ->         mod_payment:set_payment_status(PaymentId, paid, Date, Context);
update_payment_status(PaymentId, <<"paidout">>, Date, Context) ->      mod_payment:set_payment_status(PaymentId, paid, Date, Context);
update_payment_status(PaymentId, <<"refunded">>, Date, Context) ->     mod_payment:set_payment_status(PaymentId, refunded, Date, Context);
update_payment_status(PaymentId, <<"charged_back">>, Date, Context) -> mod_payment:set_payment_status(PaymentId, refunded, Date, Context);
update_payment_status(PaymentId, Status, _Date, _Context) ->
    ?LOG_ERROR(#{
        in => zotonic_mod_payment_mollie,
        text => <<"Payment PSP Mollie webhook call for unknown status">>,
        result => error,
        reason => unknown_status,
        status => Status,
        payment => PaymentId
    }),
    ok.

is_status_equal(StatusA, StatusB) ->
    StatusA1 = map_status(z_convert:to_binary(StatusA)),
    StatusB1 = map_status(z_convert:to_binary(StatusB)),
    StatusA1 =:= StatusB1.

map_status(<<"canceled">>) -> <<"cancelled">>;
map_status(<<"expired">>) -> <<"failed">>;
map_status(<<"open">>) -> <<"new">>;
map_status(<<"paidout">>) -> <<"paid">>;
map_status(<<"charged_back">>) -> <<"refunded">>;
map_status(Status) -> Status.



api_call(Method, Endpoint, Args, Context) ->
    case api_key(Context) of
        {ok, ApiKey} ->
            Url = case Endpoint of
                <<"https:", _/binary>> -> z_convert:to_list(Endpoint);
                "https:" ++ _ -> Endpoint;
                _ -> ?MOLLIE_API_URL ++ z_convert:to_list(Endpoint)
            end,
            Hs = [
                {"Authorization", "Bearer " ++ z_convert:to_list(ApiKey)}
            ],
            Request = case Method of
                          get ->
                              {Url, Hs};
                          _ ->
                              FormData = lists:map(
                                            fun({K,V}) ->
                                                {z_convert:to_list(K), z_convert:to_list(V)}
                                            end,
                                            Args),
                              Body = mochiweb_util:urlencode(FormData),
                              {Url, Hs, "application/x-www-form-urlencoded", Body}
                      end,
            ?LOG_DEBUG(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Making API call to Mollie">>,
                url => Url,
                method => Method,
                args => Args
            }),
            case httpc:request(
                    Method, Request,
                    [ {autoredirect, true}, {relaxed, false},
                      {timeout, ?TIMEOUT_REQUEST}, {connect_timeout, ?TIMEOUT_CONNECT} ],
                    [ {sync, true}, {body_format, binary} ])
            of
                {ok, {{_, X20x, _}, Headers, Payload}} when ((X20x >= 200) and (X20x < 400)) ->
                    case proplists:get_value("content-type", Headers) of
                        undefined ->
                            {ok, Payload};
                        ContentType ->
                            case binary:match(list_to_binary(ContentType), <<"json">>) of
                                nomatch ->
                                    {ok, Payload};
                                _ ->
                                    Props = z_json:decode(Payload),
                                    {ok, Props}
                            end
                    end;
                {ok, {{_, 410, _}, Headers, Payload}} ->
                    ?LOG_DEBUG(#{
                        in => zotonic_mod_payment_mollie,
                        text => <<"Mollie API call error return">>,
                        result => error,
                        reason => 410,
                        url => Url,
                        status => 410,
                        payload => Payload,
                        headers => Headers
                    }),
                    {error, 410};
                {ok, {{_, Code, _}, Headers, Payload}} ->
                    ?LOG_ERROR(#{
                        in => zotonic_mod_payment_mollie,
                        text => <<"Mollie API call error return">>,
                        result => error,
                        reason => Code,
                        url => Url,
                        status => Code,
                        payload => Payload,
                        headers => Headers
                    }),
                    {error, Code};
                {error, Reason} = Error ->
                    ?LOG_ERROR(#{
                        in => zotonic_mod_payment_mollie,
                        text => <<"Mollie API call error">>,
                        result => error,
                        reason => Reason,
                        url => Url
                    }),
                    Error
            end;
        {error, notfound} ->
            {error, api_key_not_set}
    end.

%% @doc Check if the current API Key is live or test.
-spec is_test( z:context() ) -> boolean().
is_test(Context) ->
    case api_key(Context) of
        {ok, <<"test_", _/binary>>} -> true;
        _ -> false
    end.

-spec api_key(z:context()) -> {ok, binary()} | {error, notfound}.
api_key(Context) ->
    case m_config:get_value(mod_payment_mollie, api_key, Context) of
        undefined -> {error, notfound};
        <<>> -> {error, notfound};
        ApiKey -> {ok, ApiKey}
    end.


is_valid_mandate(#{ <<"status">> := <<"pending">> }) -> true;
is_valid_mandate(#{ <<"status">> := <<"valid">> }) -> true;
is_valid_mandate(_) -> false.


maybe_create_subscription(FirstPayment, Context) ->
    case maps:get(<<"psp_data">>, FirstPayment) of
        #{
            <<"sequenceType">> := <<"first">>,
            <<"customerId">> := CustomerId
        } ->
            % v2 API data
            maybe_create_subscription_1(FirstPayment, CustomerId, Context);
        #{
            <<"recurringType">> := <<"first">>,
            <<"customerId">> := CustomerId
        } ->
            % v1 API data
            maybe_create_subscription_1(FirstPayment, CustomerId, Context);
        PspData ->
            % Log an error with the payment
            PaymentId = maps:get(<<"id">>, FirstPayment),
            UserId = maps:get(<<"user_id">>, FirstPayment),
            m_payment_log:log(
                PaymentId,
                <<"ERROR">>,
                [
                    {psp_module, mod_payment_mollie},
                    {description, <<"Could not create a subscription: PSP data missing sequenceType and/or customerId">>}
                ],
                Context),
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Mollie payment PSP data missing sequenceType and/or customerId">>,
                result => error,
                reason => pspdata,
                payment => PaymentId,
                user => UserId,
                data => PspData
            }),
            {error, pspdata}
    end.

maybe_create_subscription_1(FirstPayment, CustomerId, Context) ->
    Created = maps:get(<<"created">>, FirstPayment),
    RecentDate = z_datetime:prev_month(calendar:universal_time(), 2),
    if
        RecentDate < Created ->
            create_subscription_1(FirstPayment, CustomerId, Context);
        true ->
            ok
    end.

create_subscription_1(FirstPayment, CustomerId, Context) ->
    PaymentId = maps:get(<<"id">>, FirstPayment),
    UserId = maps:get(<<"user_id">>, FirstPayment),
    case api_call(get, "customers/" ++ z_convert:to_list(CustomerId) ++ "/mandates", [], Context) of
        {ok, #{
            <<"_embedded">> := #{
                <<"mandates">> := Mandates
            }
        }} ->
            case lists:any(fun is_valid_mandate/1, Mandates) of
                true ->
                    WebhookUrl = webhook_url(maps:get(<<"payment_nr">>, FirstPayment), Context),
                    Args = [
                        {'amount[value]', filter_format_price:format_price(maps:get(<<"amount">>, FirstPayment), Context)},
                        {'amount[currency]', maps:get(<<"currency">>, FirstPayment, <<"EUR">>)},
                        {interval, subscription_interval(Context)},
                        {startDate, subscription_start_date(Context)},
                        {webhookUrl, WebhookUrl},
                        {description, subscription_description(FirstPayment, CustomerId, Context)}
                    ],
                    case api_call(post, "customers/" ++ z_convert:to_list(CustomerId) ++ "/subscriptions",
                                  Args, Context)
                    of
                        {ok, #{
                            <<"resource">> := <<"subscription">>,
                            <<"status">> := SubStatus
                        } = Sub} ->
                            ?LOG_INFO(#{
                                in => zotonic_mod_payment_mollie,
                                text => <<"Mollie created subscription">>,
                                payment => PaymentId,
                                user => UserId,
                                customer => CustomerId,
                                status => SubStatus
                            }),
                            m_payment_log:log(
                                PaymentId,
                                <<"SUBSCRIPTION">>,
                                [
                                    {psp_module, mod_payment_mollie},
                                    {description, <<"Created subscription">>},
                                    {request_result, Sub}
                                ],
                                Context),
                            ok;
                        {ok, JSON} ->
                            m_payment_log:log(
                                PaymentId,
                                <<"ERROR">>,
                                [
                                    {psp_module, mod_payment_mollie},
                                    {description, <<"API Unexpected result creating subscription from Mollie">>},
                                    {request_result, JSON}
                                ],
                                Context),
                            ?LOG_ERROR(#{
                                in => zotonic_mod_payment_mollie,
                                text => <<"Mollie created subscription but unexpected result">>,
                                result => error,
                                reason => json,
                                payment => PaymentId,
                                customer => CustomerId,
                                user => UserId,
                                data => JSON
                            }),
                            {error, unexpected_result};
                        {error, Reason} = Error ->
                            ?LOG_ERROR(#{
                                in => zotonic_mod_payment_mollie,
                                text => <<"Mollie error creating subscription">>,
                                result => error,
                                reason => Reason,
                                payment => PaymentId,
                                customer => CustomerId,
                                user => UserId
                            }),
                            m_payment_log:log(
                                PaymentId,
                                <<"ERROR">>,
                                [
                                    {psp_module, mod_payment_mollie},
                                    {description, <<"API Error creating subscription">>},
                                    {request_result, Error}
                                ],
                                Context),
                            Error
                    end;
                false ->
                    ?LOG_INFO(#{
                        in => zotonic_mod_payment_mollie,
                        text => <<"Mollie created a subscription request but no valid mandates">>,
                        payment => PaymentId,
                        customer => CustomerId,
                        user => UserId
                    }),
                    m_payment_log:log(
                        PaymentId,
                        <<"WARNING">>,
                        [
                            {psp_module, mod_payment_mollie},
                            {description, <<"Cannot create a subscription - no valid mandates">>}
                        ],
                        Context),
                    ok
            end;
        {ok, JSON} ->
            % Log an error with the payment
            m_payment_log:log(
                PaymentId,
                <<"ERROR">>,
                [
                    {psp_module, mod_payment_mollie},
                    {description, <<"API Unexpected result fetching mandates from Mollie">>},
                    {request_result, JSON}
                ],
                Context),
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Mollie created subscription but unexpected result">>,
                result => error,
                reason => json,
                payment => PaymentId,
                customer => CustomerId,
                user => UserId,
                data => JSON
            }),
            {error, unexpected_result};
        {error, Reason} = Error ->
            % Log an error with the payment
            m_payment_log:log(
                PaymentId,
                <<"ERROR">>,
                [
                    {psp_module, mod_payment_mollie},
                    {description, <<"API Error fetching mandates from Mollie">>},
                    {request_result, Error}
                ],
                Context),
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Mollie error fetching mandates">>,
                result => error,
                reason => Reason,
                payment => PaymentId,
                customer => CustomerId,
                user => UserId
            }),
            Error
    end.

subscription_description(#{ <<"user_id">> := undefined, <<"email">> := Email }, CustomerId, _Context) ->
    subscription_description1(Email, CustomerId);
subscription_description(#{ <<"user_id">> := UserId }, CustomerId, Context) ->
    Email = z_convert:to_binary( m_rsc:p_no_acl(UserId, email, Context) ),
    subscription_description1(Email, CustomerId).

subscription_description1(Email, CustomerId) ->
    <<"Subscription for ", Email/binary, " - ", CustomerId/binary>>.

subscription_interval(Context) ->
    case m_config:get_value(mod_payment_mollie, recurring_payment_interval, Context) of
        <<"monthly">> -> <<"1 months">>;
        <<"yearly">> -> <<"12 months">>;
        _ -> <<"12 months">>
    end.

subscription_start_date(Context) ->
    {Today, _} = calendar:local_time(),
    case subscription_interval(Context) of
        <<"1 months">> ->
            format_date(filter_add_month:add_month(Today, Context));
        <<"12 months">> ->
            format_date(filter_add_year:add_year(Today, Context))
    end.

format_date({{Year, Month, Day}, _}) ->
    list_to_binary(io_lib:format("~4..0w-~2..0w-~2..0w", [Year, Month, Day])).

list_subscriptions(UserId, Context) ->
    CustIds = mollie_customer_ids(UserId, true, Context),
    list_subscriptions1(CustIds, Context).

list_subscriptions_from_email(Email, Context) ->
    CustIds = mollie_customer_ids_from_email(Email, true, Context),
    list_subscriptions1(CustIds, Context).

list_subscriptions1(CustIds, Context) ->
    try
        Subs = lists:map(
            fun(CustId) ->
                case mollie_list_subscriptions(CustId, Context) of
                    {ok, S} -> S;
                    {error, _} = E -> throw(E)
                end
            end,
            CustIds),
        {ok, lists:map(fun parse_sub/1, lists:flatten(Subs))}
    catch
        throw:{error, _} = E -> E
    end.

mollie_list_subscriptions(CustId, Context) ->
    case api_call(get, "customers/" ++ z_convert:to_list(CustId) ++ "/subscriptions?limit=250", [], Context) of
        {ok, #{ <<"_embedded">> := #{ <<"subscriptions">> := Data } } = Result} ->
            Links = maps:get(<<"_links">>, Result, #{}),
            case mollie_list_subscriptions_next(Links, Context) of
                {ok, NextData} ->
                    {ok, Data ++ NextData};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

mollie_list_subscriptions_next(#{ <<"next">> := #{ <<"href">> := Next } }, Context) when is_binary(Next), Next =/= <<>> ->
    case api_call(get, Next, [], Context) of
        {ok, #{ <<"_embedded">> := #{ <<"subscriptions">> := Data }, <<"_links">> := Links }} ->
            case mollie_list_subscriptions_next(Links, Context) of
                {ok, NextData} ->
                    {ok, Data ++ NextData};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
mollie_list_subscriptions_next(#{}, _Context) ->
    {ok, []}.


parse_sub(#{
        <<"resource">> := <<"subscription">>,
        <<"id">> := SubId,
        <<"customerId">> := CustId,
        <<"startDate">> := Start,
        <<"amount">> := #{
            <<"currency">> := Currency,
            <<"value">> := Amount
        },
        <<"interval">> := Interval,
        <<"description">> := Description
    } = Sub) ->
    Cancelled = maps:get(<<"canceledAt">>, Sub, undefined),
    #{
        id => {mollie_subscription, CustId, SubId},
        is_valid => is_null(Cancelled),
        start_date => to_date(Start),
        end_date => to_date(Cancelled),
        description => Description,
        interval => Interval,
        amount => z_convert:to_float(Amount),
        currency => Currency
    }.

is_null(undefined) -> true;
is_null(null) -> true;
is_null(<<>>) -> true;
is_null(_) -> false.

to_date(undefined) -> undefined;
to_date(null) -> undefined;
to_date(<<>>) -> undefined;
to_date(D) -> z_datetime:to_datetime(D).


has_subscription(UserId, Context) ->
    has_subscription1(list_subscriptions(UserId, Context)).

has_subscription_from_email(Email, Context) ->
    has_subscription1(list_subscriptions_from_email(Email, Context)).

has_subscription1({ok, Subs}) ->
    lists:any(fun is_subscription_active/1, Subs);
has_subscription1({error,_}) ->
    false.

is_subscription_active(#{ end_date := undefined }) -> true;
is_subscription_active(#{ end_date := _}) -> false.


cancel_subscription({mollie_subscription, CustId, SubId}, Context) ->
    case api_call(delete, "customers/" ++
                      z_convert:to_list(CustId) ++
                      "/subscriptions/" ++
                      z_convert:to_list(SubId),
                  [], Context) of
        {ok, _} ->
            ?LOG_INFO(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Mollie subscription canceled">>,
                result => ok,
                subscription => SubId,
                customer => CustId
            }),
            ok;
        {error, 410} ->
            ?LOG_INFO(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Mollie subscription already canceled">>,
                result => ok,
                reason => 410,
                subscription => SubId,
                customer => CustId
            }),
            ok;
        {error, 422} ->
            ?LOG_INFO(#{
                in => zotonic_mod_payment_mollie,
                text => <<"Mollie subscription already canceled(?)">>,
                result => ok,
                reason => 422,
                subscription => SubId,
                customer => CustId
            }),
            ok;
        {error, Reason} = Error ->
            ?LOG_ERROR(#{
                in => zotonic_mod_payment_mollie,
                text => <<"API error cancelling mollie subscription">>,
                result => error,
                reason => Reason,
                subscription => SubId,
                customer => CustId
            }),
            Error
    end;
cancel_subscription(UserId, Context) when is_integer(UserId) ->
    cancel_subscriptions(list_subscriptions(UserId, Context), Context);
cancel_subscription(Email, Context) when is_binary(Email) ->
    cancel_subscriptions(list_subscriptions_from_email(Email, Context), Context).

cancel_subscriptions({ok, Subs}, Context) ->
    lists:foldl(
      fun
          (#{ id := SubId, end_date := undefined }, ok) ->
              cancel_subscription(SubId, Context);
          (#{ id := _SubId, end_date := {_, _} }, ok) ->
              ok;
          (_, {error, _} = Error) ->
              Error
      end,
      ok,
      Subs);
cancel_subscriptions({error, _}=Error, _Context) ->
    Error.

%% @doc Find the most recent valid customer id for a given user or create a new customer
-spec ensure_mollie_customer_id( m_rsc:resource_id(), z:context() ) -> {ok, binary()} | {error, term()}.
ensure_mollie_customer_id(UserId, Context) ->
    case m_rsc:exists(UserId, Context) of
        true ->
            case mollie_customer_id(UserId, false, Context) of
                {ok, CustId} ->
                    {ok, CustId};
                {error, enoent} ->
                    ContextSudo = z_acl:sudo(Context),
                    Email = m_rsc:p_no_acl(UserId, email, Context),
                    {Name, _Context} = z_template:render_to_iolist("_name.tpl", [ {id, UserId} ], ContextSudo),
                    create_mollie_customer_id(Name, Email, Context);
                {error, _} = Error ->
                    Error
            end;
        false ->
            {error, resource_does_not_exist}
    end.

%% @doc Create a new customer
create_mollie_customer_id(Name, Email, Context) ->
    Args = [
            {name, iolist_to_binary(Name)},
            {email, Email}
           ],
    case api_call(post, "customers", Args, Context) of
        {ok, Json} ->
            {ok, maps:get(<<"id">>, Json)};
        {error, _} = Error ->
            Error
    end.

%% @doc Find the most recent valid customer id for a given user
-spec mollie_customer_id( m_rsc:resource_id(), boolean(), z:context() ) -> {ok, binary()} | {error, term()}.
mollie_customer_id(UserId, OnlyRecurrent, Context) ->
    CustIds = mollie_customer_ids(UserId, OnlyRecurrent, Context),
    first_valid_custid(CustIds, Context).

%% @doc Find the most recent valid customer id for a given email address 
-spec mollie_customer_id_from_email( binary(), boolean(), z:context() ) -> {ok, binary()} | {error, term()}.
mollie_customer_id_from_email(Email, OnlyRecurrent, Context) ->
    CustIds = mollie_customer_ids_from_email(Email, OnlyRecurrent, Context),
    first_valid_custid(CustIds, Context).

first_valid_custid([], _Context) ->
    {error, enoent};
first_valid_custid([ CustomerId | CustIds ], Context) ->
    case api_call(get, "customers/" ++ z_convert:to_list(CustomerId), [], Context) of
        {ok, _Cust} ->
            {ok, CustomerId};
        {error, 404} ->
            first_valid_custid(CustIds, Context);
        {error, 410} ->
            first_valid_custid(CustIds, Context);
        {error, _} = Error ->
            Error
    end.

%% @doc List all Mollie customer ids for the given user.
%% The newest created customer id is listed first.
-spec mollie_customer_ids( m_rsc:resource_id(), boolean(), z:context() ) -> [ binary() ].
mollie_customer_ids(UserId, OnlyRecurrent, Context) ->
    Payments = m_payment:list_user(UserId, Context),
    mollie_customer_ids1(Payments, OnlyRecurrent).

%% @doc List all Mollie customer ids for the given email address.
%% The newest created customer id is listed first.
-spec mollie_customer_ids_from_email( binary(), boolean(), z:context() ) -> [ binary() ].
mollie_customer_ids_from_email(Email, OnlyRecurrent, Context) ->
    Payments = m_payment:list_email(Email, Context),
    mollie_customer_ids1(Payments, OnlyRecurrent).

mollie_customer_ids1(Payments, OnlyRecurrent) ->
    CustIds = lists:foldl(
        fun
            (#{ <<"psp_module">> := mod_payment_mollie } = Payment, Acc) ->
                case maps:get(<<"psp_data">>, Payment) of
                    #{
                        <<"customerId">> := CustId
                    } = PspData when is_binary(CustId) ->
                        RecType = sequenceType(PspData),
                        if
                            not OnlyRecurrent orelse (RecType =/= <<>>) ->
                                case lists:member(CustId, Acc) of
                                    true -> Acc;
                                    false -> [ CustId | Acc ]
                                end;
                            true ->
                                Acc
                        end;
                    _ ->
                        Acc

                end;
            (_Payment, Acc) ->
                Acc
        end,
        [],
        Payments),
    lists:reverse(CustIds).



sequenceType(#{ <<"sequenceType">> := SequenceType }) -> SequenceType;  % v2 API
sequenceType(#{ <<"recurringType">> := SequenceType }) -> SequenceType; % v1 API
sequenceType(_) -> <<>>.

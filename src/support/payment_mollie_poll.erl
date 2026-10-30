%% @copyright 2026 Driebit BV
%% @doc Discover Mollie payments and late refunds using their creation timelines.
%% @end

%% Copyright 2026 Driebit BV
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

-module(payment_mollie_poll).
-export([page/2]).
-include_lib("zotonic_mod_payment/include/payment.hrl").

-spec page(#payment_psp_poll{}, z:context()) -> {ok, list(), term()} | {error, term()}.
page(#payment_psp_poll{cursor = {refunds, Cursor}} = Request, Context) ->
    refunds(Request#payment_psp_poll{cursor = Cursor}, Context);
page(#payment_psp_poll{since = Since, until = Until, cursor = Cursor}, Context) ->
    Query = case Cursor of
        undefined -> "limit=250";
        _ -> mochiweb_util:urlencode([{limit, 250}, {from, Cursor}])
    end,
    case m_payment_mollie_api:api_call(get, "payments?" ++ Query, [], Context) of
        {ok, #{<<"_embedded">> := #{<<"payments">> := Payments}, <<"_links">> := Links}} ->
            Dated = [{z_convert:to_datetime(maps:get(<<"createdAt">>, P)), P} || P <- Payments],
            Data = [(payment(P))#{created_at => Date} || {Date, P} <- Dated, Date >= Since, Date =< Until],
            Next = case lists:any(fun({D, _}) -> D < Since end, Dated) of
                true -> undefined;
                false -> next_cursor(maps:get(<<"next">>, Links, undefined))
            end,
            {ok, Data, case Next of undefined -> {refunds, undefined}; _ -> Next end};
        {error, _} = Error -> Error;
        _ -> {error, payment_list}
    end.

%% Extract only the opaque cursor. Never send credentials to a pagination URL.
next_cursor(#{<<"href">> := Url}) ->
    #{query := Query} = uri_string:parse(Url),
    {_, From} = lists:keyfind(<<"from">>, 1, uri_string:dissect_query(Query)),
    From;
next_cursor(undefined) -> undefined;
next_cursor(null) -> undefined.

payment(#{<<"id">> := Id, <<"status">> := Status,
          <<"amount">> := #{<<"value">> := Value, <<"currency">> := Currency}} = P) ->
    Amount = z_convert:to_float(Value),
    {LocalStatus, DateKey} = status(Status),
    %% A refunds/chargebacks link alone does not imply a full reversal.
    Reversed = reversed(<<"amountRefunded">>, Amount, P)
        orelse reversed(<<"amountChargedBack">>, Amount, P),
    #{psp_external_id => Id, amount => Amount, currency => Currency,
      status => case Reversed of true -> refunded; false -> LocalStatus end,
      status_date => case Reversed of
          true -> calendar:universal_time();
          false -> z_convert:to_datetime(maps:get(DateKey, P, maps:get(<<"createdAt">>, P)))
      end,
      description => maps:get(<<"description">>, P, <<>>), psp_data => P}.

reversed(Key, Amount, P) ->
    case maps:get(Key, P, undefined) of
        #{<<"value">> := V} when Amount > 0 -> z_convert:to_float(V) >= Amount;
        _ -> false
    end.

status(<<"open">>) -> {new, <<"createdAt">>};
status(<<"pending">>) -> {pending, <<"createdAt">>};
status(<<"authorized">>) -> {pending, <<"authorizedAt">>};
status(<<"paid">>) -> {paid, <<"paidAt">>};
status(<<"canceled">>) -> {cancelled, <<"canceledAt">>};
status(<<"expired">>) -> {cancelled, <<"expiredAt">>};
status(<<"failed">>) -> {failed, <<"failedAt">>}.

%% Refund creation is a separate event timeline, including refunds of old payments.
refunds(#payment_psp_poll{since = Since, until = Until, cursor = Cursor}, Context) ->
    Args = [{limit, 250}] ++ case Cursor of undefined -> []; _ -> [{from, Cursor}] end,
    case m_payment_mollie_api:api_call(get, "refunds?" ++ mochiweb_util:urlencode(Args), [], Context) of
        {ok, #{<<"_embedded">> := #{<<"refunds">> := Refunds}, <<"_links">> := Links}} ->
            Dated = [{z_convert:to_datetime(maps:get(<<"createdAt">>, R)), R} || R <- Refunds],
            Selected = [{Date, R} || {Date, R} <- Dated, Date >= Since, Date =< Until],
            case refund_payments(Selected, Context, []) of
                {ok, Data} ->
                    Next = case lists:any(fun({D, _}) -> D < Since end, Dated) of
                        true -> undefined;
                        false -> next_cursor(maps:get(<<"next">>, Links, undefined))
                    end,
                    {ok, Data, case Next of undefined -> undefined; _ -> {refunds, Next} end};
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error;
        _ -> {error, refund_list}
    end.

refund_payments([], _, Acc) -> {ok, lists:reverse(Acc)};
refund_payments([{Date, #{<<"paymentId">> := Id}} | Rest], Context, Acc) ->
    case m_payment_mollie_api:api_call(get, <<"payments/", (uri_string:quote(Id))/binary>>, [], Context) of
        {ok, Payment} ->
            Data = (payment(Payment))#{updated_at => Date},
            refund_payments(Rest, Context, [Data | Acc]);
        {error, _} = Error -> Error
    end.

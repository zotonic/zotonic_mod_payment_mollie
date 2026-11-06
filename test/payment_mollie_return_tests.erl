%% @copyright 2026 Marc Worrell
%% @doc Return-page synchronization happens before rendering and respects access.
-module(payment_mollie_return_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("zotonic_core/include/zotonic.hrl").

return_test() ->
    Modules = [m_payment, m_payment_mollie_config, m_payment_mollie_api, m_req],
    meck:new(Modules, [passthrough, no_link]),
    try
        meck:expect(m_req, get, fun(method, _) -> <<"GET">> end),
        meck:expect(m_payment_mollie_config, webhooks, fun(_) -> #{enabled => get(enabled)} end),
        meck:expect(m_payment, m_get, fun([<<"status">>, <<"secret-number">>], _, _) ->
            case get(allowed) of true -> {ok, {#{}, []}}; false -> {error, eacces} end
        end),
        meck:expect(m_payment, get, fun(<<"secret-number">>, _) ->
            {ok, #{<<"id">> => 42, <<"psp_module">> => get(psp)}}
        end),
        meck:expect(m_payment_mollie_api, payment_sync, fun(42, _) ->
            put(synced, true), get(sync_result)
        end),
        C = z_context:set(zotonic_dispatch, payment_psp_done,
            z_context:set_q_all([{<<"payment_nr">>, <<"secret-number">>}], #context{cowreq = #{}})),
        put(sync_result, ok),
        lists:foreach(fun({Enabled, Allowed, Psp, Expected}) ->
            put(enabled, Enabled), put(allowed, Allowed), put(psp, Psp), erase(synced),
            Result = mod_payment_mollie:observe_request_context(#request_context{phase = refresh}, C, C),
            ?assertEqual(Expected, get(synced)),
            ?assertMatch(#context{}, Result)
        end, [{false, true, mod_payment_mollie, true},
              {true, true, mod_payment_mollie, undefined},
              {false, false, mod_payment_mollie, undefined},
              {false, true, mod_payment_stripe, undefined}]),
        put(psp, mod_payment_mollie), put(sync_result, {error, timeout}),
        ?assertMatch(#context{}, mod_payment_mollie:observe_request_context(#request_context{phase = refresh}, C, C)),
        erase(synced),
        Other = z_context:set(zotonic_dispatch, home, C),
        ?assertEqual(Other, mod_payment_mollie:observe_request_context(#request_context{phase = refresh}, Other, Other)),
        ?assertEqual(undefined, get(synced)),
        ?assertEqual(C, mod_payment_mollie:observe_request_context(#request_context{phase = init}, C, C))
    after meck:unload(Modules)
    end.

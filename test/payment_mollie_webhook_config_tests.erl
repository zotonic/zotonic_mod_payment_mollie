%% @copyright 2026 Marc Worrell
%% @doc Optional webhook policy and HTTP payloads in the sandbox.
-module(payment_mollie_webhook_config_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("zotonic_core/include/zotonic.hrl").

webhooks_test() ->
    meck:new([m_config, z_context, httpc], [passthrough, no_link]),
    try
        meck:expect(m_config, get_value, fun
            (mod_payment_mollie, webhook_host, _) -> get(origin);
            (mod_payment_mollie, api_key, _) -> <<"test_mock">>
        end),
        meck:expect(m_config, get_boolean, fun(mod_payment_mollie, disable_webhooks, _) -> get(disabled) =:= true end),
        meck:expect(z_context, abs_url, fun(_, _) -> <<"https://wallet.test/">> end),
        C = z_acl:sudo(z_context:new(zotonic_site_testsandbox)),
        lists:foreach(fun({Origin, Disabled, Enabled}) ->
            put(origin, Origin), put(disabled, Disabled),
            ?assertMatch(#{enabled := Enabled}, m_payment_mollie_config:webhooks(C))
        end, [{undefined, false, false}, {<<"https://wallet.TEST:8443">>, false, false},
              {<<"http://localhost:8000">>, false, false},
              {<<"https://public.example.org">>, false, true},
              {<<"https://public.example.org">>, true, false}]),
        put(origin, undefined), put(disabled, false),
        ?assertEqual(undefined, m_payment_mollie_api:webhook_url(<<"payment">>, C)),
        ?assertEqual({error, eacces}, m_payment_mollie_config:m_get([<<"webhooks">>], #{}, #context{})),
        %% Mollie's create-payment and create-subscription docs make webhookUrl
        %% optional. Omit it entirely, rather than sending an empty string.
        meck:expect(httpc, request, fun(post, {_, _, _, Body}, _, _) ->
            ?assertEqual(nomatch, binary:match(iolist_to_binary(Body), <<"webhookUrl">>)),
            {ok, {{"HTTP/1.1", 201, "Created"}, [{"content-type", "application/json"}], <<"{}">>}}
        end),
        lists:foreach(fun(Path) ->
            ?assertEqual({ok, #{}}, m_payment_mollie_api:api_call(post, Path,
                [{description, <<"Test">>}, {webhookUrl, undefined}], C))
        end, ["payments", "customers/cst_mock/subscriptions"])
    after meck:unload([m_config, z_context, httpc])
    end.

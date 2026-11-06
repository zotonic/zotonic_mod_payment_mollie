%% @copyright 2026 Marc Worrell
%% @doc Profile migration and verified payment updates in the Zotonic sandbox.
-module(payment_mollie_profile_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("zotonic_core/include/zotonic.hrl").

profile_test() ->
    C = z_acl:sudo(z_context:new(zotonic_site_testsandbox)),
    Old = {{2001, 1, 1}, {0, 0, 0}},
    {ok, Id} = z_db:insert(payment, #{<<"payment_nr">> => <<"profile-migration-test">>,
        <<"psp_module">> => mod_payment_mollie, <<"psp_external_id">> => <<"tr_profile_migration">>,
        <<"amount">> => 12.34, <<"currency">> => <<"EUR">>, <<"modified">> => Old,
        <<"psp_data">> => ?DB_PROPS(#{<<"profileId">> => <<"pfl_original">>})}, C),
    try
        ok = mod_payment_mollie:manage_schema(install, C),
        ok = mod_payment_mollie:manage_schema(install, C),
        {ok, P} = m_payment:get(Id, C),
        ?assertEqual(<<"pfl_original">>, maps:get(<<"psp_profile_id">>, P)),
        ?assertEqual(Old, maps:get(<<"modified">>, P)),
        D = #{psp_external_id => <<"tr_profile_migration">>, psp_profile_id => <<"pfl_original">>,
            status => paid, status_date => calendar:universal_time(),
            amount => 12.34, currency => <<"EUR">>},
        {ok, Paid} = mod_payment:receive_payment(mod_payment_mollie, D, C),
        ?assertEqual(<<"pfl_original">>, maps:get(<<"psp_profile_id">>, Paid)),
        {ok, Again} = mod_payment:receive_payment(mod_payment_mollie, maps:remove(psp_profile_id, D), C),
        ?assertEqual(<<"pfl_original">>, maps:get(<<"psp_profile_id">>, Again)),
        %% A missing webhook must still find a known payment by its PSP ID.
        OldKey = m_config:get_value(mod_payment_mollie, api_key, <<>>, C),
        m_config:set_value(mod_payment_mollie, api_key, <<"test_sync_mock">>, C),
        meck:new(httpc, [passthrough, no_link]),
        try
            meck:expect(httpc, request, fun(get, _, _, _) ->
                Json = #{<<"resource">> => <<"payment">>, <<"id">> => <<"tr_profile_migration">>,
                       <<"webhookUrl">> => null, <<"status">> => <<"paid">>,
                       <<"paidAt">> => <<"2026-11-06T10:00:00+00:00">>,
                       <<"createdAt">> => <<"2026-11-06T09:00:00+00:00">>,
                       <<"profileId">> => <<"pfl_original">>},
                {ok, {{"HTTP/1.1", 200, "OK"}, [{"content-type", "application/json"}], z_json:encode(Json)}}
            end),
            ?assertEqual(ok, m_payment_mollie_api:payment_sync(Id, C))
        after
            meck:unload(httpc),
            m_config:set_value(mod_payment_mollie, api_key, OldKey, C)
        end
    after
        z_db:q("delete from payment_log where payment_id = $1", [Id], C),
        z_db:q("delete from payment where id = $1", [Id], C)
    end.

%% @copyright 2026 Marc Worrell
%% @doc Mollie Profiles API contract and cache tests in the Zotonic sandbox.
%% Licensed under the Apache License, Version 2.0.
-module(payment_mollie_profiles_api_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("zotonic_core/include/zotonic.hrl").

%% Fixtures and pagination follow https://docs.mollie.com/reference/list-profiles
%% and https://docs.mollie.com/reference/get-current-profile, not our payment code.
profiles_test() ->
    C = z_acl:sudo(z_context:new(zotonic_site_testsandbox)),
    OldKey = m_config:get_value(mod_payment_mollie, api_key, <<>>, C),
    OldToken = m_config:get_value(mod_payment_mollie, profiles_access_token, <<>>, C),
    Key = <<"test_profiles_contract">>,
    Token = <<"access_profiles_contract">>,
    meck:new(httpc, [passthrough, no_link]),
    try
        ?assertEqual({error, eacces}, m_payment_mollie_profiles:m_get([<<"list">>], #{}, #context{})),
        m_config:set_value(mod_payment_mollie, api_key, Key, C),
        m_config:set_value(mod_payment_mollie, profiles_access_token, <<>>, C),
        meck:expect(httpc, request, fun(get, {Url, Headers}, Options, _) ->
            ?assertEqual("https://api.mollie.com/v2/profiles/me", Url),
            ?assertEqual("Bearer test_profiles_contract", proplists:get_value("Authorization", Headers)),
            ?assertEqual(false, proplists:get_value(autoredirect, Options)),
            reply(profile(<<"pfl_QkEhN94Ba">>, <<"My website name">>))
        end),
        #{profiles := [P], is_stale := false} = m_payment_mollie_profiles:list(C),
        ?assertEqual(<<"My website name">>, maps:get(<<"name">>, P)),
        m_payment_mollie_profiles:list(C),
        ?assertEqual(1, meck:num_calls(httpc, request, '_')),
        m_config:set_value(mod_payment_mollie, profiles_access_token, Token, C),
        meck:expect(httpc, request, fun(get, {Url, Headers}, _, _) ->
            ?assertEqual("Bearer access_profiles_contract", proplists:get_value("Authorization", Headers)),
            case Url of
                "https://api.mollie.com/v2/profiles?limit=250" ->
                    reply(page([P], #{<<"href">> => <<"https://api.mollie.com/v2/profiles?from=pfl_next&limit=250">>}));
                "https://api.mollie.com/v2/profiles?from=pfl_next&limit=250" ->
                    reply(page([profile(<<"pfl_next">>, <<"Second website">>)], null))
            end
        end),
        #{profiles := Both, is_stale := false} = m_payment_mollie_profiles:list(C),
        ?assertEqual(2, length(Both)),
        CacheKey = {m_payment_mollie_profiles, crypto:hash(sha256, term_to_binary({token, Token}))},
        z_depcache:flush(CacheKey, C),
        meck:expect(httpc, request, fun(_, _, _, _) -> {error, timeout} end),
        ?assertEqual(#{profiles => Both, is_stale => true}, m_payment_mollie_profiles:list(C)),
        z_depcache:flush(CacheKey, C),
        meck:expect(httpc, request, fun(_, _, _, _) ->
            reply(page([P], #{<<"href">> => <<"https://example.org/steal-token">>}))
        end),
        ?assertEqual(#{profiles => Both, is_stale => true}, m_payment_mollie_profiles:list(C)),
        %% A changed credential must never inherit the previous credential's cache.
        m_config:set_value(mod_payment_mollie, profiles_access_token, <<"access_other">>, C),
        meck:expect(httpc, request, fun(_, _, _, _) ->
            {ok, {{"HTTP/1.1", 403, "Forbidden"}, [], <<"{}">>}}
        end),
        ?assertEqual(#{profiles => [], is_stale => true}, m_payment_mollie_profiles:list(C))
    after
        meck:unload(httpc),
        m_config:set_value(mod_payment_mollie, api_key, OldKey, C),
        m_config:set_value(mod_payment_mollie, profiles_access_token, OldToken, C)
    end.

profile(Id, Name) ->
    #{<<"resource">> => <<"profile">>, <<"id">> => Id, <<"name">> => Name,
      <<"mode">> => <<"live">>, <<"website">> => <<"https://shop.example.org">>,
      <<"status">> => <<"verified">>}.
page(Profiles, Next) ->
    #{<<"count">> => length(Profiles), <<"_embedded">> => #{<<"profiles">> => Profiles},
      <<"_links">> => #{<<"next">> => Next}}.
reply(Json) ->
    {ok, {{"HTTP/1.1", 200, "OK"}, [{"content-type", "application/hal+json"}], z_json:encode(Json)}}.

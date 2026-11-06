%% @copyright 2026 Marc Worrell
%% @doc Cached Mollie profiles for administrative source selection.
%% Licensed under the Apache License, Version 2.0.
-module(m_payment_mollie_profiles).
-moduledoc(#{zotonic_keywords => ["reference", "model", "payments", "api_and_integration"]}).
-moduledoc("
Look up the current API key's profile, or all profiles accessible to the optional
profiles_access_token with profiles.read permission. The list model path requires
administrator access. Direct list/1 calls are for trusted server-side callers.
Results are cached for 15 minutes, with the last successful list retained for one
day on errors. Cache entries are isolated by credentials. Payment APIs are unaffected.
").
-export([m_get/3, list/1]).

-spec m_get(list(), term(), z:context()) -> {ok, {map(), list()}} | {error, term()}.
m_get([<<"list">> | Rest], _Msg, Context) ->
    case z_acl:is_admin(Context) of
        true -> {ok, {list(Context), Rest}};
        false -> {error, eacces}
    end;
m_get(_, _, _) -> {error, unknown_path}.

-spec list(Context) -> map() when Context :: z:context().
list(Context) ->
    Credentials = credentials(Context),
    Key = {?MODULE, crypto:hash(sha256, term_to_binary(Credentials))},
    z_depcache:memo(fun() ->
        case fetch(Credentials) of
            {ok, Profiles} ->
                z_depcache:set({Key, last_good}, Profiles, 86400, Context),
                #{profiles => Profiles, is_stale => false};
            {error, _} ->
                Profiles = case z_depcache:get({Key, last_good}, Context) of
                    {ok, Previous} -> Previous;
                    undefined -> []
                end,
                #{profiles => Profiles, is_stale => true}
        end
    end, Key, 900, Context).

credentials(Context) ->
    case m_config:get_value(mod_payment_mollie, profiles_access_token, Context) of
        Token when is_binary(Token), Token =/= <<>> -> {token, z_string:trim(Token)};
        _ -> {key, m_payment_mollie_api:api_key(Context)}
    end.

fetch({key, {ok, Key}}) ->
    case request(<<"https://api.mollie.com/v2/profiles/me">>, Key) of
        {ok, #{<<"id">> := _, <<"name">> := _} = Profile} -> {ok, [Profile]};
        {ok, _} -> {error, invalid_response};
        {error, _} = Error -> Error
    end;
fetch({key, {error, _}}) -> {error, no_credentials};
fetch({token, Token}) -> pages(<<"https://api.mollie.com/v2/profiles?limit=250">>, Token, [], []).

pages(Url, Token, Seen, Acc) ->
    case lists:member(Url, Seen) of
        true -> {error, pagination_loop};
        false ->
            case request(Url, Token) of
                {ok, #{<<"_embedded">> := #{<<"profiles">> := Profiles}, <<"_links">> := Links}}
                    when is_list(Profiles), is_map(Links) ->
                    case lists:all(fun valid_profile/1, Profiles) of
                        true -> next(maps:get(<<"next">>, Links, undefined), Token,
                                     [Url | Seen], Acc ++ Profiles);
                        false -> {error, invalid_response}
                    end;
                {ok, _} -> {error, invalid_response};
                {error, _} = Error -> Error
            end
    end.

valid_profile(#{<<"id">> := Id, <<"name">> := Name}) -> is_binary(Id) andalso is_binary(Name);
valid_profile(_) -> false.

next(null, _, _, Acc) -> {ok, Acc};
next(undefined, _, _, Acc) -> {ok, Acc};
%% Never send the token to a host or endpoint supplied by an arbitrary next link.
next(#{<<"href">> := <<"https://api.mollie.com/v2/profiles?", _/binary>> = Url}, Token, Seen, Acc) ->
    pages(Url, Token, Seen, Acc);
next(_, _, _, _) -> {error, invalid_next_link}.

request(Url, Token) ->
    Headers = [{"Authorization", "Bearer " ++ binary_to_list(Token)}],
    case httpc:request(get, {binary_to_list(Url), Headers},
            [{autoredirect, false}, {timeout, 10000}, {connect_timeout, 5000}],
            [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            try {ok, z_json:decode(Body)} catch error:_ -> {error, invalid_json} end;
        {ok, {{_, Code, _}, _, _}} -> {error, Code};
        {error, _} = Error -> Error
    end.

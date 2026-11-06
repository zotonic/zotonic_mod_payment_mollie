%% @copyright 2026 Marc Worrell
%% @doc Effective Mollie webhook configuration.
%% Licensed under the Apache License, Version 2.0.
-module(m_payment_mollie_config).
-moduledoc(#{zotonic_keywords => ["reference", "model", "payments", "configuration"]}).
-moduledoc("The webhooks model path exposes effective webhook configuration to administrators only. A .test hostname is a local-development heuristic, not an Internet reachability check.").
-export([m_get/3, webhooks/1]).

m_get([<<"webhooks">> | Rest], _Msg, Context) ->
    case z_acl:is_admin(Context) of
        true -> {ok, {webhooks(Context), Rest}};
        false -> {error, eacces}
    end;
m_get(_, _, _) -> {error, unknown_path}.

-spec webhooks(Context) -> map() when Context :: z:context().
webhooks(Context) ->
    Origin = case m_config:get_value(mod_payment_mollie, webhook_host, Context) of
        <<"http:", _/binary>> = Host -> Host;
        <<"https:", _/binary>> = Host -> Host;
        _ -> z_context:abs_url(<<"/">>, Context)
    end,
    Hostname = case uri_string:parse(Origin) of
        #{host := H} -> z_string:to_lower(z_convert:to_binary(H));
        _ -> <<>>
    end,
    IsLocal = Hostname =:= <<"localhost">> orelse
        lists:suffix(".test", string:trim(binary_to_list(Hostname), trailing, ".")),
    Disabled = m_config:get_boolean(mod_payment_mollie, disable_webhooks, Context),
    #{enabled => not Disabled andalso not IsLocal, is_local => IsLocal, origin => Origin}.

{% with m.payment_mollie_config.webhooks as webhooks %}
{% with not webhooks.enabled as omitted %}
{% include "_admin_payment_config_section.tpl" module=`mod_payment_mollie` title=_"Mollie" notice=omitted|if:_"Mollie webhooks are omitted for new payments and subscriptions: they are disabled or the webhook host is a local .test or localhost domain. Status updates rely on synchronization. Set a public webhook host to use a tunnel.":"" explanation=_"Discovery polls the API key’s profile every four hours when collecting all payments is enabled. The synchronization cursor is managed automatically." %}
{% endwith %}
{% endwith %}

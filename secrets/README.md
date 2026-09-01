# secrets/

Credential files mounted into containers. **Gitignored** — nothing here is
committed except this README.

## discord-webhook-url

Optional. Only needed if you enable the Discord receiver in
`alertmanager/alertmanager.yml`.

```bash
printf '%s' 'https://discord.com/api/webhooks/...' > secrets/discord-webhook-url
chmod 600 secrets/discord-webhook-url
```

Without it Alertmanager still starts and delivers to ntfy; the Discord receiver
logs a delivery error. Remove the `discord_configs` block if you do not want it.

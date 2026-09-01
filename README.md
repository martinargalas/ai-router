# ai-router

Route AI coding requests to a local model when it can handle them, and to Claude
when it can't. Track what every developer spends. Stop credentials from leaving
your network.

A Docker Compose stack built on [LiteLLM](https://litellm.ai) and
[Ollama](https://ollama.com).

**On the reference setup it cut cost by 93 % against sending everything to a
frontier model**, while a locally-run classifier got the local-vs-cloud decision
right 96.7 % of the time.

---

## Quick start

```bash
git clone https://github.com/martinargalas/ai-router && cd ai-router
cp .env.example .env
```

Fill in `.env` — the file explains each value and how to generate it. Minimum:
`AI_ROUTER_DIR`, `POSTGRES_PASSWORD`, `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`,
`REDIS_PASSWORD`. `ANTHROPIC_API_KEY` is optional; without it everything runs
locally.

Ports 3000, 4000, 8080 and 9090 must be free — all bound to localhost.

```bash
ollama pull qwen2.5-coder:7b
docker compose --env-file .env up -d

# audit views and eval tables
for f in sql/*-view.sql sql/eval-tables.sql; do
  docker exec -i ai-router-db psql -U litellm -d litellm < "$f"
done
```

Create a key for yourself:

```bash
curl -s localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"key_alias":"alice","user_id":"alice",
       "models":["auto","fast-local","code-local","frontier","frontier-mid","frontier-fast"],
       "max_budget":10,"budget_duration":"30d","rpm_limit":120}'
```

That key goes in your editor. `LITELLM_MASTER_KEY` never does — it is full admin.

### Dashboards

Grafana and Prometheus start with the stack. Two of the dashboards read the
audit tables, which needs one more role:

```bash
PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)
docker exec -i ai-router-db psql -U litellm -d litellm -v pw="$PW" -f - < sql/grafana-readonly-user.sql
echo "GRAFANA_RO_PASSWORD=$PW" >> .env
docker compose --env-file .env up -d ai-router-grafana
```

Grafana on <http://localhost:3000> (`admin` / `GRAFANA_ADMIN_PASSWORD`), three
dashboards already loaded: spend and latency, an audit of everything that left
the network, and classifier quality.

---

## Point your editor at it

Base URL `http://localhost:4000/v1`, your key, and one of these models:

| Use | Model | Backend | Why |
|---|---|---|---|
| Chat, edits | `auto` | classifier picks a tier | most traffic stays local |
| Autocomplete | `fast-local` | Ollama on your host | must be fast; skips the classifier |
| Agents | `frontier-mid` | Sonnet | local models can't call tools reliably |

`frontier-fast` and `frontier` map to Haiku and Opus if you want them directly.
Applications use these aliases, never model names, so swapping a model is one
line in `config/litellm-config.yaml`.

A ready [Continue](https://continue.dev) config is in
`clients/continue-config.example.yaml`. Aider works with `auto` including local
models, because it applies text diffs instead of calling tools.

Claude Code uses the Anthropic API shape — point `ANTHROPIC_BASE_URL` at
`http://localhost:4000` and set `ANTHROPIC_MODEL=frontier-mid`.

---

## Day to day

```bash
sh reports/weekly-report.sh 7   # what you spent and saved
sh sql/blocked-report.sh 7      # what the credential guard caught
sh tests/test-guardrails.sh     # guardrail regression suite (~1s, free)
sh evals/run-classifier-eval.sh # classifier accuracy (free, runs locally)
```

Budget alerts go to ntfy. Alerts also fire when a deployment silently falls
back to another model.

---

## What it does not do

**The credential guard catches accidents, not leaks.** It matches eight patterns
— AWS keys, GitHub and Slack tokens, PEM private keys, Anthropic keys,
`api_key=`, IBAN, national ID. It does not understand sensitive content: an
internal document or a description of non-public architecture goes through.

**Nothing marks a source as confidential.** Routing is by complexity only.

**Prompt text is never stored.** The audit answers who, when, where and how much
— not what. That's deliberate.

**No semantic caching, no knowledge base.** Only exact-match caching runs.

---

[docs/NOTES.md](docs/NOTES.md) has the measurements behind the numbers above,
the Ollama tuning that matters, and a list of LiteLLM features that look
configured but silently do nothing. Worth reading before you change the routing
config.

MIT licensed — see [LICENSE](LICENSE).

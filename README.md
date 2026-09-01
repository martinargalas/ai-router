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

## Why

Most AI coding traffic is simple — completions, small edits, "what does this
function do". Sending all of it to a frontier model is expensive. Sending all of
it to a small local model gives bad answers on the hard questions.

This picks per request. Your editor talks to one endpoint with one key; the
gateway decides where the request actually goes, records what it cost, and blocks
API keys and tokens before they reach a third party.

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

Already running your own Prometheus and Grafana? Delete those two services from
`docker-compose.yml`, point your instance at the gateway using the files in
`prometheus/`, and import the dashboards from `grafana/`.

---

## Point your editor at it

Base URL `http://localhost:4000/v1`, your key, and one of these models:

| Use | Model | Why |
|---|---|---|
| Chat, edits | `auto` | the router picks the tier |
| Autocomplete | `fast-local` | must be fast; skip the classifier |
| Agents (Claude Code, Cline) | `frontier-mid` | local models can't call tools reliably |

A ready [Continue](https://continue.dev) config is in
`clients/continue-config.example.yaml`. Aider works with `auto` including local
models, because it applies text diffs instead of calling tools.

Claude Code uses the Anthropic API shape — point `ANTHROPIC_BASE_URL` at
`http://localhost:4000` and set `ANTHROPIC_MODEL=frontier-mid`.

---

## Models

Applications use aliases, never model names, so swapping a model is a one-line
config change:

| Alias | Backend |
|---|---|
| `auto` | classifier picks one of the tiers below |
| `fast-local`, `code-local` | Ollama on your host |
| `frontier-fast` / `frontier-mid` / `frontier` | Haiku / Sonnet / Opus |

Edit `config/litellm-config.yaml` to point them wherever you like.

---

## Day to day

```bash
sh reports/weekly-report.sh 7   # what you spent and saved
sh sql/blocked-report.sh 7      # what the credential guard caught
sh tests/test-guardrails.sh     # guardrail regression suite (~1s, free)
sh evals/run-classifier-eval.sh # classifier accuracy (free, runs locally)
```

Budget alerts go to ntfy and optionally Discord. Alerts also fire when a
deployment silently falls back to another model.

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

## Notes

[docs/NOTES.md](docs/NOTES.md) has the measurements behind the numbers above,
the Ollama tuning that matters, and a list of LiteLLM features that look
configured but silently do nothing — with the workarounds this stack uses. Worth
reading before you change the routing config.

## License

MIT — see [LICENSE](LICENSE).

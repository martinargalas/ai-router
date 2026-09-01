# ai-router

A self-hosted AI gateway that routes each request between local and frontier
models based on task complexity, enforces per-developer budgets, blocks
credentials from leaving the network, and audits every outbound call.

Built on [LiteLLM](https://litellm.ai) with Ollama for local inference. Runs as a
Docker Compose stack.

**Measured on the reference setup: 93 % cost reduction against sending everything
to a frontier model.**

---

## What it actually does

**Complexity-based routing.** A locally-run classifier scores each request and
picks a tier. Simple questions and routine engineering stay local; architecture
and hard reasoning escalate to Claude. Applications reference stable aliases
(`auto`, `fast-local`, `frontier`), never concrete model names, so swapping a
model is a config change rather than a client change.

**Per-developer cost tracking and budgets.** Each developer gets a virtual key
carrying a budget, rate limits and an allow-list of models. Exceeding the budget
rejects cloud calls while local models keep serving.

**Credential blocking.** A pre-call guardrail blocks eight credential patterns
before a request leaves: AWS access keys, GitHub and Slack tokens, PEM private
keys, Anthropic keys, generic `api_key=` assignments, IBAN, and Czech national ID
numbers.

**Egress audit.** Every outbound call is recorded with who, when, which alias was
requested versus which model actually served it, tokens, cost, source IP and
which guardrails ran. Prompt bodies are deliberately not stored.

**Graceful degradation with visibility.** A provider outage falls back to a local
model instead of erroring — and because a silent downgrade is worse than an
error, cooldowns and fallbacks raise their own alerts.

**Measurement built in.** A 30-case golden set measures classifier accuracy and
writes results to Postgres for trending. A weekly report shows savings against a
frontier-only baseline. A regression suite covers the credential guardrail.

---

## Architecture

```
  IDE / CLI / chat client
          │  OpenAI-compatible API + per-developer virtual key
          ▼
     [ LiteLLM ]  ── Postgres (keys, spend, budgets, audit)
          │        ── Redis    (rate limits, exact-match cache)
          │
          ├── classifier ──▶ local model          (decides the tier, costs nothing)
          ├──────────────▶ Ollama on the host     (SIMPLE, MEDIUM)
          └──────────────▶ Anthropic API          (COMPLEX, REASONING)

     Prometheus ──▶ Alertmanager ──▶ ntfy + Discord
     Grafana    ──▶ 3 dashboards (FinOps, Governance, Evals)
```

Ollama runs **natively on the host**, not in a container — a container has no
access to Metal or CUDA and inference falls back to CPU.

---

## Requirements

- Docker with Compose
- [Ollama](https://ollama.com) on the host, reachable from containers
- An Anthropic API key (optional — everything works local-only without one)
- Optional: an existing Traefik, Prometheus and Grafana; the stack integrates
  with them but does not require them

---

## Quick start

```bash
git clone <this-repo> ai-router && cd ai-router
cp .env.example .env
```

Fill in `.env`:

```bash
AI_ROUTER_DIR=/absolute/path/to/ai-router
POSTGRES_PASSWORD=$(openssl rand -base64 24)
LITELLM_MASTER_KEY=sk-$(openssl rand -hex 24)
LITELLM_SALT_KEY=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -base64 24)
ANTHROPIC_API_KEY=sk-ant-...
OLLAMA_BASE_URL=http://host.docker.internal:11434
```

`LITELLM_SALT_KEY` must never change after the first start — it encrypts stored
credentials, and changing it makes existing virtual keys unreadable. Back it up
next to the database password.

Pull a local model and start:

```bash
ollama pull qwen2.5-coder:7b
docker compose --env-file .env up -d
```

Create a developer key:

```bash
curl -s localhost:4000/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"key_alias":"alice","user_id":"alice",
       "models":["auto","fast-local","code-local","frontier","frontier-mid","frontier-fast"],
       "max_budget":10,"budget_duration":"30d","rpm_limit":120}'
```

Then apply the SQL objects (audit views, eval tables, read-only Grafana role):

```bash
for f in sql/egress-audit-view.sql sql/blocked-audit-view.sql sql/eval-tables.sql; do
  docker exec -i ai-router-db psql -U litellm -d litellm < "$f"
done
```

---

## Ollama tuning

Set these before starting Ollama — the defaults will hurt:

```bash
OLLAMA_KEEP_ALIVE=24h          # default 5m evicts the model and kills TTFT
OLLAMA_MAX_LOADED_MODELS=3
OLLAMA_FLASH_ATTENTION=1
```

**Ollama may keep only one model resident.** On the reference setup (32 GB
Apple M4) loading a 7B evicted a 3B despite `MAX_LOADED_MODELS=3` and
`keep_alive=24h`. A switch cost **2174 ms** — four times the entire autocomplete
latency budget. That is why `fast-local` and `code-local` point at the same
model. If your host holds both, split them.

Measured warm: 3B = TTFT 80-133 ms at 45 tok/s, 7B = TTFT 159-169 ms at 21 tok/s.

---

## Client setup

| Client | Endpoint | Model | Note |
|---|---|---|---|
| Continue — autocomplete | `/v1/completions` | `fast-local` | never `auto`; the classifier adds ~0.69 s |
| Continue — chat, edit | `/v1/chat/completions` | `auto` | router decides |
| Aider | `/v1/chat/completions` | `auto` | the only agentic client that works with local models |
| Claude Code | `/v1/messages` | `frontier-mid` | needs tool calling |
| MCP clients | `/mcp` | — | the gateway proxies and logs tool calls |

**Local models do not do tool calling reliably.** Verified: given a tool
definition, the local model returned `stop_reason: end_turn` and plain text
instead of `tool_use`. Clients built on native tool calling (Claude Code, Cline,
OpenHands) must route to cloud models. Aider and Continue's edit mode are the
exception because they apply text diffs rather than calling tools.

A ready Continue config is in `clients/continue-config.example.yaml`.

---

## Operations

```bash
sh reports/weekly-report.sh 7      # savings, egress, rejections, budgets
sh sql/blocked-report.sh 7         # what the guardrail caught
sh sql/egress-detail.sh 20         # per-call outbound listing
sh tests/test-guardrails.sh        # guardrail regression suite (free, ~1 s)
sh evals/run-classifier-eval.sh    # classifier accuracy (free, local)
```

Grafana dashboards are in `grafana/`. The two Postgres-backed ones need a
read-only datasource:

```bash
PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)
docker exec -i ai-router-db psql -U litellm -d litellm -v pw="$PW" -f - < sql/grafana-readonly-user.sql
echo "GRAFANA_RO_PASSWORD=$PW" >> .env
```

Prometheus is not modified automatically. Add the scrape job and alert rules
yourself — see the headers of `prometheus/ai-router-scrape-job.yml` and
`prometheus/ai-router-rules.yml`.

---

## Things that do not work in LiteLLM (measured, 1.98.0)

These cost hours to discover. The config carries workarounds for all of them.

| Feature | Reality |
|---|---|
| Tag-based routing | Tags never take effect, via request metadata, `litellm_metadata` or key metadata. Distribution stays random. |
| Heuristic complexity scorer | Returns `0.0` even for a proof-of-undecidability prompt, so everything lands in SIMPLE. Use `classifier_type: llm`. |
| `budget_alerts()` | Defined but never called anywhere in the package. Budget alerting is done through Prometheus instead. |
| `soft_budget` | Does not persist on keys or users. |
| `LiteLLM_ErrorLogs` | Table exists with the right schema; nothing writes to it. |
| `LiteLLM_DailyGuardrailMetrics` | Counts only requests that passed. Blocks are invisible there and in the Guardrails Monitor UI. |
| `/guardrails/usage/logs` | Returns zero even with `action=BLOCK`. |
| `context_window_fallbacks` | Never fires against Ollama, which truncates oversized prompts silently instead of erroring. |

Blocked requests **are** written to `LiteLLM_SpendLogs` with `status='failure'`
and the matched pattern in `error_information`. That is what
`sql/blocked-audit-view.sql` reads.

---

## Other measured gotchas

**Adaptive thinking eats `max_tokens`.** Claude 5 models think by default and
thinking tokens count against `max_tokens`. With `max_tokens: 8` the entire
budget went to thinking and `content` came back `None` with
`finish_reason: length`. The config sets sane defaults; do not send small
`max_tokens` from your application.

**Budgets overshoot by roughly 20 %.** Spend is flushed to Postgres in batches,
so requests slip through between crossing the limit and the block taking effect.
Rate limits go through Redis and are exact.

**Fallbacks are silent.** When a deployment is in cooldown the router skips it
with no error in the log and another model answers. `AiRouterDeploymentCooldown`
and `AiRouterSilentFallback` exist because of this.

**`aws_secret_key` is deliberately not in the guardrail.** It matches 40
base64-alphabet characters, which is exactly the shape of a git commit hash — it
blocked `Commit 4f2779ed528c... broke the build`. A pattern that blocks ordinary
developer work is worse than no pattern.

---

## Measured results

| Metric | Value |
|---|---|
| Cost saving vs. frontier-only | 93.0 % |
| Classifier accuracy — local/cloud decision | 96.7 % |
| Classifier accuracy — overall, 4 tiers | 90.0 % |
| Guardrail regression suite | 15/15, zero false positives |
| Gateway overhead | under the 50 ms target |

Classifier accuracy was measured with a 7B model. A 3B model scored 70 % overall
but still 93.3 % on the local/cloud boundary — the decision that actually costs
money. Overall accuracy is the misleading number: confusing two cloud tiers is
not the same failure as sending a hard question to a small local model.

---

## Limitations

**The guardrail protects against accidents, not leaks.** It matches credential
patterns. It does not classify sensitive content in general — an internal
document, a client name or a description of non-public architecture passes
through. LiteLLM ships a Presidio guardrail for real PII detection; it is not
deployed here.

**There is no "this source is confidential" enforcement.** Routing is by
complexity alone, regardless of where the content came from.

**Prompt contents are not auditable.** Storage is off by design, so the audit
answers who, when, where and how much — not what.

**Semantic caching is not enabled.** Only exact-match caching runs. Caching in
LiteLLM is global and cannot be scoped per model, and semantic similarity on code
would return answers about different code.

**No knowledge base.** RAG over documentation and tickets was scoped but not
built.

---

## License

MIT — see [LICENSE](LICENSE).

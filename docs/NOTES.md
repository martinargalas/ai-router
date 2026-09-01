# Implementation notes

Measurements and gotchas behind the numbers in the README. Read this before
changing the routing config or swapping models.

---

## Measured results

| Metric | Value |
|---|---|
| Cost saving vs. frontier-only | 93.0 % |
| Classifier accuracy — local/cloud decision | 96.7 % |
| Classifier accuracy — overall, 4 tiers | 90.0 % |
| Guardrail regression suite | 15/15, zero false positives |

Reference setup: Apple M4, 32 GB, `qwen2.5-coder:7b` locally, Claude for the
cloud tiers.

**Overall accuracy is the misleading number.** Confusing two cloud tiers is not
the same failure as sending a hard question to a small local model. A 3B
classifier scored only 70 % overall but still 93.3 % on the local/cloud boundary
— the decision that actually costs money. `evals/run-classifier-eval.sh` reports
both, and the Evals dashboard trends them separately.

Where the 7B classifier earns its keep is the top tier: a 3B model picked
REASONING once out of six, so the most expensive model was effectively never
reachable through `auto`. With 7B it picks it five times out of six.

---

## Ollama tuning

Set these before starting Ollama — the defaults will hurt:

```bash
OLLAMA_KEEP_ALIVE=24h          # default 5m evicts the model and destroys TTFT
OLLAMA_MAX_LOADED_MODELS=3
OLLAMA_FLASH_ATTENTION=1
```

**Ollama may keep only one model resident, whatever you set.** On the reference
setup, loading a 7B evicted a 3B despite `MAX_LOADED_MODELS=3` and
`keep_alive=24h`. A switch cost **2174 ms** — four times the entire autocomplete
latency budget.

That is why `fast-local` and `code-local` point at the same model here. If your
host holds both, split them and you get the faster small model back for
completions.

Measured warm:

| | TTFT | Throughput |
|---|---|---|
| 3B | 80–133 ms | 45 tok/s |
| 7B | 159–169 ms | 21 tok/s |

Both meet a 500 ms TTFT budget. The 2.2 s reload does not.

---

## Local models and tool calling

Given a tool definition, the local model returned `stop_reason: end_turn` with
plain text instead of `tool_use`. Anything built on native tool calling — Claude
Code, Cline, OpenHands — must route to cloud models.

Aider and Continue's edit mode are the exception: they apply text diffs rather
than calling tools, so local models work with them.

If an agentic client is pointed at `auto` and lands on a local tier, it does not
error. It degenerates — Continue's agent mode echoed the question back token by
token wrapped in `<assistant>` tags. Use `frontier-mid` for agents, or the
`auto-agentic` alias, which routes by complexity but only between cloud models.

---

## Claude 5 thinking eats max_tokens

Claude 5 models think by default and thinking tokens count against `max_tokens`.
With `max_tokens: 8` the entire budget went to thinking: `content` came back
`None` with `finish_reason: length`.

The config sets sane defaults for when a client sends none, but a client-supplied
value wins. Do not send small `max_tokens` to cloud models from your application.

---

## Budgets overshoot by about 20 %

Spend is flushed to Postgres in batches, so requests slip through between
crossing the limit and the block taking effect. Measured: a key with a $0.00002
budget stopped at $0.000024.

Rate limits go through Redis and are exact.

---

## LiteLLM features that do not work

Measured on 1.98.0. Each cost hours to discover; the config carries workarounds.

| Feature | Reality |
|---|---|
| Tag-based routing | Tags never take effect — via request metadata, `litellm_metadata`, or key metadata. Distribution stays random. |
| Heuristic complexity scorer | Returns `0.0` even for a proof-of-undecidability prompt, so everything lands in SIMPLE. Use `classifier_type: llm`. |
| `budget_alerts()` | Defined but never called anywhere in the package. Budget alerting goes through Prometheus instead. |
| `soft_budget` | Does not persist on keys or users. |
| `LiteLLM_ErrorLogs` | Table exists with the right schema; nothing writes to it. |
| `LiteLLM_DailyGuardrailMetrics` | Counts only requests that passed. Blocks are invisible there and in the Guardrails Monitor UI. |
| `/guardrails/usage/logs` | Returns zero even with `action=BLOCK`. |
| `context_window_fallbacks` | Never fires against Ollama, which truncates oversized prompts silently instead of erroring. |

Blocked requests **are** written to `LiteLLM_SpendLogs` with `status='failure'`
and the matched pattern in `error_information`. That is what
`sql/blocked-audit-view.sql` reads, and why `sh sql/blocked-report.sh` shows
catches the built-in UI does not.

---

## Fallbacks are silent

When a deployment is in cooldown the router skips it with no error in the log and
another model answers. An escalation to Sonnet once fell back to a local model
and only the `routing_decision` field in the audit revealed it.

`AiRouterDeploymentCooldown` and `AiRouterSilentFallback` exist because of this.
Keep them.

---

## Why aws_secret_key is not in the guardrail

It matches 40 base64-alphabet characters — exactly the shape of a git commit
hash. It blocked `Commit 4f2779ed528c... broke the build`.

A pattern that blocks ordinary developer work is worse than no pattern.
`aws_access_key` (the `AKIA` prefix) is unambiguous, and in a real leak the
secret key usually travels next to its access key id anyway.

Email addresses and IP addresses are not blocked either — they appear
legitimately in logs, configs and fixtures.

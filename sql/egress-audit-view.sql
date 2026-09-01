-- Egress audit view.
--
-- Answers "what data went where, and why" for every call that leaves the local
-- network. Built on LiteLLM_SpendLogs, which already collects most of it.
--
-- Apply after a fresh start or a database restore:
--   docker exec -i ai-router-db psql -U litellm -d litellm < sql/egress-audit-view.sql
--
-- NOTE: prompt_stored is always false by design. store_prompts_in_spend_logs is
-- off, so prompt bodies are never persisted. The audit answers WHO, WHEN, WHERE
-- and HOW MUCH — not WHAT. Storing prompts would create a second copy of
-- sensitive data in exactly the place you do not want it.

DROP VIEW IF EXISTS ai_router_egress_audit;
CREATE VIEW ai_router_egress_audit AS
SELECT
    s."startTime"                                    AS ts,
    s.request_id,
    s.custom_llm_provider                            AS provider,
    s.model                                          AS served_by,
    -- model_group is empty on escalated calls; recover it from metadata.
    COALESCE(NULLIF(s.model_group, ''),
             s.metadata->'routing_decision'->>'router_model_name') AS requested_alias,
    COALESCE(NULLIF(s."user", ''),
             s.metadata->>'user_api_key_user_id')     AS user_name,
    -- Silent substitution check: what the router picked vs what actually served.
    (s.metadata->'routing_decision'->>'routed_model') AS router_chose,
    s.metadata->'routing_decision'->>'tier'           AS tier,
    s.metadata->>'user_api_key_alias'                AS key_alias,
    s.metadata->>'user_api_key'                      AS key_hash,
    COALESCE(NULLIF(s.requester_ip_address,''),
             s.metadata->>'requester_ip_address')     AS source_ip,
    s.prompt_tokens, s.completion_tokens, s.total_tokens,
    round(s.spend::numeric, 8)                       AS cost_usd,
    s.status,
    s.request_duration_ms,
    s.metadata->'applied_guardrails'                 AS guardrails,
    s.metadata->'guardrail_information'              AS guardrail_detail,
    s.metadata->'routing_decision'                   AS routing_decision_raw,
    (s.messages::text <> '{}' AND s.messages IS NOT NULL) AS prompt_stored
FROM "LiteLLM_SpendLogs" s
-- Egress = anything not served locally. Filtering by exclusion means a newly
-- added cloud provider shows up in the audit without touching this view.
WHERE s.custom_llm_provider IS NOT NULL
  AND s.custom_llm_provider NOT IN ('ollama', 'ollama_chat', '')
ORDER BY s."startTime" DESC;

COMMENT ON VIEW ai_router_egress_audit IS
  'Calls leaving the local network. Prompt bodies are deliberately not stored.';

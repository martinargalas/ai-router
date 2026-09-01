-- Blocked request audit view.
--
-- Blocked requests DO get written to LiteLLM_SpendLogs with status='failure' and
-- full detail in metadata->error_information->error_message.
--
-- They are NOT counted by LiteLLM_DailyGuardrailMetrics, which only tracks what
-- passed — verified: 26 evaluated, 26 passed, 0 blocked, while dozens of blocks
-- had happened. The Guardrails Monitor page in the LiteLLM UI is therefore
-- misleading for security purposes. /guardrails/usage/logs returns zero even
-- with action=BLOCK. This view is the working alternative.
--
-- Apply:
--   docker exec -i ai-router-db psql -U litellm -d litellm < sql/blocked-audit-view.sql

DROP VIEW IF EXISTS ai_router_blocked_audit;
CREATE VIEW ai_router_blocked_audit AS
SELECT
    s."startTime"                                      AS ts,
    s.request_id,
    s.metadata->>'user_api_key_alias'                  AS key_alias,
    COALESCE(NULLIF(s."user",''),
             s.metadata->>'user_api_key_user_id')      AS user_name,
    s.model_group                                      AS requested,
    -- Pulled out of error_message: "... 'pattern': 'aws_access_key' ..."
    substring(s.metadata->'error_information'->>'error_message'
              from '''pattern'': ''([a-z_]+)''')       AS pattern,
    substring(s.metadata->'error_information'->>'error_message'
              from '''guardrail_name'': ''([a-z_-]+)''') AS guardrail,
    substring(s.metadata->'error_information'->>'error_message'
              from '''guardrail_mode'': ''([a-z_]+)''')  AS stage,
    -- Rejection category. Without it, credential detections get mixed up with
    -- budget and rate-limit rejections in one listing, which is confusing.
    CASE
      WHEN s.metadata->'error_information'->>'error_message' LIKE '%Content blocked%'
        THEN 'guardrail'
      WHEN s.metadata->'error_information'->>'error_class' = 'BudgetExceededError'
        THEN 'budget'
      WHEN s.metadata->'error_information'->>'error_class' = 'ProxyRateLimitError'
        THEN 'rate limit'
      WHEN s.metadata->'error_information'->>'error_message' LIKE '%not allowed to access model%'
        THEN 'model not allowed'
      ELSE 'other'
    END                                                AS reason,
    s.metadata->'error_information'->>'error_class'    AS error_class_name,
    s.metadata->'error_information'->>'error_code'     AS code,
    COALESCE(NULLIF(s.requester_ip_address,''),
             s.metadata->>'requester_ip_address')      AS source_ip
FROM "LiteLLM_SpendLogs" s
WHERE s.status = 'failure'
ORDER BY s."startTime" DESC;

COMMENT ON VIEW ai_router_blocked_audit IS
  'Rejected requests including the pattern that matched. Not visible in the LiteLLM Guardrails Monitor.';

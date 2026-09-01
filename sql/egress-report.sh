#!/bin/sh
# Outbound traffic summary for a period.  sh sql/egress-report.sh [days]
DAYS="${1:-7}"
docker exec ai-router-db psql -U litellm -d litellm -c "
SELECT provider, key_alias, user_name, count(*) AS calls,
       sum(total_tokens) AS tokens, round(sum(cost_usd),6) AS usd,
       bool_or(prompt_stored) AS prompt_stored
FROM ai_router_egress_audit
WHERE ts > now() - interval '$DAYS days'
GROUP BY 1,2,3 ORDER BY 6 DESC NULLS LAST;"

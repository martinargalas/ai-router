#!/bin/sh
# Summary of rejected requests.  sh sql/blocked-report.sh [days]
DAYS="${1:-7}"
echo "--- by rejection reason ---"
docker exec ai-router-db psql -U litellm -d litellm -c "
SELECT reason, count(*) AS count, count(DISTINCT key_alias) AS keys,
       to_char(max(ts),'DD.MM HH24:MI') AS last_seen
FROM ai_router_blocked_audit WHERE ts > now() - interval '$DAYS days'
GROUP BY 1 ORDER BY 2 DESC;"
echo "--- credential detections by pattern ---"
docker exec ai-router-db psql -U litellm -d litellm -c "
SELECT COALESCE(pattern,'(neznamy)') AS pattern, COALESCE(guardrail,'-') AS guardrail,
       COALESCE(key_alias,'-') AS key, count(*) AS blocks,
       to_char(max(ts),'DD.MM HH24:MI') AS last_seen
FROM ai_router_blocked_audit
WHERE ts > now() - interval '$DAYS days' AND reason='guardrail'
GROUP BY 1,2,3 ORDER BY 4 DESC;"
echo "--- most recent rejections ---"
docker exec ai-router-db psql -U litellm -d litellm -c "
SELECT to_char(ts,'DD.MM HH24:MI:SS') AS ts, key_alias AS key,
       reason, COALESCE(pattern,'-') AS pattern, code
FROM ai_router_blocked_audit WHERE ts > now() - interval '$DAYS days' LIMIT 10;"

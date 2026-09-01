#!/bin/sh
# Detailed listing of outbound calls.  sh sql/egress-detail.sh [pocet]
N="${1:-20}"
docker exec ai-router-db psql -U litellm -d litellm -c "
SELECT to_char(ts,'DD.MM HH24:MI:SS')      AS ts,
       key_alias                            AS key,
       user_name,
       requested_alias                      AS requested,
       COALESCE(router_chose,'-')           AS router_chose,
       COALESCE(tier,'-')                    AS tier,
       served_by                        AS obslouzil,
       total_tokens                          AS tok,
       cost_usd,
       COALESCE(guardrails::text,'-')        AS guardrails,
       status
FROM ai_router_egress_audit LIMIT $N;"

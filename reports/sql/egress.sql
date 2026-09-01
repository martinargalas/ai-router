SELECT '  ' || rpad(klic,18) || rpad(model,24) || lpad(n::text,5) || ' volani  '
       || lpad(tok::text,8) || ' tok  ' || to_char(usd,'FM0.000000') AS r
FROM (SELECT COALESCE(key_alias,'-') AS key, served_by AS model,
             count(*) AS n, sum(total_tokens) AS tok, sum(cost_usd) AS usd
      FROM ai_router_egress_audit
      WHERE ts > now() - (:'dny' || ' days')::interval
      GROUP BY 1,2) t
ORDER BY usd DESC NULLS LAST;

SELECT '  ' || rpad(reason,16) || lpad(n::text,5) || '  (keys: ' || klicu || ')' AS r
FROM (SELECT reason, count(*) AS n, count(DISTINCT key_alias) AS keys
      FROM ai_router_blocked_audit
      WHERE ts > now() - (:'dny' || ' days')::interval
      GROUP BY 1) t
ORDER BY n DESC;

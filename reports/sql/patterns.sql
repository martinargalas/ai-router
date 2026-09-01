SELECT '  ' || rpad(pattern,20) || lpad(n::text,4) || 'x' AS r
FROM (SELECT pattern, count(*) AS n FROM ai_router_blocked_audit
      WHERE ts > now() - (:'dny' || ' days')::interval
        AND reason='guardrail' AND pattern IS NOT NULL
      GROUP BY 1) t
ORDER BY n DESC LIMIT 5;

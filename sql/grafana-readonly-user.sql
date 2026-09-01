-- Read-only role for Grafana.
-- Grafana NEDOSTANE heslo od uzivatele litellm - vidi jen dve audit view,
-- and the eval tables, nothing else, and cannot write.
--
-- Apply after a database restore:
--   PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 24)
--   docker exec -i ai-router-db psql -U litellm -d litellm -v pw="$PW" \
--     -f - < sql/grafana-readonly-user.sql
--   echo "GRAFANA_RO_PASSWORD=$PW" >> .env

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='grafana_ro') THEN
    CREATE ROLE grafana_ro LOGIN PASSWORD :'pw';
  ELSE
    ALTER ROLE grafana_ro LOGIN PASSWORD :'pw';
  END IF;
END
$$;

REVOKE ALL ON SCHEMA public FROM grafana_ro;
GRANT CONNECT ON DATABASE litellm TO grafana_ro;
GRANT USAGE ON SCHEMA public TO grafana_ro;
-- Only the audit views and eval tables.
GRANT SELECT ON ai_router_egress_audit  TO grafana_ro;
GRANT SELECT ON ai_router_blocked_audit TO grafana_ro;

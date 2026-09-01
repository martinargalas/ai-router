-- Tables for classifier eval results.
-- Not part of the LiteLLM schema — hence the ai_router_ prefix.
--
-- Apply after a database restore:
--   docker exec -i ai-router-db psql -U litellm -d litellm < sql/eval-tables.sql

CREATE TABLE IF NOT EXISTS ai_router_eval_runs (
    id                serial PRIMARY KEY,
    ts               timestamptz NOT NULL DEFAULT now(),
    suite              text        NOT NULL DEFAULT 'classifier',
    classifier_model  text,
    rubric           text,
    total            int  NOT NULL,
    correct           int  NOT NULL,
    accuracy          numeric(5,4) NOT NULL,
    over_escalated       int  NOT NULL DEFAULT 0,
    under_escalated       int  NOT NULL DEFAULT 0,
    -- Accuracy on the local/cloud decision specifically. Overall accuracy is
    -- misleading: confusing two cloud tiers is not the same failure as sending
    -- a hard question to a small local model.
    boundary_accuracy  numeric(5,4),
    boundary_over    int DEFAULT 0,
    boundary_under      int DEFAULT 0,
    note          text
);

CREATE TABLE IF NOT EXISTS ai_router_eval_cases (
    id        bigserial PRIMARY KEY,
    run_id    int  NOT NULL REFERENCES ai_router_eval_runs(id) ON DELETE CASCADE,
    prompt    text NOT NULL,
    expected text NOT NULL,
    got    text,
    cause     text,
    correct   boolean GENERATED ALWAYS AS (got = expected) STORED
);
CREATE INDEX IF NOT EXISTS ix_eval_cases_run ON ai_router_eval_cases(run_id);

-- Grafana reads through the read-only role only.
GRANT SELECT ON ai_router_eval_runs, ai_router_eval_cases TO grafana_ro;

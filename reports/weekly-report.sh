#!/bin/sh
# Weekly ai-router report.  sh reports/weekly-report.sh [days]
#
# All data comes from LiteLLM endpoints or the audit views — no model
# calls, so the report costs nothing.

DAYS="${1:-7}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="${LITELLM_MASTER_KEY:-$(grep '^LITELLM_MASTER_KEY=' "$DIR/.env" | cut -d= -f2)}"
URL="${AI_ROUTER_URL:-http://localhost:4000}"
S=$(date -u -v-${DAYS}d +%Y-%m-%d 2>/dev/null || date -u -d "$DAYS days ago" +%Y-%m-%d)
E=$(date -u -v+1d +%Y-%m-%d 2>/dev/null || date -u -d 'tomorrow' +%Y-%m-%d)


# SQL lives in separate files to avoid nested-quoting hell.
psql_file() {
  docker exec -i ai-router-db psql -U litellm -d litellm -t -A \
    -v days="$DAYS" -f - < "$1" 2>&1 | grep -v '^$' | grep -viE 'error|line [0-9]'
}

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  ai-router — report — last $DAYS days ($S .. $E)"
echo "╚════════════════════════════════════════════════════════════╝"

echo
echo "── ROUTING SAVINGS ─────────────────────────────────────────"
curl -sL -m 25 "$URL/auto_router/benchmarks?start_date=$S&end_date=$E" -H "Authorization: Bearer $MASTER" \
 | python3 -c '
import sys,json
d=json.loads(sys.stdin.read(),strict=False)
t=d.get("totals") or {}
if not t: print("  zadna data"); raise SystemExit
print("  sessions:        %d  (turns %d)" % (t.get("sessions",0), t.get("turns",0)))
print("  actual:          $%.6f" % t.get("spend",0))
print("  baseline:        $%.6f   (everything on the frontier model)" % t.get("baseline_spend",0))
print("  saved:           $%.6f   = %.1f %%" % (t.get("saved_spend",0), t.get("saved_pct",0)))
c=t.get("cache") or {}
print("  cache hit rate:  %.1f %%" % c.get("hit_rate_pct",0))'

echo
echo "── CLOUD EGRESS ────────────────────────────────────────"
psql_file "$DIR/reports/sql/egress.sql"

echo
echo "── REJECTIONS ───────────────────────────────────────────────"
psql_file "$DIR/reports/sql/blocked.sql"

echo
echo "── TOP CREDENTIAL CATCHES ─────────────────────────"
psql_file "$DIR/reports/sql/patterns.sql"

echo
echo "── BUDGETS ────────────────────────────────────────────────"
curl -sL -m 20 "$URL/key/list?return_full_object=true" -H "Authorization: Bearer $MASTER" \
 | python3 -c '
import sys,json
d=json.loads(sys.stdin.read(),strict=False); ks=d.get("keys",d)
for k in ks:
    if not isinstance(k,dict): continue
    mb=k.get("max_budget"); sp=k.get("spend") or 0
    if mb: print("  %-18s $%.6f / $%-8s  (%.1f %%)" % (k.get("key_alias"), sp, mb, 100*sp/mb))
    else:  print("  %-18s $%.6f / bez limitu" % (k.get("key_alias"), sp))'
echo

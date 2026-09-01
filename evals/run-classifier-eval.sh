#!/bin/sh
# Complexity classifier eval.
#   sh evals/run-classifier-eval.sh
#
# Uses /auto_router/test_routing — a dry run that does NOT call the target model.
# The classifier runs locally, so the whole eval is effectively free.
#
# Results are written to evals/results/ and to Postgres for trending.

DIR="$(cd "$(dirname "$0")/.." && pwd)"
# First argument = classifier alias (default fast-local).
#   sh evals/run-classifier-eval.sh code-local
CLASSIFIER="${1:-fast-local}"
MASTER="${LITELLM_MASTER_KEY:-$(grep '^LITELLM_MASTER_KEY=' "$DIR/.env" | cut -d= -f2)}"
URL="${AI_ROUTER_URL:-http://localhost:4000}"
mkdir -p "$DIR/evals/results"
OUT="$DIR/evals/results/$(date +%Y%m%d-%H%M%S).json"

MASTER="$MASTER" URL="$URL" OUT="$OUT" CLASSIFIER="$CLASSIFIER" python3 - "$DIR/evals/classifier-goldenset.json" <<'PYEOF'
import json,os,sys,subprocess,collections,datetime

gs=json.load(open(sys.argv[1]))["cases"]
MASTER=os.environ["MASTER"]; URL=os.environ["URL"]; OUT=os.environ["OUT"]
CLS=os.environ.get("CLASSIFIER","fast-local")

CFG={"tiers":{"SIMPLE":"fast-local","MEDIUM":"fast-local",
              "COMPLEX":"frontier-mid","REASONING":"frontier"},
     "classifier_type":"llm",
     "classifier_llm_config":{"model":CLS,"timeout_ms":30000,
                              "classification_rubric":"agentic"},
     "default_model":"fast-local"}

TIERS=["SIMPLE","MEDIUM","COMPLEX","REASONING"]
RANK={t:i for i,t in enumerate(TIERS)}

import time
rows=[]; lat=[]
for i,c in enumerate(gs,1):
    body=json.dumps({"prompt":c["prompt"],"complexity_router_config":CFG})
    t0=time.time()
    r=subprocess.run(["curl","-sL","-m","90",URL+"/auto_router/test_routing",
        "-H","Authorization: Bearer "+MASTER,"-H","Content-Type: application/json",
        "--data-binary",body],capture_output=True,text=True)
    try:
        d=json.loads(r.stdout)
        got=(d.get("routing_decision") or {}).get("tier")
        cause=(d.get("routing_decision") or {}).get("cause")
    except Exception:
        got=None; cause="parse_fail"
    lat.append(time.time()-t0)
    rows.append({"prompt":c["prompt"],"expected":c["expected"],"got":got,"cause":cause})
    sys.stderr.write("\r  klasifikovano %d/%d" % (i,len(gs))); sys.stderr.flush()
sys.stderr.write("\n")

ok=sum(1 for r in rows if r["got"]==r["expected"])
n=len(rows)
print()
lat_s=sorted(lat)
print("  CLASSIFIER: %s" % CLS)
print("  ACCURACY: %d/%d = %.1f %%" % (ok,n,100*ok/n))
print("  LATENCY:  median %.2f s   p95 %.2f s" % (lat_s[len(lat_s)//2], lat_s[int(len(lat_s)*0.95)-1]))

# per-tier
print()
print("  By tier:")
for t in TIERS:
    sub=[r for r in rows if r["expected"]==t]
    if sub:
        h=sum(1 for r in sub if r["got"]==t)
        print("    %-10s %d/%d  (%.0f %%)" % (t,h,len(sub),100*h/len(sub)))

# matice zamen
print()
print("  Confusion matrix (row = expected, column = classified as):")
print("             " + "".join("%-11s"%t[:9] for t in TIERS))
for e in TIERS:
    line="    %-9s"%e
    for g in TIERS:
        c=sum(1 for r in rows if r["expected"]==e and r["got"]==g)
        line += "%-11s" % (c if c else ".")
    print(line)

# dopad chyb
over=[r for r in rows if r["got"] and RANK[r["got"]]>RANK[r["expected"]]]
under=[r for r in rows if r["got"] and RANK[r["got"]]<RANK[r["expected"]]]
# --- local/cloud boundary accuracy ---
# This is the number that costs money. Overall accuracy is misleading:
# confusing two cloud tiers is not the same failure as
# sending a hard question to a small local model.
LOCAL_TIERS = {"SIMPLE","MEDIUM"}
def side(t): return "local" if t in LOCAL_TIERS else "cloud"
bnd = [(side(r["expected"]), side(r["got"])) for r in rows if r["got"]]
bok = sum(1 for a,b in bnd if a==b)
over_b  = sum(1 for a,b in bnd if a=="local" and b=="cloud")
under_b = sum(1 for a,b in bnd if a=="cloud" and b=="local")
print()
print("  LOCAL/CLOUD BOUNDARY (the decision that costs money):")
print("    accuracy:            %d/%d = %.1f %%" % (bok,len(bnd),100*bok/len(bnd)))
print("    local -> cloud:      %2d   paid unnecessarily" % over_b)
print("    cloud -> local:      %2d   hard question sent to a small model" % under_b)

print()
print("  Error impact (within and across the boundary):")
print("    over-escalated:  %2d  -> unnecessarily expensive calls" % len(over))
print("    under-escalated: %2d  -> worse answers, user cannot tell" % len(under))

if over or under:
    print()
    print("  Misclassifications:")
    for r in over+under:
        sign="^" if r in over else "v"
        print("    %s %-9s -> %-9s  %s" % (sign,r["expected"],r["got"],r["prompt"][:58]))

json.dump({"ts":datetime.datetime.now().isoformat(),"accuracy":ok/n,
           "total":n,"correct":ok,"over_escalated":len(over),"under_escalated":len(under),
           "vysledky":rows}, open(OUT,"w"), ensure_ascii=False, indent=1)

# --- write to Postgres so it can be trended in Grafana ---
def q(v):
    if v is None: return "NULL"
    return "'" + str(v).replace("'","''") + "'"

cm = CFG["classifier_llm_config"]["model"]
rub = CFG["classifier_llm_config"].get("classification_rubric")
sql = ["INSERT INTO ai_router_eval_runs (suite,classifier_model,rubric,total,correct,accuracy,over_escalated,under_escalated,boundary_accuracy,boundary_over,boundary_under) VALUES ('classifier',%s,%s,%d,%d,%.4f,%d,%d,%.4f,%d,%d) RETURNING id;" % (q(cm),q(rub),n,ok,ok/n,len(over),len(under),bok/len(bnd),over_b,under_b)]
res = subprocess.run(["docker","exec","-i","ai-router-db","psql","-U","litellm","-d","litellm","-t","-A","-c",sql[0]],
                     capture_output=True,text=True)
run_id = res.stdout.strip().splitlines()[0] if res.stdout.strip() else None
if run_id and run_id.isdigit():
    vals = ",".join("(%s,%s,%s,%s,%s)" % (run_id,q(r["prompt"]),q(r["expected"]),q(r["got"]),q(r["cause"])) for r in rows)
    subprocess.run(["docker","exec","-i","ai-router-db","psql","-U","litellm","-d","litellm","-q","-c",
        "INSERT INTO ai_router_eval_cases (run_id,prompt,expected,got,cause) VALUES " + vals + ";"],
        capture_output=True,text=True)
    print()
    print("  saved: %s" % OUT)
    print("  stored as run #%s (Grafana: Evals dashboard)" % run_id)
else:
    print()
    print("  saved: %s" % OUT)
    print("  DB WRITE FAILED: %s" % (res.stderr or res.stdout)[:150])
PYEOF

#!/bin/sh
# Regression test for credential detection.
# Run after EVERY guardrail config change:  sh tests/test-guardrails.sh
#
# Uses /guardrails/apply_guardrail, which evaluates text WITHOUT calling a model.
# That makes the test free, fast, and it names the pattern that matched.
#
# False positives matter as much as catches: a guardrail that blocks
# git commit hashes is unusable for a coding assistant.

MASTER="${LITELLM_MASTER_KEY:-$(grep '^LITELLM_MASTER_KEY=' .env 2>/dev/null | cut -d= -f2)}"
URL="${AI_ROUTER_URL:-http://localhost:4000}"
[ -z "$MASTER" ] && { echo "chybi LITELLM_MASTER_KEY nebo .env"; exit 1; }

PASS=0; FAIL=0
t() {
  DESC="$1"; TXT="$2"; EXPECT="$3"
  python3 -c "
import json,sys
print(json.dumps({'guardrail_name':'secret-scan','text':sys.argv[1]}))" "$TXT" > /tmp/gt.json
  curl -sL -m 30 -o /tmp/gtr.json "$URL/guardrails/apply_guardrail" \
    -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' --data-binary @/tmp/gt.json
  RES=$(python3 -c '
import json,re
d=json.loads(open("/tmp/gtr.json").read(), strict=False)
msg=str(d.get("error",{}).get("message","")) if d.get("error") else ""
if msg:
    m=re.search(r"Content blocked: ([a-z_]+) pattern", msg) or re.search(r"'"'"'pattern'"'"':\s*'"'"'([a-z_]+)'"'"'", msg)
    print("BLOK|"+(m.group(1) if m else "?"))
else:
    print("PROSLO|-")' 2>/dev/null || echo "PARSE_FAIL|-")
  GOT="${RES%%|*}"; PAT="${RES##*|}"
  if [ "$GOT" = "$EXPECT" ]; then PASS=$((PASS+1)); M="OK "; else FAIL=$((FAIL+1)); M="!! "; fi
  printf "  %s%-28s -> %-7s %-18s (cekano %s)\n" "$M" "$DESC" "$GOT" "$PAT" "$EXPECT"
}

# Test fixtures are assembled at runtime, not written as literals. Otherwise
# GitHub's push protection flags this file as containing real secrets — which it
# does not. None of these are valid credentials.
#
# ghp_ + EXACTLY 36 chars. The github_token pattern requires the exact length;
# any other count silently passes and the test would report a false failure.
GH="ghp_$(printf '0123456789abcdefghijklmnopqrstuvwxyz')"
[ "${#GH}" -eq 40 ] || { echo "TEST BUG: GH is ${#GH} chars, must be 40"; exit 1; }
SLACK="xox""b-1234567890-1234567890-$(printf 'abcdefghijklmnopqrstuvwx')"
ANTHRO="sk-""ant-api03-$(printf 'abcdefghijklmnopqrstuvwxyz012345')"
AWSKEY="AKIA""IOSFODNN7EXAMPLE"

echo "=== SHOULD block ==="
t "AWS access key"  "Debug: AWS_ACCESS_KEY_ID=$AWSKEY"                          "BLOK"
t "GitHub token"    "Why fails? $GH"                                            "BLOK"
t "Slack token"     "token $SLACK"                                              "BLOK"
t "generic api key" "config has api_key=abcdefghij0123456789XYZ"                "BLOK"
t "private key"   "Fix: -----BEGIN RSA PRIVATE KEY-----MIIEowIBAAKCAQEA"      "BLOK"
t "Anthropic key"   "key $ANTHRO"                                               "BLOK"
t "IBAN"            "Payment to CZ6508000000192000145399"                       "BLOK"
t "national ID"     "Zakaznik ma national ID 850615/1234"                       "BLOK"

echo "=== MUST NOT block (false positives) ==="
t "ordinary code"       "Write a Python function that reverses a string"            "PROSLO"
t "mentions a key, no value"  "How do I store an API key securely in env vars?"           "PROSLO"
t "email"           "Parse log: user=jan@example.com status=200"                "PROSLO"
t "IP address"       "Why is 192.168.1.50 unreachable?"                          "PROSLO"
t "git commit hash" "Commit 4f2779ed528c1276460f678d2334597d5f0f37b0 broke it"  "PROSLO"
t "sha256"          "Checksum a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9 mismatch" "PROSLO"
t "UUID"            "Request id 4f2779ed-528c-1276-4604-f678d2334597 failed"    "PROSLO"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1

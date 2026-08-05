#!/usr/bin/env bash
# Non-interactive E2E smoke test (capstone-requirements.md §6.1). Purely
# read-only against a running cluster -- safe to run repeatedly, never
# creates/deletes/patches anything.
#
# Every check is wrapped in its own `if`, so one failing check never aborts
# the run early (a condition tested by `if` doesn't trigger `set -e`) -- this
# script always evaluates every check and prints one PASS/FAIL line for each,
# then a summary count. The exit code is non-zero if ANY check failed, so it
# still composes as a fail-fast gate in CI/a Makefile target even though the
# run itself doesn't stop at the first failure.
#
# Reaches every service the same way a real client would: the Ingress for
# frontend/rider, and `kubectl exec` into an already-running Pod for
# everything else (each app Pod's own `ambassador` sidecar for /healthz,
# postgres-0 for psql, the redis Pod for redis-cli) -- no extra tooling
# needed on the host beyond curl and kubectl.
#
# Usage: scripts/smoke-test.sh
# Env overrides: NS (default veloshare), BASE_URL (default http://localhost)
set -euo pipefail

NS="${NS:-veloshare}"
BASE_URL="${BASE_URL:-http://localhost}"

TOTAL=0
FAILED=0

pass() { TOTAL=$((TOTAL + 1)); printf 'PASS  %s\n' "$1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; }

# Strips all whitespace so `{"status": "ok"}` and `{"status":"ok"}` compare equal.
normalize() { printf '%s' "$1" | tr -d '[:space:]'; }

for bin in kubectl curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' not found in PATH" >&2; exit 1; }
done
if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo "error: namespace '$NS' not found -- run 'make up' (or 'make deploy') first." >&2
  exit 1
fi

echo "== Deployments Ready =="
for d in $(kubectl -n "$NS" get deploy -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  desired=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.spec.replicas}')
  ready=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas}')
  ready="${ready:-0}"
  if [ -n "$desired" ] && [ "$desired" -gt 0 ] && [ "$ready" = "$desired" ]; then
    pass "deployment/$d ready ($ready/$desired)"
  else
    fail "deployment/$d ready ($ready/$desired)"
  fi
done

echo
echo "== StatefulSets Ready =="
for s in $(kubectl -n "$NS" get statefulset -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  desired=$(kubectl -n "$NS" get statefulset "$s" -o jsonpath='{.spec.replicas}')
  ready=$(kubectl -n "$NS" get statefulset "$s" -o jsonpath='{.status.readyReplicas}')
  ready="${ready:-0}"
  if [ -n "$desired" ] && [ "$desired" -gt 0 ] && [ "$ready" = "$desired" ]; then
    pass "statefulset/$s ready ($ready/$desired)"
  else
    fail "statefulset/$s ready ($ready/$desired)"
  fi
done

echo
echo "== Services have Endpoints =="
for svc in $(kubectl -n "$NS" get svc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true); do
  subsets=$(kubectl -n "$NS" get endpoints "$svc" -o jsonpath='{.subsets}' 2>/dev/null || true)
  if [ -n "$subsets" ] && [ "$subsets" != "[]" ]; then
    pass "service/$svc has endpoints"
  else
    fail "service/$svc has NO endpoints"
  fi
done

echo
echo "== Ingress =="
http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/" 2>/dev/null || echo "000")
if [ "$http_code" = "200" ]; then
  pass "GET $BASE_URL/ -> 200 (frontend via ingress)"
else
  fail "GET $BASE_URL/ -> $http_code (expected 200, frontend via ingress)"
fi

body=$(curl -sS --max-time 10 "$BASE_URL/api/healthz" 2>/dev/null || echo "")
if [ "$(normalize "$body")" = '{"status":"ok"}' ]; then
  pass "GET $BASE_URL/api/healthz -> ok (rider via ingress)"
else
  fail "GET $BASE_URL/api/healthz -> '$body' (expected {\"status\":\"ok\"}, rider via ingress)"
fi

echo
echo "== App service /healthz (via each pod's own ambassador sidecar) =="
for svc in rider station trip pricing; do
  pod=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$svc" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$pod" ]; then
    fail "$svc /healthz (no running pod found)"
    continue
  fi
  out=$(kubectl -n "$NS" exec "$pod" -c ambassador -- curl -sS --max-time 5 http://127.0.0.1:8080/healthz 2>/dev/null || true)
  if [ "$(normalize "$out")" = '{"status":"ok"}' ]; then
    pass "$svc/healthz via pod/$pod -c ambassador -> ok"
  else
    fail "$svc/healthz via pod/$pod -c ambassador -> '$out' (expected {\"status\":\"ok\"})"
  fi
done

echo
echo "== Postgres =="
pg_out=$(kubectl -n "$NS" exec postgres-0 -- psql -U postgres -d veloshare -tAc "SELECT 1;" 2>/dev/null || true)
if [ "$(normalize "$pg_out")" = "1" ]; then
  pass "postgres-0 accepts a trivial query (SELECT 1)"
else
  fail "postgres-0 query failed or returned unexpected result: '$pg_out'"
fi

echo
echo "== Redis =="
redis_out=$(kubectl -n "$NS" exec deploy/redis -- redis-cli ping 2>/dev/null || true)
if [ "$(normalize "$redis_out")" = "PONG" ]; then
  pass "redis responds to PING"
else
  fail "redis PING failed: '$redis_out'"
fi

echo
passed=$((TOTAL - FAILED))
echo "== summary: $passed/$TOTAL checks passed =="
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi

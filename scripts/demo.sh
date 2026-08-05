#!/usr/bin/env bash
# Interactive walkthrough of the capstone-requirements.md §6.3 live-demo
# checklist, in order, ~5-10 minutes end to end. One function per step; each
# prints a banner naming the CKAD requirement ID(s) it demonstrates (see
# capstone-requirements.md §4) before running real kubectl/helm commands
# against the cluster.
#
# Read-only steps (1, 2, 3, 6, 7) never prompt. Steps that change cluster
# state (4, 5, 8, 9) print what they're about to do and require an explicit
# "y" before running, then restore the original state afterward where that's
# possible (patch back, roll forward again, delete the demo objects they
# created). If a destructive sub-step is interrupted mid-way (Ctrl-C), you
# may need to clean up by hand — the affected step's output says how.
#
# Usage:
#   scripts/demo.sh              run all 9 steps, pausing between each
#   scripts/demo.sh 5            run only step 5
#   scripts/demo.sh --no-pause   run all steps back to back, no pauses
#
# Env overrides:
#   NS                   namespace (default: veloshare)
#   RELEASE              helm release name (default: veloshare)
#   AUTO=1               non-interactive: implies --no-pause, and every
#                        destructive sub-step is SKIPPED unless
#                        FORCE_DESTRUCTIVE=1 is also set
#   FORCE_DESTRUCTIVE=1  with AUTO=1, also run the destructive sub-steps
#                        (only meaningful together with AUTO=1)
set -euo pipefail

NS="${NS:-veloshare}"
RELEASE="${RELEASE:-veloshare}"
BASE_URL="${BASE_URL:-http://localhost}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NO_PAUSE=0
ONLY_STEP=""

# ---- small helpers --------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: scripts/demo.sh [STEP] [--no-pause]

Walks a presenter through the capstone §6.3 live-demo checklist, one CKAD
requirement at a time.

  STEP         run only this step (1-9); default runs all 9 in order
  --no-pause   don't wait for Enter between steps

Env overrides: NS, RELEASE, BASE_URL, AUTO=1, FORCE_DESTRUCTIVE=1
(see the comment header in this file for what each does)
EOF
}

banner() {
  local num="$1" title="$2" reqs="$3"
  echo
  echo "================================================================"
  echo "  STEP $num/9 -- $title"
  echo "  CKAD requirement(s): $reqs   (capstone-requirements.md section 4)"
  echo "================================================================"
}

# Waits for Enter between steps. Skipped when --no-pause / AUTO=1.
pause() {
  if [ "$NO_PAUSE" = "1" ] || [ "${AUTO:-0}" = "1" ]; then
    return 0
  fi
  read -r -p $'\n-- press Enter for the next step (Ctrl-C to stop here) -- ' _ || true
}

# Gate for any command that changes cluster state. In AUTO=1 mode the
# destructive sub-step is skipped unless FORCE_DESTRUCTIVE=1 is also set, so
# a non-interactive "run everything" pass never mutates the cluster by
# accident.
confirm() {
  local prompt="$1" reply
  if [ "${AUTO:-0}" = "1" ]; then
    if [ "${FORCE_DESTRUCTIVE:-0}" = "1" ]; then
      echo "  [auto] proceeding: $prompt"
      return 0
    fi
    echo "  [auto] skipping (destructive; set FORCE_DESTRUCTIVE=1 to include): $prompt"
    return 1
  fi
  read -r -p "  >> $prompt [y/N] " reply || reply=""
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) echo "  skipped."; return 1 ;;
  esac
}

preflight() {
  for bin in kubectl helm curl; do
    command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' not found in PATH" >&2; exit 1; }
  done
  if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
    echo "error: namespace '$NS' not found -- run 'make up' (or 'make deploy') first." >&2
    exit 1
  fi
}

# ---- step 1: pods + endpoints ---------------------------------------------

step1() {
  banner 1 "All Pods Running/Ready; Services have Endpoints" "N5, P1, O1, O2"
  echo "-- Pods (expect STATUS=Running, READY=N/N for every app pod) --"
  kubectl -n "$NS" get pods -o wide
  echo
  echo "-- Deployments / StatefulSets (READY column must equal the desired count) --"
  kubectl -n "$NS" get deploy,statefulset
  echo
  echo "-- Endpoints (a Service with no backing Pod shows <none> here -- none should) --"
  kubectl -n "$NS" get endpoints
}

# ---- step 2: ingress --------------------------------------------------------

step2() {
  banner 2 "Ingress routes to frontend and /api/healthz" "N2, N3, O5"
  echo "-- Ingress objects (two: '/' + optional '/kibana' on 'veloshare', '/api/healthz' on 'veloshare-api') --"
  kubectl -n "$NS" get ingress -o wide
  echo
  echo "-- GET $BASE_URL/  (expect 200, served by frontend) --"
  curl -sS -o /dev/null -w '  HTTP %{http_code}\n' "$BASE_URL/" || echo "  WARNING: request failed"
  echo
  echo "-- GET $BASE_URL/api/healthz  (rewrite-target sends this straight to rider's /healthz) --"
  curl -sS "$BASE_URL/api/healthz" || echo "  WARNING: request failed"
  echo
}

# ---- step 3: configmap / secret injection ----------------------------------

step3() {
  banner 3 "ConfigMap / Secret injection" "C1, C2"
  echo "-- ConfigMaps in $NS (names only) --"
  kubectl -n "$NS" get configmap
  echo
  echo "-- Secrets in $NS (names + type only -- VALUES are never printed) --"
  kubectl -n "$NS" get secret
  echo
  echo "-- trip's envFrom wiring: DB Secret + own ConfigMap + shared auth Secret --"
  kubectl -n "$NS" get deploy trip \
    -o jsonpath='{range .spec.template.spec.containers[?(@.name=="trip")].envFrom[*]}  {.secretRef.name}{.configMapRef.name}{"\n"}{end}'
  echo
  echo "-- pricing's envFrom wiring: ConfigMap only (stateless, no DB credential needed) --"
  kubectl -n "$NS" get deploy pricing \
    -o jsonpath='{range .spec.template.spec.containers[?(@.name=="pricing")].envFrom[*]}  {.configMapRef.name}{"\n"}{end}'
  echo
  echo "-- 'describe secret' shows key NAMES and byte counts, never the value: --"
  kubectl -n "$NS" describe secret trip-db | sed -n '/^Data/,$p'
}

# ---- step 4: probes ---------------------------------------------------------

step4() {
  banner 4 "Probe behaviour" "O1, O2, O3"
  echo "-- rider's liveness/readiness probes (every business service follows this pattern) --"
  echo -n "  liveness:  "
  kubectl -n "$NS" get deploy rider -o jsonpath='{.spec.template.spec.containers[?(@.name=="rider")].livenessProbe}'; echo
  echo -n "  readiness: "
  kubectl -n "$NS" get deploy rider -o jsonpath='{.spec.template.spec.containers[?(@.name=="rider")].readinessProbe}'; echo
  echo
  echo "-- postgres uses an exec probe (pg_isready) instead of HTTP --"
  echo -n "  readiness: "
  kubectl -n "$NS" get statefulset postgres -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}'; echo
  echo
  echo "-- startupProbe pattern (deliberately slow-starting container) is a separate standalone"
  echo "   lab, not applied here: kubectl apply -f $REPO_ROOT/probes-demo.yaml"
  echo
  if confirm "DESTRUCTIVE (self-healing): delete the running rider Pod and watch its Service Endpoint drop, then reappear once the replacement Pod passes readiness?"; then
    local pod
    pod=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=rider -o jsonpath='{.items[0].metadata.name}')
    echo "  deleting pod/$pod ..."
    kubectl -n "$NS" delete pod "$pod"
    echo "  -- rider endpoints right after the delete (may already be empty) --"
    kubectl -n "$NS" get endpoints rider
    echo "  waiting for the Deployment to bring the replacement Pod to Ready ..."
    kubectl -n "$NS" rollout status deploy/rider --timeout=90s
    echo "  -- rider endpoints once the new Pod passes its readiness probe --"
    kubectl -n "$NS" get endpoints rider
  fi
}

# ---- step 5: rolling update / blue-green -----------------------------------

step5() {
  banner 5 "Rolling update / blue-green switch" "P2, P3, D6"
  echo "-- documented rolling-update procedure: kubectl rollout restart + rollout status --"
  kubectl -n "$NS" rollout history deploy/pricing
  echo
  if confirm "DESTRUCTIVE (brief, self-healing): rolling-restart deploy/pricing?"; then
    kubectl -n "$NS" rollout restart deploy/pricing
    kubectl -n "$NS" rollout status deploy/pricing --timeout=90s
    kubectl -n "$NS" rollout history deploy/pricing
  fi
  echo
  echo "-- blue/green lab (bluegreen-demo.yaml): two Deployments (color=blue/green), one"
  echo "   Service; traffic cutover is a single Service-selector patch, no Pod touched --"
  if confirm "DESTRUCTIVE: apply bluegreen-demo.yaml, flip the Service blue -> green -> blue, then delete the demo objects to restore the original (empty) state?"; then
    kubectl apply -f "$REPO_ROOT/bluegreen-demo.yaml"
    kubectl -n "$NS" rollout status deploy/bluegreen-demo-blue --timeout=60s
    kubectl -n "$NS" rollout status deploy/bluegreen-demo-green --timeout=60s
    echo "  -- Service currently selects: --"
    kubectl -n "$NS" get svc bluegreen-demo -o jsonpath='{.spec.selector}'; echo
    echo "  -- curl through the Service (expect BLUE) --"
    kubectl -n "$NS" run bluegreen-curl-1 --rm -i --restart=Never --image=curlimages/curl \
      --labels=app.kubernetes.io/name=probe -- curl -sS --max-time 5 http://bluegreen-demo/ || true
    echo "  -- flipping the Service selector to green --"
    kubectl -n "$NS" patch svc bluegreen-demo -p '{"spec":{"selector":{"color":"green"}}}'
    echo "  -- curl through the Service again (expect GREEN, no Pod was touched) --"
    kubectl -n "$NS" run bluegreen-curl-2 --rm -i --restart=Never --image=curlimages/curl \
      --labels=app.kubernetes.io/name=probe -- curl -sS --max-time 5 http://bluegreen-demo/ || true
    echo "  -- restoring: flipping back to blue --"
    kubectl -n "$NS" patch svc bluegreen-demo -p '{"spec":{"selector":{"color":"blue"}}}'
    echo "  -- restoring: removing the demo objects --"
    kubectl delete -f "$REPO_ROOT/bluegreen-demo.yaml"
  fi
}

# ---- step 6: HPA -------------------------------------------------------------

step6() {
  banner 6 "HPA object present" "P4"
  kubectl -n "$NS" get hpa
  echo
  kubectl -n "$NS" describe hpa pricing
  echo
  echo "  NOTE: metrics-server is not installed in this environment (see CLAUDE.md's"
  echo "  'Deliberate rough edges'), so TARGETS legitimately reads 'cpu: <unknown>/70%' and"
  echo "  the HPA never scales past minReplicas. Its PRESENCE is what's graded here (P4),"
  echo "  not active scaling. Install metrics-server first if you want to show real numbers."
}

# ---- step 7: NetworkPolicy ---------------------------------------------------

step7() {
  banner 7 "NetworkPolicy: allowed vs. denied path" "N4"
  kubectl -n "$NS" get networkpolicy
  echo
  echo "-- DENIED: throwaway pod with a non-matching label calling rider directly --"
  echo "   (expect this to time out / fail -- backend-isolation only allows ingress-nginx,"
  echo "   frontend, and other backend pods)"
  kubectl -n "$NS" run probe-denied --rm -i --restart=Never --image=curlimages/curl \
    --labels=app.kubernetes.io/name=probe -- curl -sS --max-time 5 http://rider/healthz \
    || echo "  (failed/timed out as expected -- NetworkPolicy is enforced)"
  echo
  echo "-- ALLOWED: throwaway pod labeled like the frontend calling the same URL --"
  echo "   (expect 200 -- backend-isolation matches on app.kubernetes.io/name=frontend,"
  echo "   not on which image is actually running)"
  kubectl -n "$NS" run probe-allowed --rm -i --restart=Never --image=curlimages/curl \
    --labels=app.kubernetes.io/name=frontend -- curl -sS --max-time 5 http://rider/healthz \
    || echo "  WARNING: expected this to succeed -- check backend-isolation and kindnet"
}

# ---- step 8: PVC persistence -------------------------------------------------

step8() {
  banner 8 "PVC persistence across Pod delete/recreate" "D5"
  echo "-- postgres's PVC (bound to the postgres-0 StatefulSet Pod) --"
  kubectl -n "$NS" get pvc
  echo
  local marker
  marker="demo-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "-- writing a marker row (public.pvc_demo, separate from any app schema) --"
  kubectl -n "$NS" exec postgres-0 -- psql -U postgres -d veloshare -c \
    "CREATE TABLE IF NOT EXISTS public.pvc_demo (id serial PRIMARY KEY, note text, created_at timestamptz DEFAULT now()); INSERT INTO public.pvc_demo (note) VALUES ('$marker');"
  kubectl -n "$NS" exec postgres-0 -- psql -U postgres -d veloshare -c "SELECT * FROM public.pvc_demo ORDER BY id;"
  echo
  if confirm "DESTRUCTIVE (self-healing): delete pod/postgres-0 so the StatefulSet recreates it, then re-read the marker row from the same PVC?"; then
    kubectl -n "$NS" delete pod postgres-0
    echo "  waiting for postgres-0 to come back Ready ..."
    kubectl -n "$NS" wait --for=condition=Ready pod/postgres-0 --timeout=120s
    echo "  -- marker row after recreate (still present = the PVC's data survived the Pod) --"
    kubectl -n "$NS" exec postgres-0 -- psql -U postgres -d veloshare -c "SELECT * FROM public.pvc_demo ORDER BY id;"
  fi
}

# ---- step 9: helm rollback / kustomize overlay -------------------------------

step9() {
  banner 9 "Helm history/rollback (and/or Kustomize overlay apply)" "P5, P6"
  echo "-- Helm release history --"
  helm -n "$NS" history "$RELEASE"
  echo
  local current_rev prev_rev
  current_rev=$(helm -n "$NS" history "$RELEASE" -o json 2>/dev/null | grep -o '"revision":[0-9]*' | grep -o '[0-9]*' | tail -1 || true)
  if [ -z "$current_rev" ] || [ "$current_rev" -le 1 ]; then
    echo "  only one revision on record -- nothing to roll back to yet."
    echo "  (run 'make deploy' again after a values change to create revision 2, then re-run this step)"
  else
    prev_rev=$((current_rev - 1))
    if confirm "DESTRUCTIVE (restored after): roll back '$RELEASE' from revision $current_rev to $prev_rev, show it took effect, then roll forward again to restore revision $current_rev's content?"; then
      helm -n "$NS" rollback "$RELEASE" "$prev_rev" --wait --timeout 3m
      kubectl -n "$NS" get pods
      helm -n "$NS" history "$RELEASE"
      echo "  -- restoring: rolling forward again to revision $current_rev's content --"
      helm -n "$NS" rollback "$RELEASE" "$current_rev" --wait --timeout 3m
      helm -n "$NS" history "$RELEASE"
    fi
  fi
  echo
  echo "-- Kustomize alternative (kustomize-demo/): base/ + an overlay patching image tag + replicas --"
  if confirm "DESTRUCTIVE: apply the Kustomize base, then the 'patched' overlay (replicas: 3, newTag), then delete both to restore the original (empty) state?"; then
    kubectl apply -k "$REPO_ROOT/kustomize-demo/base"
    kubectl -n "$NS" rollout status deploy/kustomize-demo-app --timeout=60s
    echo "  -- base --"
    kubectl -n "$NS" get deploy kustomize-demo-app \
      -o jsonpath='  replicas={.spec.replicas}  image={.spec.template.spec.containers[0].image}{"\n"}'
    kubectl apply -k "$REPO_ROOT/kustomize-demo/overlays/patched"
    kubectl -n "$NS" rollout status deploy/kustomize-demo-app --timeout=60s
    echo "  -- patched overlay --"
    kubectl -n "$NS" get deploy kustomize-demo-app \
      -o jsonpath='  replicas={.spec.replicas}  image={.spec.template.spec.containers[0].image}{"\n"}'
    echo "  -- restoring: removing the demo objects --"
    kubectl delete -k "$REPO_ROOT/kustomize-demo/overlays/patched"
  fi
}

# ---- main -------------------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --no-pause) NO_PAUSE=1 ;;
    -h|--help) usage; exit 0 ;;
    1|2|3|4|5|6|7|8|9) ONLY_STEP="$arg" ;;
    *) echo "unknown argument: $arg" >&2; usage; exit 1 ;;
  esac
done
[ "${AUTO:-0}" = "1" ] && NO_PAUSE=1

preflight

if [ -n "$ONLY_STEP" ]; then
  "step$ONLY_STEP"
else
  for n in 1 2 3 4 5 6 7 8 9; do
    "step$n"
    [ "$n" -lt 9 ] && pause
  done
  echo
  echo "== demo complete =="
fi

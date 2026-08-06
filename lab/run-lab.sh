#!/usr/bin/env bash
# VeloShare CKAD lab runner — the instructor's Day 3/4/5 lab schedule, executed
# step by step against a real cluster, in an isolated namespace.
#
# Source of truth for what these labs must cover: ../lab-requirements.md
# (12 labs: 3.1-3.4 config & security, 4.1-4.4 networking & storage,
# 5.1-5.4 observability & exam prep).
#
# Two things make this different from a plain `kubectl apply -R`:
#
#   1. Every lab runs against a REAL VeloShare service -- veloshare/pricing,
#      veloshare/frontend, veloshare/pod-lister -- not a stock nginx off Docker
#      Hub. The object under test is always something this project built.
#
#   2. Everything lands in the `veloshare-lab` namespace, never `veloshare`.
#      Half of these labs exist to break something on purpose (quota rejection,
#      selector mismatch, denied egress, a container that fails its probe).
#      Doing that in `veloshare` would fight the Helm release for ownership.
#
# Usage:
#   lab/run-lab.sh                 all 12 labs, in order, pausing between each
#   lab/run-lab.sh 4.3             just lab 4.3
#   lab/run-lab.sh day4            just Day 4 (4.1 - 4.4)
#   lab/run-lab.sh --auto          unattended; non-zero exit if any check fails
#   lab/run-lab.sh --no-pause      all labs back to back, still verbose
#   lab/run-lab.sh --list          list the labs and exit
#   lab/run-lab.sh --clean         delete the veloshare-lab namespace and exit
#
# Env overrides:
#   NS          lab namespace           (default: veloshare-lab)
#   INGRESS_URL ingress controller URL   (default: http://localhost)
#   LAB_HOST    Host header for lab 4.2 (default: lab.veloshare.local)
#
# Exit code: 0 if every verification passed, 1 otherwise. That makes --auto
# usable as a regression check on the cluster, not just a demo.
set -uo pipefail

NS="${NS:-veloshare-lab}"
INGRESS_URL="${INGRESS_URL:-http://localhost}"
LAB_HOST="${LAB_HOST:-lab.veloshare.local}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

LABS=(3.1 3.2 3.3 3.4 4.1 4.2 4.3 4.4 5.1 5.2 5.3 5.4)

declare -A LAB_TITLE=(
  [3.1]="ConfigMap & Secret Injection"
  [3.2]="Security Context Lockdown"
  [3.3]="ServiceAccount & RBAC"
  [3.4]="Namespace Quotas"
  [4.1]="ClusterIP & NodePort"
  [4.2]="Ingress Routing"
  [4.3]="NetworkPolicy Isolation"
  [4.4]="Persistent Volume Claims"
  [5.1]="Self-Healing App"
  [5.2]="CLI Observability"
  [5.3]="Broken YAML Triage"
  [5.4]="Helm Deploy & Rollback"
)

declare -A LAB_DOMAIN=(
  [3.1]="Application Environment, Configuration & Security (25%)"
  [3.2]="Application Environment, Configuration & Security (25%)"
  [3.3]="Application Environment, Configuration & Security (25%)"
  [3.4]="Application Environment, Configuration & Security (25%)"
  [4.1]="Services and Networking (20%)"
  [4.2]="Services and Networking (20%)"
  [4.3]="Services and Networking (20%)"
  [4.4]="Services and Networking / Design and Build"
  [5.1]="Application Observability and Maintenance (15%)"
  [5.2]="Application Observability and Maintenance (15%)"
  [5.3]="Application Observability and Maintenance (15%)"
  [5.4]="Application Deployment (20%)"
)

declare -A LAB_DIR=(
  [3.1]="day3/3.1-configmap-secret"
  [3.2]="day3/3.2-security-context"
  [3.3]="day3/3.3-rbac"
  [3.4]="day3/3.4-quota"
  [4.1]="day4/4.1-clusterip-nodeport"
  [4.2]="day4/4.2-ingress"
  [4.3]="day4/4.3-networkpolicy"
  [4.4]="day4/4.4-pvc"
  [5.1]="day5/5.1-probes"
  [5.2]="day5/5.2-cli-observability"
  [5.3]="day5/5.3-broken-yaml"
  [5.4]="day5/5.4-helm"
)

AUTO=0
NO_PAUSE=0
TARGETS=()

PASSED=0
FAILED=0
FAILED_NAMES=()

# ---- output helpers -------------------------------------------------------

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""
fi

banner() {
  local id="$1"
  echo
  echo "${C_BOLD}================================================================${C_RESET}"
  echo "${C_BOLD}  LAB $id — ${LAB_TITLE[$id]}${C_RESET}"
  echo "  CKAD domain: ${LAB_DOMAIN[$id]}"
  echo "  Files:       lab/${LAB_DIR[$id]}/"
  echo "${C_BOLD}================================================================${C_RESET}"
}

# A short prose explanation of what the next commands prove. This is the part
# a reader needs in order to follow a demo they are watching rather than typing.
note() { echo; echo "${C_CYAN}  ▸ $*${C_RESET}"; }

# Echo a command with a "$ " prefix, then run it, indenting its output. Nothing
# is paraphrased: what is printed is what was executed.
run() {
  local cmd="$1"
  echo
  echo "  ${C_DIM}\$${C_RESET} $cmd"
  eval "$cmd" 2>&1 | sed 's/^/      /'
  return "${PIPESTATUS[0]}"
}

# A verification. Records PASS/FAIL for the final summary and the exit code.
#   check "<description>" "<command>" ["<substring the output must contain>"]
check() {
  local desc="$1" cmd="$2" want="${3:-}"
  local out rc
  out="$(eval "$cmd" 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && { [ -z "$want" ] || grep -qF -- "$want" <<<"$out"; }; then
    echo "    ${C_GREEN}✓ PASS${C_RESET}  $desc"
    PASSED=$((PASSED + 1))
  else
    echo "    ${C_RED}✗ FAIL${C_RESET}  $desc"
    [ -n "$want" ] && echo "           expected to find: $want"
    sed 's/^/           /' <<<"$out" | head -12
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$desc")
  fi
}

# A verification that the command FAILS — the rejection demos in lab 3.4, and
# the blocked-traffic demos in lab 4.3, are only correct when they do not work.
#   check_fails "<description>" "<command>" ["<substring the error must contain>"]
check_fails() {
  local desc="$1" cmd="$2" want="${3:-}"
  local out rc
  out="$(eval "$cmd" 2>&1)"; rc=$?
  if [ $rc -ne 0 ] && { [ -z "$want" ] || grep -qiF -- "$want" <<<"$out"; }; then
    echo "    ${C_GREEN}✓ PASS${C_RESET}  $desc ${C_DIM}(correctly rejected)${C_RESET}"
    sed 's/^/           /' <<<"$out" | head -6
    PASSED=$((PASSED + 1))
  else
    echo "    ${C_RED}✗ FAIL${C_RESET}  $desc ${C_DIM}(expected this to be rejected)${C_RESET}"
    sed 's/^/           /' <<<"$out" | head -12
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$desc")
  fi
}

pause() {
  [ "$AUTO" = 1 ] && return 0
  [ "$NO_PAUSE" = 1 ] && return 0
  echo
  read -r -p "  ${C_DIM}— Enter to continue —${C_RESET} " _ || true
}

# Fail loudly and early if a lab's manifests are missing, rather than emitting a
# confusing kubectl error halfway through.
require_files() {
  local missing=0 f
  for f in "$@"; do
    if [ ! -e "$SCRIPT_DIR/$f" ]; then
      echo "  ${C_RED}missing manifest: lab/$f${C_RESET}" >&2
      missing=1
    fi
  done
  return $missing
}

k() { kubectl -n "$NS" "$@"; }

# ---- cluster preflight ----------------------------------------------------

preflight() {
  command -v kubectl >/dev/null || { echo "error: kubectl not found in PATH" >&2; exit 1; }
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "error: no reachable cluster (is the kind cluster up? try: make up)" >&2
    exit 1
  fi
}

ensure_namespace() {
  if ! kubectl get ns "$NS" >/dev/null 2>&1; then
    note "Creating the lab namespace (isolated from the live 'veloshare' release)."
    run "kubectl apply -f $SCRIPT_DIR/00-namespace.yaml"
  fi
}

# Wait for a Pod to report Ready. Returns non-zero on timeout so `check` can
# record it rather than the script dying mid-lab.
wait_ready() {
  local target="$1" timeout="${2:-120s}"
  k wait --for=condition=ready "$target" --timeout="$timeout" >/dev/null 2>&1
}

# Poll until a Pod's status contains an expected string (used for the failure
# cases, which never become Ready and so cannot be waited on with kubectl wait).
wait_for_status() {
  local pod="$1" want="$2" timeout="${3:-60}"
  local i=0
  while [ $i -lt "$timeout" ]; do
    if k get pod "$pod" -o jsonpath='{.status.containerStatuses[*].state.waiting.reason}{" "}{.status.phase}' 2>/dev/null | grep -qi "$want"; then
      return 0
    fi
    sleep 1; i=$((i + 1))
  done
  return 1
}

# Poll until a Service has (or loses) an endpoint address. Endpoint propagation
# is directly observable, so waiting on the real condition beats guessing a
# sleep duration -- it is both faster in the common case and correct in the slow
# one. Every `sleep N` in these labs was replaced by one of these.
wait_endpoints() {
  local svc="$1" timeout="${2:-60}" i=0
  while [ $i -lt "$timeout" ]; do
    [ -n "$(k get endpoints "$svc" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)" ] && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

wait_no_endpoints() {
  local svc="$1" timeout="${2:-60}" i=0
  while [ $i -lt "$timeout" ]; do
    [ -z "$(k get endpoints "$svc" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)" ] && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

# Poll until a URL answers through the ingress controller.
wait_http() {
  local url="$1" timeout="${2:-60}" i=0
  while [ $i -lt "$timeout" ]; do
    curl -sSf --max-time 3 -o /dev/null -H "Host: $LAB_HOST" "$url" >/dev/null 2>&1 && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

# Poll until a Pod's containers report ready == true|false.
wait_pod_ready_is() {
  local pod="$1" want="$2" timeout="${3:-90}" i=0
  while [ $i -lt "$timeout" ]; do
    [ "$(k get pod "$pod" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "$want" ] && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

# Poll until a ReplicaSet records a FailedCreate event (the quota-rejection
# signal in lab 3.4, which never produces a Pod to wait on).
wait_rs_failure() {
  local selector="$1" timeout="${2:-30}" i=0
  while [ $i -lt "$timeout" ]; do
    k describe rs -l "$selector" 2>/dev/null | grep -q "exceeded quota" && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}

# ============================================================================
# DAY 3 — Configuration & security
# ============================================================================

lab_3_1() {
  local d="${LAB_DIR[3.1]}"
  require_files "$d/pod-config-consumer.yaml" "$d/credentials/DB_PASSWORD" "$d/credentials/JWT_SECRET" || return 1

  note "Objective 1 — create a Secret FROM FILE and a ConfigMap FROM LITERAL."
  note "Both are created imperatively, which is how you would do it under exam time pressure."

  # --dry-run=client | apply makes the imperative create idempotent, so the lab
  # can be re-run without "already exists" errors.
  run "kubectl -n $NS create secret generic lab-pricing-creds \\
      --from-file=$SCRIPT_DIR/$d/credentials \\
      --dry-run=client -o yaml | kubectl apply -f -"

  run "kubectl -n $NS create configmap lab-pricing-config \\
      --from-literal=PRICING_UNLOCK_FEE_CENTS=250 \\
      --from-literal=PRICING_TIER_RATES='{\"standard\": 30, \"member\": 12, \"day_pass\": 7}' \\
      --dry-run=client -o yaml | kubectl apply -f -"

  note "The Secret's keys come from the FILENAMES in credentials/; the ConfigMap's from the literals."
  run "kubectl -n $NS describe secret lab-pricing-creds"
  run "kubectl -n $NS get configmap lab-pricing-config -o jsonpath='{.data}' | head -c 400; echo"

  note "Objective 2 — one Pod consuming BOTH: Secret as env vars, ConfigMap as a mounted volume."
  run "kubectl apply -f $SCRIPT_DIR/$d/pod-config-consumer.yaml"
  wait_ready pod/lab-config-consumer

  note "Secret -> environment variables:"
  run "kubectl -n $NS exec lab-config-consumer -c pricing -- sh -c 'env | grep -E \"^(DB_PASSWORD|JWT_SECRET)=\"'"

  note "ConfigMap -> files on a mounted volume (one file per key):"
  run "kubectl -n $NS exec lab-config-consumer -c pricing -- ls -l /etc/veloshare/config"
  run "kubectl -n $NS exec lab-config-consumer -c pricing -- cat /etc/veloshare/config/PRICING_TIER_RATES; echo"

  note "And the proof it is not merely mounted but USED — pricing's /tiers reflects the lab values,"
  note "not the 100/15/8/5 defaults compiled into services/pricing/main.py."
  run "kubectl -n $NS exec lab-config-consumer -c pricing -- python -c \"import urllib.request,json;print(json.load(urllib.request.urlopen('http://127.0.0.1:8000/tiers')))\""

  echo
  check "Secret injected as env vars" \
    "k exec lab-config-consumer -c pricing -- sh -c 'env | grep -c \"^DB_PASSWORD=\"'" "1"
  check "ConfigMap mounted as a volume" \
    "k exec lab-config-consumer -c pricing -- cat /etc/veloshare/config/PRICING_UNLOCK_FEE_CENTS" "250"
  check "app reads the injected config (unlock fee 250)" \
    "k exec lab-config-consumer -c pricing -- python -c \"import urllib.request,json;print(json.load(urllib.request.urlopen('http://127.0.0.1:8000/tiers'))['unlock_fee_cents'])\"" "250"
}

lab_3_2() {
  local d="${LAB_DIR[3.2]}"
  require_files "$d/pod-hardened.yaml" "$d/broken/pod-runs-as-root.yaml" || return 1

  note "Objective 1 & 2 — non-root, read-only rootfs, no capabilities, no privilege escalation."
  run "kubectl apply -f $SCRIPT_DIR/$d/pod-hardened.yaml"
  wait_ready pod/lab-hardened

  run "kubectl -n $NS get pod lab-hardened -o jsonpath='{.spec.containers[0].securityContext}' | python3 -m json.tool 2>/dev/null || kubectl -n $NS get pod lab-hardened -o jsonpath='{.spec.containers[0].securityContext}{\"\\n\"}'"

  note "Now prove each setting from INSIDE the container rather than trusting the manifest."
  run "kubectl -n $NS exec lab-hardened -c pricing -- id"
  run "kubectl -n $NS exec lab-hardened -c pricing -- grep -E 'CapEff|NoNewPrivs' /proc/self/status"

  note "readOnlyRootFilesystem: writing to / fails, writing to the declared emptyDir succeeds."
  run "kubectl -n $NS exec lab-hardened -c pricing -- touch /nope || true"
  run "kubectl -n $NS exec lab-hardened -c pricing -- touch /var/log/veloshare/ok && echo '      (write to emptyDir succeeded)'"

  note "Counter-example — runAsUser: 0 against runAsNonRoot: true. The kubelet refuses to"
  note "create the container, and notice that 'kubectl apply' itself still reports success."
  run "kubectl apply -f $SCRIPT_DIR/$d/broken/pod-runs-as-root.yaml"
  wait_for_status lab-runs-as-root "CreateContainerConfigError" 60 || true
  run "kubectl -n $NS get pod lab-runs-as-root"
  run "kubectl -n $NS describe pod lab-runs-as-root | grep -A2 -i 'Warning\\|Error' | head -12"

  echo
  check "container runs as uid 10001, not root" \
    "k exec lab-hardened -c pricing -- id -u" "10001"
  check "all capabilities dropped (CapEff is zero)" \
    "k exec lab-hardened -c pricing -- grep CapEff /proc/self/status" "0000000000000000"
  check "privilege escalation disabled (NoNewPrivs: 1)" \
    "k exec lab-hardened -c pricing -- grep NoNewPrivs /proc/self/status" "NoNewPrivs:	1"
  check_fails "root filesystem is read-only" \
    "k exec lab-hardened -c pricing -- touch /nope" "Read-only file system"
  check "root-running Pod is rejected by runAsNonRoot" \
    "k get pod lab-runs-as-root -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}'" "CreateContainerConfigError"
}

lab_3_3() {
  local d="${LAB_DIR[3.3]}"
  require_files "$d/rbac.yaml" "$d/job-pod-lister.yaml" "$d/broken/job-default-sa.yaml" || return 1

  note "Objective 1 — ServiceAccount + Role + RoleBinding. All three are required:"
  note "a Role grants nothing until a RoleBinding attaches it to a subject."
  run "kubectl apply -f $SCRIPT_DIR/$d/rbac.yaml"
  run "kubectl -n $NS get sa,role,rolebinding -l lab=3.3"
  run "kubectl -n $NS describe role lab-pod-lister"

  note "Reason about the grant WITHOUT running a workload — 'auth can-i --as' is the fastest"
  note "RBAC debugging tool there is, and it is worth knowing cold for the exam."
  run "kubectl -n $NS auth can-i list pods   --as=system:serviceaccount:$NS:lab-pod-lister"
  run "kubectl -n $NS auth can-i delete pods --as=system:serviceaccount:$NS:lab-pod-lister"
  run "kubectl -n $NS auth can-i list secrets --as=system:serviceaccount:$NS:lab-pod-lister"
  run "kubectl -n default auth can-i list pods --as=system:serviceaccount:$NS:lab-pod-lister"

  note "Objective 2 — a Pod uses that SA's mounted token to list Pods through the API."
  note "veloshare/pod-lister calls the API with curl, not kubectl, so the token -> header"
  note "-> API call chain is visible in services/pod-lister/list-pods.sh."
  run "kubectl delete job lab-pod-lister -n $NS --ignore-not-found >/dev/null 2>&1; kubectl apply -f $SCRIPT_DIR/$d/job-pod-lister.yaml"
  k wait --for=condition=complete job/lab-pod-lister --timeout=90s >/dev/null 2>&1 || true
  run "kubectl -n $NS logs job/lab-pod-lister"

  note "Counter-example — same image, no serviceAccountName, so it gets the 'default' SA."
  note "Watch it 'succeed' while actually being denied: RBAC failures are 403 response bodies."
  run "kubectl delete job lab-pod-lister-denied -n $NS --ignore-not-found >/dev/null 2>&1; kubectl apply -f $SCRIPT_DIR/$d/broken/job-default-sa.yaml"
  k wait --for=condition=complete job/lab-pod-lister-denied --timeout=90s >/dev/null 2>&1 || true
  run "kubectl -n $NS logs job/lab-pod-lister-denied"

  echo
  check "bound SA may list pods" \
    "k auth can-i list pods --as=system:serviceaccount:$NS:lab-pod-lister" "yes"
  # `kubectl auth can-i` exits 1 when the answer is "no" -- which is the PASSING
  # result here. Capture the word, ignore the exit code.
  check "bound SA may NOT delete pods (least privilege)" \
    "test \"\$(k auth can-i delete pods --as=system:serviceaccount:$NS:lab-pod-lister 2>/dev/null)\" = no && echo ok" "ok"
  check "bound SA may NOT list secrets" \
    "test \"\$(k auth can-i list secrets --as=system:serviceaccount:$NS:lab-pod-lister 2>/dev/null)\" = no && echo ok" "ok"
  check "Role is namespace-scoped (denied in 'default')" \
    "test \"\$(kubectl -n default auth can-i list pods --as=system:serviceaccount:$NS:lab-pod-lister 2>/dev/null)\" = no && echo ok" "ok"
  check "Pod listed namespace pods via its SA token" \
    "k logs job/lab-pod-lister" "lab-pod-lister"
  check "default SA is forbidden" \
    "k logs job/lab-pod-lister-denied" "forbidden"
}

lab_3_4() {
  local d="${LAB_DIR[3.4]}"
  require_files "$d/resourcequota.yaml" "$d/limitrange.yaml" \
                "$d/rejected/deployment-oversized.yaml" "$d/rejected/pod-over-limitrange.yaml" || return 1

  note "Objective 1 — apply a ResourceQuota (namespace ceiling) and a LimitRange (per-container)."
  run "kubectl apply -f $SCRIPT_DIR/$d/resourcequota.yaml -f $SCRIPT_DIR/$d/limitrange.yaml"
  run "kubectl -n $NS describe resourcequota veloshare-lab-quota"
  run "kubectl -n $NS describe limitrange veloshare-lab-limits"

  note "Objective 2, case A — quota rejection via a DEPLOYMENT (4 replicas x 2 CPU vs a 1 CPU ceiling)."
  note "This is the case that catches people out: 'apply' SUCCEEDS and nothing ever comes up."
  run "kubectl apply -f $SCRIPT_DIR/$d/rejected/deployment-oversized.yaml"
  wait_rs_failure "lab=3.4-oversized" 30 || true
  run "kubectl -n $NS get deploy lab-oversized"
  run "kubectl -n $NS get pods -l lab=3.4-oversized"
  note "The real error is an event on the ReplicaSet, never on your terminal:"
  run "kubectl -n $NS describe rs -l lab=3.4-oversized | grep -A3 -i 'FailedCreate\\|forbidden' | head -12"

  note "Objective 2, case B — LimitRange rejection via a BARE POD. Same admission machinery,"
  note "completely different experience: this one fails on your terminal, immediately."
  run "kubectl apply -f $SCRIPT_DIR/$d/rejected/pod-over-limitrange.yaml || true"

  echo
  check "ResourceQuota is enforcing" \
    "k get resourcequota veloshare-lab-quota -o jsonpath='{.status.hard.requests\\.cpu}'" "1"
  check "LimitRange is present" \
    "k get limitrange veloshare-lab-limits -o jsonpath='{.spec.limits[0].max.cpu}'" "2"
  check "oversized Deployment created no Pods at all" \
    "test \$(k get pods -l lab=3.4-oversized --no-headers 2>/dev/null | wc -l) -eq 0 && echo ok" "ok"
  check "quota rejection is recorded on the ReplicaSet" \
    "k describe rs -l lab=3.4-oversized" "exceeded quota"
  check_fails "over-LimitRange Pod is rejected at apply time" \
    "kubectl apply -f $SCRIPT_DIR/$d/rejected/pod-over-limitrange.yaml" "forbidden"

  note "Cleaning up the rejected Deployment so it does not sit at 0/4 through the rest of the run."
  run "kubectl -n $NS delete deploy lab-oversized --ignore-not-found"
}

# ============================================================================
# DAY 4 — Networking & storage
# ============================================================================

lab_4_1() {
  local d="${LAB_DIR[4.1]}"
  require_files "$d/deployment-pricing.yaml" "$d/service-pricing-clusterip.yaml" \
                "$d/deployment-frontend.yaml" "$d/service-frontend-nodeport.yaml" \
                "$d/services-stub-backends.yaml" \
                "$d/broken/service-pricing-selector-mismatch.yaml" \
                "$d/fixed/service-pricing-selector-fixed.yaml" || return 1

  note "Objective 1 — a ClusterIP backend (pricing) and a NodePort frontend."
  note "The backend Service is named 'pricing' on purpose: veloshare/frontend's baked-in"
  note "nginx.conf proxies /api/pricing/ to http://pricing/, so the real image works unmodified."
  run "kubectl apply -f $SCRIPT_DIR/$d/deployment-pricing.yaml -f $SCRIPT_DIR/$d/service-pricing-clusterip.yaml"
  note "The frontend image's baked-in nginx.conf also proxies rider/station/trip, and nginx"
  note "refuses to start if ANY proxy_pass hostname fails to resolve. Selector-less stub"
  note "Services give those names a DNS record -- see services-stub-backends.yaml."
  run "kubectl apply -f $SCRIPT_DIR/$d/services-stub-backends.yaml"
  run "kubectl apply -f $SCRIPT_DIR/$d/deployment-frontend.yaml -f $SCRIPT_DIR/$d/service-frontend-nodeport.yaml"
  k rollout status deploy/pricing --timeout=90s >/dev/null 2>&1 || true
  k rollout status deploy/frontend --timeout=90s >/dev/null 2>&1 || true
  run "kubectl -n $NS get deploy,svc -l app.kubernetes.io/component=ckad-lab"

  note "Objective 3 — Endpoints. This is the one-command answer to 'why does my Service not work'."
  run "kubectl -n $NS get endpoints pricing frontend"
  run "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=pricing"

  note "Reaching the ClusterIP by DNS from another Pod — east-west traffic:"
  run "kubectl -n $NS exec deploy/frontend -- wget -qO- --timeout=5 http://pricing/healthz; echo"

  note "Objective 2 — break the selector on purpose, then diagnose it."
  run "kubectl apply -f $SCRIPT_DIR/$d/broken/service-pricing-selector-mismatch.yaml"
  wait_no_endpoints pricing 30 || true
  run "kubectl -n $NS get endpoints pricing"
  note "Empty Endpoints is ALWAYS one of two things: the selector matches no Pod labels,"
  note "or no matching Pod is Ready. Compare the two label sets directly:"
  run "kubectl -n $NS get svc pricing -o jsonpath='{.spec.selector}{\"\\n\"}'"
  run "kubectl -n $NS get pods -l app.kubernetes.io/name=pricing --show-labels | head -4"

  note "Now fix it — a single apply, because the selector was the only thing wrong."
  run "kubectl apply -f $SCRIPT_DIR/$d/fixed/service-pricing-selector-fixed.yaml"
  wait_endpoints pricing 30 || true
  run "kubectl -n $NS get endpoints pricing"

  echo
  check "pricing Service is ClusterIP" \
    "k get svc pricing -o jsonpath='{.spec.type}'" "ClusterIP"
  check "frontend Service is NodePort" \
    "k get svc frontend -o jsonpath='{.spec.type}'" "NodePort"
  check "pricing has Endpoints after the fix" \
    "k get endpoints pricing -o jsonpath='{.subsets[0].addresses[0].ip}'"
  check "backend reachable by DNS from the frontend Pod" \
    "k exec deploy/frontend -- wget -qO- --timeout=5 http://pricing/healthz" '"status":"ok"'
}

lab_4_2() {
  local d="${LAB_DIR[4.2]}"
  require_files "$d/ingress-frontend.yaml" "$d/ingress-api.yaml" || return 1

  note "Objective 1 — route / to the frontend and /api to the backend."
  note "Two Ingress OBJECTS, not two rules: the rewrite-target annotation applies to every"
  note "path in the object it is set on, so mixing them would rewrite '/' as well. The platform"
  note "learned this the hard way — see the incident comment in helm/veloshare/templates/ingress-api.yaml."
  run "kubectl apply -f $SCRIPT_DIR/$d/ingress-frontend.yaml -f $SCRIPT_DIR/$d/ingress-api.yaml"
  wait_http "$INGRESS_URL/api/healthz" 60 || true
  run "kubectl -n $NS get ingress"

  note "Both Ingresses set host '$LAB_HOST' so they cannot collide with the live veloshare"
  note "Ingress, which is host-less and therefore matches any Host header on '/'."

  note "Objective 2 — verify through the ingress controller, not by port-forwarding."
  run "curl -sS -H 'Host: $LAB_HOST' $INGRESS_URL/api/healthz; echo"
  run "curl -sS -H 'Host: $LAB_HOST' $INGRESS_URL/api/tiers; echo"
  run "curl -sS -o /dev/null -w '      HTTP %{http_code}\\n' -H 'Host: $LAB_HOST' $INGRESS_URL/"
  run "kubectl -n $NS describe ingress lab-api | tail -12"

  echo
  check "/api/healthz routes to the pricing backend" \
    "curl -sS --max-time 8 -H 'Host: $LAB_HOST' $INGRESS_URL/api/healthz" '"status":"ok"'
  check "/api/tiers routes to the pricing backend" \
    "curl -sS --max-time 8 -H 'Host: $LAB_HOST' $INGRESS_URL/api/tiers" "unlock_fee_cents"
  check "/ routes to the frontend" \
    "curl -sS --max-time 8 -o /dev/null -w '%{http_code}' -H 'Host: $LAB_HOST' $INGRESS_URL/" "200"
  check "two Ingress objects, two backends" \
    "test \$(k get ingress --no-headers | wc -l) -ge 2 && echo ok" "ok"
}

lab_4_3() {
  local d="${LAB_DIR[4.3]}"
  require_files "$d/networkpolicy-default-deny.yaml" "$d/networkpolicy-allow-dns.yaml" \
                "$d/networkpolicy-allow-frontend-to-pricing.yaml" \
                "$d/networkpolicy-allow-ingress-to-frontend.yaml" \
                "$d/networkpolicy-deny-external-egress.yaml" "$d/test-client.yaml" || return 1

  note "This lab needs lab 4.1's pricing + frontend Deployments. Applying them if absent."
  k get deploy pricing >/dev/null 2>&1 || run "kubectl apply -f $SCRIPT_DIR/${LAB_DIR[4.1]}/deployment-pricing.yaml -f $SCRIPT_DIR/${LAB_DIR[4.1]}/service-pricing-clusterip.yaml"
  k get deploy frontend >/dev/null 2>&1 || run "kubectl apply -f $SCRIPT_DIR/${LAB_DIR[4.1]}/services-stub-backends.yaml -f $SCRIPT_DIR/${LAB_DIR[4.1]}/deployment-frontend.yaml -f $SCRIPT_DIR/${LAB_DIR[4.1]}/service-frontend-nodeport.yaml"
  k rollout status deploy/pricing --timeout=90s >/dev/null 2>&1 || true
  k rollout status deploy/frontend --timeout=90s >/dev/null 2>&1 || true

  note "An unauthorised client Pod, deliberately NOT labelled as the frontend."
  run "kubectl apply -f $SCRIPT_DIR/$d/test-client.yaml"
  wait_ready pod/lab-netpol-client

  note "Baseline BEFORE any policy — everything can reach everything."
  run "kubectl -n $NS exec lab-netpol-client -- python -c \"import urllib.request;print(urllib.request.urlopen('http://pricing/healthz',timeout=3).read().decode())\" || true"

  note "Objective 1 — default-deny first, then add back exactly what is needed."
  note "Order matters conceptually, not mechanically: policies are purely additive allow-lists,"
  note "and a Pod becomes isolated the moment ANY policy selects it."
  run "kubectl apply -f $SCRIPT_DIR/$d/networkpolicy-default-deny.yaml"
  run "kubectl apply -f $SCRIPT_DIR/$d/networkpolicy-allow-dns.yaml"
  run "kubectl apply -f $SCRIPT_DIR/$d/networkpolicy-allow-frontend-to-pricing.yaml"
  run "kubectl apply -f $SCRIPT_DIR/$d/networkpolicy-allow-ingress-to-frontend.yaml"
  run "kubectl -n $NS get networkpolicy"
  # The one place a fixed sleep is honest: the CNI applies policies
  # asynchronously and exposes no readiness signal to poll.
  sleep 2

  note "ALLOWED — frontend to pricing, which the policy names explicitly:"
  run "kubectl -n $NS exec deploy/frontend -- wget -qO- --timeout=5 http://pricing/healthz; echo"

  note "DENIED — the same request from the unauthorised client. Note it HANGS rather than"
  note "refusing: a dropped packet looks like a timeout, not a connection error. That"
  note "distinction is how you tell a NetworkPolicy from a wrong port."
  run "kubectl -n $NS exec lab-netpol-client -- python -c \"import urllib.request;print(urllib.request.urlopen('http://pricing/healthz',timeout=3).read().decode())\" || true"

  note "Objective 2 — deny backend egress to the internet."
  run "kubectl apply -f $SCRIPT_DIR/$d/networkpolicy-deny-external-egress.yaml"
  sleep 2
  run "kubectl -n $NS exec deploy/pricing -- python -c \"import socket;socket.create_connection(('1.1.1.1',443),timeout=3);print('reached the internet')\" || true"

  echo
  check "allowed path still works (frontend -> pricing)" \
    "k exec deploy/frontend -- wget -qO- --timeout=8 http://pricing/healthz" '"status":"ok"'
  check_fails "unauthorised client is blocked" \
    "k exec lab-netpol-client -- python -c \"import urllib.request;urllib.request.urlopen('http://pricing/healthz',timeout=3)\""
  check_fails "backend egress to the internet is blocked" \
    "k exec deploy/pricing -- python -c \"import socket;socket.create_connection(('1.1.1.1',443),timeout=3)\""
  check "DNS still resolves (the rule people forget)" \
    "k exec deploy/frontend -- wget -qO- --timeout=8 http://pricing/healthz" '"status":"ok"'
  # Both lab 4.2 routes, not just one. /api survives on the pricing policy's
  # ingress-nginx peer; / needs its own rule on frontend, and checking only the
  # first would hide that.
  if k get ingress lab-frontend >/dev/null 2>&1; then
    check "Ingress route /api still reachable under the policies" \
      "curl -sS --max-time 8 -H 'Host: $LAB_HOST' $INGRESS_URL/api/healthz" '"status":"ok"'
    check "Ingress route / still reachable under the policies" \
      "curl -sS --max-time 8 -o /dev/null -w '%{http_code}' -H 'Host: $LAB_HOST' $INGRESS_URL/" "200"
  fi

  # The default-deny selects EVERY Pod in the namespace, which would quietly
  # break labs 5.1-5.4 (their Pods would be isolated with no matching allow
  # rule). Tearing it down is part of the lab, not an afterthought.
  note "Removing this lab's policies before moving on — 'podSelector: {}' selects every Pod in"
  note "the namespace, so leaving it in place would isolate the Day 5 workloads too."
  note "Re-apply any time with: kubectl apply -f lab/$d/"
  run "kubectl -n $NS delete networkpolicy -l lab=4.3 --ignore-not-found"
}

lab_4_4() {
  local d="${LAB_DIR[4.4]}"
  require_files "$d/pvc.yaml" "$d/pod-writer.yaml" || return 1

  note "Objective 1 — a 1Gi PVC via dynamic provisioning (StorageClass 'standard')."
  run "kubectl apply -f $SCRIPT_DIR/$d/pvc.yaml"
  run "kubectl -n $NS get pvc lab-pricing-logs"
  note "Pending is CORRECT here, not broken: 'standard' uses volumeBindingMode"
  note "WaitForFirstConsumer, so the PV is not provisioned until a Pod actually mounts it."

  note "Objective 2 — mount it, write data, delete the Pod, recreate, verify."
  note "The mount point is /var/log/veloshare, which is where pricing genuinely writes its"
  note "JSON log — so this persists the service's real data, not a synthetic test file."
  run "kubectl apply -f $SCRIPT_DIR/$d/pod-writer.yaml"
  wait_ready pod/lab-pvc-writer
  run "kubectl -n $NS get pvc lab-pricing-logs"

  note "Generate real application log lines, then add an unmistakable marker."
  run "kubectl -n $NS exec lab-pvc-writer -- python -c \"import urllib.request
for _ in range(5): urllib.request.urlopen('http://127.0.0.1:8000/tiers',timeout=5)
print('made 5 requests')\""
  run "kubectl -n $NS exec lab-pvc-writer -- sh -c 'echo lab-4.4-marker-\$(date -u +%H%M%S) >> /var/log/veloshare/marker.txt'"
  run "kubectl -n $NS exec lab-pvc-writer -- sh -c 'wc -l < /var/log/veloshare/app.log; cat /var/log/veloshare/marker.txt'"

  note "Now destroy the Pod completely. The PVC — and the PV behind it — are untouched."
  run "kubectl -n $NS delete pod lab-pvc-writer --wait=true"
  run "kubectl -n $NS get pvc lab-pricing-logs"

  note "Recreate from the same manifest and read the data back."
  run "kubectl apply -f $SCRIPT_DIR/$d/pod-writer.yaml"
  wait_ready pod/lab-pvc-writer
  run "kubectl -n $NS exec lab-pvc-writer -- cat /var/log/veloshare/marker.txt"

  echo
  check "PVC is Bound" \
    "k get pvc lab-pricing-logs -o jsonpath='{.status.phase}'" "Bound"
  check "PVC provisioned 1Gi" \
    "k get pvc lab-pricing-logs -o jsonpath='{.status.capacity.storage}'" "1Gi"
  check "marker file survived Pod deletion and recreation" \
    "k exec lab-pvc-writer -- cat /var/log/veloshare/marker.txt" "lab-4.4-marker"
  check "the service's own log file survived too" \
    "k exec lab-pvc-writer -- sh -c 'test -s /var/log/veloshare/app.log && echo ok'" "ok"
}

# ============================================================================
# DAY 5 — Observability & exam prep
# ============================================================================

lab_5_1() {
  local d="${LAB_DIR[5.1]}"
  require_files "$d/pod-probes.yaml" "$d/service-probes.yaml" || return 1

  note "Objectives 1-3 — HTTP liveness, file-based readiness, and a startup probe, on one Pod."
  run "kubectl delete pod lab-probes -n $NS --ignore-not-found >/dev/null 2>&1; kubectl apply -f $SCRIPT_DIR/$d/pod-probes.yaml -f $SCRIPT_DIR/$d/service-probes.yaml"

  note "While the startupProbe is running, liveness and readiness are SUSPENDED. That is the"
  note "entire reason startupProbe exists: a slow starter would otherwise be killed by its"
  note "own liveness probe before it finished booting."
  wait_pod_ready_is lab-probes false 60 || true
  run "kubectl -n $NS get pod lab-probes"

  note "The readiness probe is 'cat /tmp/ready' and that file does not exist yet, so the Pod"
  note "is Running but 0/1 — and therefore absent from the Service's Endpoints."
  run "kubectl -n $NS get endpoints lab-probes"

  note "Create the file. Readiness flips within one probe period and the endpoint appears."
  run "kubectl -n $NS exec lab-probes -- touch /tmp/ready"
  wait_pod_ready_is lab-probes true 30 || true
  run "kubectl -n $NS get pod lab-probes"
  run "kubectl -n $NS get endpoints lab-probes"

  note "Now remove it again. The endpoint disappears — but RESTARTS stays 0."
  note "That is the difference the exam tests: readiness removes traffic, liveness restarts."
  run "kubectl -n $NS exec lab-probes -- rm -f /tmp/ready"
  wait_pod_ready_is lab-probes false 30 || true
  run "kubectl -n $NS get pod lab-probes"
  run "kubectl -n $NS get endpoints lab-probes"

  echo
  check "Pod is not Ready without /tmp/ready" \
    "k get pod lab-probes -o jsonpath='{.status.containerStatuses[0].ready}'" "false"
  check "Endpoints are empty while not Ready" \
    "test -z \"\$(k get endpoints lab-probes -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null)\" && echo ok" "ok"
  run "kubectl -n $NS exec lab-probes -- touch /tmp/ready" >/dev/null 2>&1
  wait_pod_ready_is lab-probes true 30 || true
  check "Pod becomes Ready once the file exists" \
    "k get pod lab-probes -o jsonpath='{.status.containerStatuses[0].ready}'" "true"
  check "readiness churn did NOT restart the container" \
    "k get pod lab-probes -o jsonpath='{.status.containerStatuses[0].restartCount}'" "0"
  check "all three probe types are configured" \
    "k get pod lab-probes -o jsonpath='{.spec.containers[0].startupProbe.httpGet.path}{\" \"}{.spec.containers[0].livenessProbe.httpGet.path}{\" \"}{.spec.containers[0].readinessProbe.exec.command[0]}'" "/healthz /healthz cat"
}

lab_5_2() {
  local d="${LAB_DIR[5.2]}"
  require_files "$d/deployment-multicontainer.yaml" "$d/configmap-ambassador.yaml" "$d/pod-crashloop.yaml" || return 1

  note "Objective 1 — 'kubectl logs -c'. A two-container Pod (pricing + the ambassador nginx"
  note "sidecar the real platform uses) makes -c necessary rather than decorative."
  run "kubectl apply -f $SCRIPT_DIR/$d/configmap-ambassador.yaml -f $SCRIPT_DIR/$d/deployment-multicontainer.yaml"
  k rollout status deploy/lab-observe --timeout=90s >/dev/null 2>&1 || true
  run "kubectl -n $NS get pod -l app.kubernetes.io/name=pricing,lab=5.2"

  note "Without -c, modern kubectl does NOT refuse -- it picks the first container and says so:"
  note "  Defaulted container \"pricing\" out of: pricing, ambassador"
  note "Older kubectl errored out instead. Either way, never rely on the default: it silently"
  note "changes which container you are reading if the Pod spec is reordered."
  run "kubectl -n $NS logs deploy/lab-observe --tail=5 || true"
  run "kubectl -n $NS logs deploy/lab-observe -c pricing --tail=5"
  run "kubectl -n $NS logs deploy/lab-observe -c ambassador --tail=5"
  run "kubectl -n $NS logs deploy/lab-observe --all-containers --tail=6"

  note "--previous needs a container that HAS a previous instance, so here is one that"
  note "crashes on purpose every few seconds."
  run "kubectl delete pod lab-crashloop -n $NS --ignore-not-found >/dev/null 2>&1; kubectl apply -f $SCRIPT_DIR/$d/pod-crashloop.yaml"
  note "Waiting for the first restart..."
  local i=0
  while [ $i -lt 90 ]; do
    [ "$(k get pod lab-crashloop -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo 0)" -ge 1 ] 2>/dev/null && break
    sleep 2; i=$((i + 2))
  done
  run "kubectl -n $NS get pod lab-crashloop"
  note "The current instance may still be starting; --previous is the only way to see why"
  note "the LAST one died. This is the single most useful flag for a CrashLoopBackOff."
  run "kubectl -n $NS logs lab-crashloop --previous"

  note "Objective 2 — Events, from both directions."
  run "kubectl -n $NS describe pod lab-crashloop | tail -14"
  run "kubectl -n $NS get events --sort-by=.lastTimestamp | tail -12"

  note "Objective 3 — kubectl top. Needs metrics-server; on kind it also needs"
  note "--kubelet-insecure-tls, which 'make metrics-server' patches in for you."
  run "kubectl -n $NS top pods || echo '      metrics-server not installed — run: make metrics-server'"

  echo
  check "logs -c selects the app container" \
    "k logs deploy/lab-observe -c pricing --tail=20" "pricing"
  check "logs -c selects the sidecar" \
    "k logs deploy/lab-observe -c ambassador --tail=20 2>&1 | head -1; echo ok" "ok"
  check "logs without -c defaults to the first container and announces it" \
    "k logs deploy/lab-observe --tail=1 2>&1" "Defaulted container"
  check "crashlooping Pod has restarted at least once" \
    "test \"\$(k get pod lab-crashloop -o jsonpath='{.status.containerStatuses[0].restartCount}')\" -ge 1 && echo ok" "ok"
  check "--previous shows why the last instance died" \
    "k logs lab-crashloop --previous" "simulated crash"
  check "events are readable for the failing Pod" \
    "k describe pod lab-crashloop" "Container started"
}

lab_5_3() {
  local d="${LAB_DIR[5.3]}"
  require_files "$d/broken/1-deployment-selector.yaml" "$d/fixed/1-deployment-selector.yaml" \
                "$d/broken/2-service-targetport.yaml" "$d/fixed/2-service-targetport.yaml" \
                "$d/broken/3-deployment-image.yaml" "$d/fixed/3-deployment-image.yaml" || return 1

  note "Bug 1 — selector does not match the Pod template. Rejected by API VALIDATION,"
  note "so this one never reaches the cluster at all. Read the error, it names the field."
  run "kubectl apply -f $SCRIPT_DIR/$d/broken/1-deployment-selector.yaml || true"
  run "kubectl apply -f $SCRIPT_DIR/$d/fixed/1-deployment-selector.yaml"
  k rollout status deploy/lab-triage-selector --timeout=90s >/dev/null 2>&1 || true
  run "kubectl -n $NS get deploy lab-triage-selector"

  note "Bug 2 — Service targetPort 8080 against a container listening on 8000."
  note "The nastiest of the three, because Endpoints ARE populated: the selector is fine and"
  note "the Pod is Ready. Everything looks healthy and nothing works."
  run "kubectl apply -f $SCRIPT_DIR/$d/broken/2-service-targetport.yaml"
  k rollout status deploy/lab-triage-port --timeout=90s >/dev/null 2>&1 || true
  wait_endpoints lab-triage-port 30 || true
  run "kubectl -n $NS get endpoints lab-triage-port"
  note "Endpoints present — note the :8080 — yet the connection fails:"
  run "kubectl -n $NS exec deploy/lab-triage-port -- python -c \"import urllib.request;print(urllib.request.urlopen('http://lab-triage-port/healthz',timeout=5).read())\" || true"
  run "kubectl apply -f $SCRIPT_DIR/$d/fixed/2-service-targetport.yaml"
  wait_endpoints lab-triage-port 30 || true
  run "kubectl -n $NS get endpoints lab-triage-port"
  run "kubectl -n $NS exec deploy/lab-triage-port -- python -c \"import urllib.request;print(urllib.request.urlopen('http://lab-triage-port/healthz',timeout=5).read().decode())\""

  note "Bug 3 — an image tag that was never loaded into the kind cluster."
  run "kubectl apply -f $SCRIPT_DIR/$d/broken/3-deployment-image.yaml"
  wait_for_status "$(k get pod -l lab=5.3-image -o name 2>/dev/null | head -1 | cut -d/ -f2)" "ImagePull" 45 || sleep 5
  run "kubectl -n $NS get pods -l lab=5.3-image"
  run "kubectl -n $NS describe pod -l lab=5.3-image | grep -A3 -i 'failed\\|error' | head -10"
  run "kubectl apply -f $SCRIPT_DIR/$d/fixed/3-deployment-image.yaml"
  k rollout status deploy/lab-triage-image --timeout=90s >/dev/null 2>&1 || true
  run "kubectl -n $NS get deploy lab-triage-image"

  echo
  check_fails "bug 1: mismatched selector is rejected by validation" \
    "kubectl apply -f $SCRIPT_DIR/$d/broken/1-deployment-selector.yaml" "selector"
  check "bug 1 fixed: Deployment rolls out" \
    "k get deploy lab-triage-selector -o jsonpath='{.status.readyReplicas}'" "1"
  check "bug 2 fixed: Service targetPort now matches the container port" \
    "k get svc lab-triage-port -o jsonpath='{.spec.ports[0].targetPort}'" "8000"
  check "bug 2 fixed: backend answers through the Service" \
    "k exec deploy/lab-triage-port -- python -c \"import urllib.request;print(urllib.request.urlopen('http://lab-triage-port/healthz',timeout=8).read().decode())\"" '"status":"ok"'
  check "bug 3 fixed: Deployment rolls out with a real tag" \
    "k get deploy lab-triage-image -o jsonpath='{.status.readyReplicas}'" "1"
}

lab_5_4() {
  local d="${LAB_DIR[5.4]}"
  local chart="$SCRIPT_DIR/$d/lab-pricing"
  require_files "$d/lab-pricing/Chart.yaml" "$d/lab-pricing/values.yaml" || return 1

  if ! command -v helm >/dev/null; then
    echo "  ${C_YELLOW}helm not found in PATH — skipping lab 5.4${C_RESET}"
    return 0
  fi

  note "Render and lint before touching the cluster — the repo convention for every chart."
  run "helm lint $chart"
  run "helm template lab-pricing $chart | head -30"

  note "Objective 1 — install with value overrides."
  note "The observable proof of which revision is live is pricing's own GET /tiers:"
  note "unlock_fee_cents comes from the chart's ConfigMap, so it changes when values change."
  run "helm -n $NS upgrade --install lab-pricing $chart --wait --timeout 3m"
  run "helm -n $NS list"
  run "kubectl -n $NS exec deploy/lab-pricing -- python -c \"import urllib.request,json;print('unlock_fee_cents =', json.load(urllib.request.urlopen('http://127.0.0.1:8000/tiers',timeout=5))['unlock_fee_cents'])\""

  note "Objective 2 — upgrade, then roll back."
  run "helm -n $NS upgrade lab-pricing $chart --set fare.unlockFeeCents=375 --set replicaCount=2 --wait --timeout 3m"
  run "kubectl -n $NS get deploy lab-pricing"
  run "kubectl -n $NS exec deploy/lab-pricing -- python -c \"import urllib.request,json;print('unlock_fee_cents =', json.load(urllib.request.urlopen('http://127.0.0.1:8000/tiers',timeout=5))['unlock_fee_cents'])\""
  run "helm -n $NS history lab-pricing"

  note "Roll back to revision 1. Note this creates a NEW revision rather than deleting one —"
  note "Helm history is append-only, which is what makes rollback itself reversible."
  run "helm -n $NS rollback lab-pricing 1 --wait --timeout 3m"
  run "helm -n $NS history lab-pricing"
  run "kubectl -n $NS get deploy lab-pricing"
  run "kubectl -n $NS exec deploy/lab-pricing -- python -c \"import urllib.request,json;print('unlock_fee_cents =', json.load(urllib.request.urlopen('http://127.0.0.1:8000/tiers',timeout=5))['unlock_fee_cents'])\""

  echo
  check "chart lints clean" "helm lint $chart" "0 chart(s) failed"
  check "release is deployed" \
    "helm -n $NS status lab-pricing -o json | python3 -c 'import sys,json;print(json.load(sys.stdin)[\"info\"][\"status\"])'" "deployed"
  check "history records at least 3 revisions (install, upgrade, rollback)" \
    "test \$(helm -n $NS history lab-pricing --max 20 -o json | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))') -ge 3 && echo ok" "ok"
  check "rollback restored the original value (100)" \
    "k exec deploy/lab-pricing -- python -c \"import urllib.request,json;print(json.load(urllib.request.urlopen('http://127.0.0.1:8000/tiers',timeout=8))['unlock_fee_cents'])\"" "100"
  check "rollback restored the original replica count (1)" \
    "k get deploy lab-pricing -o jsonpath='{.spec.replicas}'" "1"
}

# ---- summary / cleanup ----------------------------------------------------

summary() {
  echo
  echo "${C_BOLD}================================================================${C_RESET}"
  echo "${C_BOLD}  SUMMARY${C_RESET}"
  echo "  ${C_GREEN}passed: $PASSED${C_RESET}   ${C_RED}failed: $FAILED${C_RESET}"
  if [ "$FAILED" -gt 0 ]; then
    echo
    echo "  Failed checks:"
    printf '    - %s\n' "${FAILED_NAMES[@]}"
  fi
  echo "${C_BOLD}================================================================${C_RESET}"
  echo
  echo "  Inspect what was built:   kubectl -n $NS get all,ingress,networkpolicy,pvc"
  echo "  Tear the lab down:        lab/run-lab.sh --clean"
  echo
}

clean() {
  echo
  echo "${C_YELLOW}DESTRUCTIVE:${C_RESET} this deletes the entire '$NS' namespace and everything in it."
  echo "The live 'veloshare' namespace is not touched."
  if [ "$AUTO" != 1 ]; then
    read -r -p "Type the namespace name to confirm: " confirm
    if [ "$confirm" != "$NS" ]; then
      echo "Aborted."
      exit 1
    fi
  fi
  command -v helm >/dev/null && helm -n "$NS" uninstall lab-pricing >/dev/null 2>&1
  kubectl delete namespace "$NS" --ignore-not-found --wait=true
  echo "Deleted namespace $NS."
}

list_labs() {
  echo
  echo "  ${C_BOLD}VeloShare CKAD labs${C_RESET} — see lab-requirements.md"
  echo
  local id day="" d
  for id in "${LABS[@]}"; do
    d="day${id%%.*}"
    if [ "$d" != "$day" ]; then
      day="$d"
      case "$day" in
        day3) echo "  ${C_BOLD}Day 3 — Configuration & security${C_RESET}" ;;
        day4) echo "  ${C_BOLD}Day 4 — Networking & storage${C_RESET}" ;;
        day5) echo "  ${C_BOLD}Day 5 — Observability & exam prep${C_RESET}" ;;
      esac
    fi
    printf '    %-5s %-32s %s\n' "$id" "${LAB_TITLE[$id]}" "${C_DIM}lab/${LAB_DIR[$id]}/${C_RESET}"
  done
  echo
}

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---- main -----------------------------------------------------------------

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --auto)     AUTO=1; NO_PAUSE=1 ;;
      --no-pause) NO_PAUSE=1 ;;
      --list)     list_labs; exit 0 ;;
      --clean)    preflight; clean; exit 0 ;;
      -h|--help)  usage; exit 0 ;;
      day3)       TARGETS+=(3.1 3.2 3.3 3.4) ;;
      day4)       TARGETS+=(4.1 4.2 4.3 4.4) ;;
      day5)       TARGETS+=(5.1 5.2 5.3 5.4) ;;
      [345].[1-4]) TARGETS+=("$arg") ;;
      *)          echo "unknown argument: $arg" >&2; usage >&2; exit 1 ;;
    esac
  done

  [ ${#TARGETS[@]} -eq 0 ] && TARGETS=("${LABS[@]}")

  preflight
  ensure_namespace

  local id fn
  for id in "${TARGETS[@]}"; do
    banner "$id"
    fn="lab_${id//./_}"
    if ! declare -F "$fn" >/dev/null; then
      echo "  ${C_RED}no implementation for lab $id${C_RESET}"
      FAILED=$((FAILED + 1)); FAILED_NAMES+=("lab $id not implemented")
      continue
    fi
    if ! "$fn"; then
      echo "  ${C_RED}lab $id could not run (see errors above)${C_RESET}"
      FAILED=$((FAILED + 1)); FAILED_NAMES+=("lab $id could not run")
    fi
    pause
  done

  summary
  [ "$FAILED" -eq 0 ]
}

main "$@"

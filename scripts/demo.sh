#!/usr/bin/env bash
# Interactive walkthrough of the capstone-requirements.md §6.3 live-demo
# checklist, in order, ~10-15 minutes end to end. One function per step; each
# prints a banner naming the CKAD requirement ID(s) it demonstrates (see
# capstone-requirements.md §4) before running real kubectl/helm commands
# against the cluster.
#
# Every step is presented in three lanes, so a reviewer can follow the whole
# chain from source to running cluster:
#
#   MANIFEST  where the resource is DECLARED -- repo file path, real line
#             numbers, and the relevant snippet printed inline.
#   LIVE      the exact command (echoed with a "$ " prefix before it runs) and
#             its unedited output from the cluster. Nothing is paraphrased:
#             what you see printed is what was executed.
#   EXPORT    the live object written to docs/evidence/*.yaml so it can be read
#             in full, diffed, or attached to the submission.
#
# Secrets are NEVER exported as YAML -- `kubectl describe secret` output (key
# names + byte counts, no values) goes to docs/evidence/*.txt instead. See
# secret_snap() below.
#
# Read-only steps (1, 2, 3, 6, 7) never prompt. Steps that change cluster
# state (4, 5, 8, 9) print what they're about to do and require an explicit
# "y" before running, then restore the original state afterward where that's
# possible (patch back, roll forward again, delete the demo objects they
# created). If a destructive sub-step is interrupted mid-way (Ctrl-C), you
# may need to clean up by hand -- the affected step's output says how.
#
# Usage:
#   scripts/demo.sh              run all 9 steps, pausing between each
#   scripts/demo.sh 5            run only step 5
#   scripts/demo.sh --no-pause   run all steps back to back, no pauses
#
# Env overrides:
#   NS                   namespace (default: veloshare)
#   RELEASE              helm release name (default: veloshare)
#   EXPORT_DIR           where the YAML exports land (default: docs/evidence)
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
EXPORT_DIR="${EXPORT_DIR:-$REPO_ROOT/docs/evidence}"

NO_PAUSE=0
ONLY_STEP=""

# ---- small helpers --------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: scripts/demo.sh [STEP] [--no-pause]

Walks a presenter through the capstone §6.3 live-demo checklist, one CKAD
requirement at a time. Each step shows the declaring manifest (file:line),
the exact command being run, its live output, and exports the object to YAML.

  STEP         run only this step (1-9); default runs all 9 in order
  --no-pause   don't wait for Enter between steps

Env overrides: NS, RELEASE, BASE_URL, EXPORT_DIR, AUTO=1, FORCE_DESTRUCTIVE=1
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

# Lane header, so MANIFEST / LIVE / EXPORT stay visually distinct on screen.
lane() {
  echo
  echo "-- $1 --------------------------------------------------------"
}

# Path relative to the repo root, for compact display.
rel() { echo "${1#"$REPO_ROOT"/}"; }

# MANIFEST lane: print a snippet of a repo file with REAL line numbers, located
# by searching for an anchor string rather than by hardcoding line numbers
# (which rot the moment anyone edits the template above them).
#   src <file> <anchor-regex> [lines-after]
src() {
  local file="$1" anchor="$2" after="${3:-12}" line
  if [ ! -f "$file" ]; then
    echo "  (missing file: $(rel "$file"))"
    return 0
  fi
  line=$(grep -nE -m1 -- "$anchor" "$file" 2>/dev/null | cut -d: -f1 || true)
  if [ -z "$line" ]; then
    echo "  (anchor '$anchor' not found in $(rel "$file"))"
    return 0
  fi
  echo "  $(rel "$file"):$line"
  sed -n "${line},$((line + after))p" "$file" | nl -ba -v"$line" -w6 -s' | '
  echo
}

# LIVE lane: echo the command exactly as it will run, then run it. Use this for
# anything without shell metacharacters.
#
# Arguments containing whitespace or shell metacharacters are re-quoted in the
# echoed line, so what's printed can be copy-pasted into a terminal and behave
# identically. (A raw "$*" would print a multi-word psql -c argument as if it
# were several arguments -- readable, but a lie you can't paste.)
run() {
  local out="" a
  for a in "$@"; do
    case "$a" in
      *[[:space:]\'\"\$\;\&\|\<\>\(\)\*]*) out+=" '${a//\'/\'\\\'\'}'" ;;
      *) out+=" $a" ;;
    esac
  done
  echo "  \$$out"
  "$@" || echo "  (command exited non-zero: $?)"
  echo
}

# LIVE lane variant for commands that need a real shell (pipes, redirects,
# jsonpath with braces that would be confusing to quote through "$@").
shrun() {
  echo "  \$ $1"
  eval "$1" || echo "  (command exited non-zero: $?)"
  echo
}

# EXPORT lane: write a live object to docs/evidence/<name>.yaml.
#   snap <basename> <kubectl-args...>      (namespace is added automatically)
snap() {
  local out="$EXPORT_DIR/$1.yaml"; shift
  mkdir -p "$EXPORT_DIR"
  echo "  \$ kubectl -n $NS $* -o yaml > $(rel "$out")"
  if kubectl -n "$NS" "$@" -o yaml >"$out" 2>/dev/null; then
    echo "    wrote $(rel "$out") ($(wc -l <"$out" | tr -d ' ') lines)"
  else
    echo "    (export failed -- object not present?)"
    rm -f "$out"
  fi
}

# EXPORT lane, Secret-safe. `kubectl get secret -o yaml` would write base64
# credentials to a file inside the repo -- "Secrets committed in plaintext to
# git" is an automatic-fail condition in capstone-requirements.md §7. So for
# Secrets we export `describe` output instead: it lists key names and byte
# counts and never the values.
secret_snap() {
  local name="$1" out="$EXPORT_DIR/secret-$1.txt"
  mkdir -p "$EXPORT_DIR"
  echo "  \$ kubectl -n $NS describe secret $name > $(rel "$out")   # describe, NOT -o yaml: no values on disk"
  if kubectl -n "$NS" describe secret "$name" >"$out" 2>/dev/null; then
    echo "    wrote $(rel "$out") (key names + byte counts only)"
  else
    echo "    (export failed -- secret not present?)"
    rm -f "$out"
  fi
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
  mkdir -p "$EXPORT_DIR"
  echo "namespace: $NS   release: $RELEASE   exports: $(rel "$EXPORT_DIR")/"
}

# ---- step 1: pods + endpoints ---------------------------------------------

step1() {
  banner 1 "All Pods Running/Ready; Services have Endpoints" "N5, P1, O1, O2"

  lane "MANIFEST: a Deployment and its matching Service"
  echo "  The Service's selector must match the Pod template's labels, or the"
  echo "  Service ends up with zero endpoints. Both sides come from the same"
  echo "  _helpers.tpl function, so they cannot drift apart:"
  src "$REPO_ROOT/helm/veloshare/charts/rider/templates/service.yaml" '^spec:' 10
  src "$REPO_ROOT/helm/veloshare/templates/_helpers.tpl" 'veloshare.selectorLabels' 8

  lane "LIVE: cluster state"
  run kubectl -n "$NS" get pods -o wide
  run kubectl -n "$NS" get deploy,statefulset
  echo "  A Service with no backing Pod shows <none> in ENDPOINTS -- none should."
  echo "  Using EndpointSlice, not the v1 Endpoints API: the latter is deprecated"
  echo "  in v1.33+ and prints a warning, which would undercut O5."
  run kubectl -n "$NS" get endpointslices

  lane "EXPORT"
  snap "01-pods" get pods
  snap "01-deployments" get deploy
  snap "01-endpointslices" get endpointslices
}

# ---- step 2: ingress --------------------------------------------------------

step2() {
  banner 2 "Ingress routes to frontend and /api/healthz" "N2, N3, O5"

  lane "MANIFEST: two Ingress objects, three path rules"
  echo "  networking.k8s.io/v1 (N3 needs >=2 path rules to different backends;"
  echo "  O5 needs a current, non-deprecated API version):"
  src "$REPO_ROOT/helm/veloshare/templates/ingress.yaml" 'apiVersion:' 6
  echo "  '/' -> frontend, plus '/kibana' -> kibana when logging is enabled:"
  src "$REPO_ROOT/helm/veloshare/templates/ingress.yaml" 'paths:' 18
  echo "  '/api/healthz' -> rider lives in a SECOND Ingress object because the"
  echo "  rewrite-target annotation applies to every path in the object it is"
  echo "  set on (see the incident note in the file):"
  src "$REPO_ROOT/helm/veloshare/templates/ingress-api.yaml" 'annotations:' 3
  src "$REPO_ROOT/helm/veloshare/templates/ingress-api.yaml" '- path: /api/healthz' 8

  lane "LIVE: cluster state + real HTTP requests"
  run kubectl -n "$NS" get ingress -o wide
  echo "  Expect 200, served by frontend:"
  shrun "curl -sS -o /dev/null -w '  HTTP %{http_code}\n' $BASE_URL/"
  echo "  Expect {\"status\":\"ok\"} -- rewrite-target sends this to rider's /healthz:"
  shrun "curl -sS $BASE_URL/api/healthz; echo"

  lane "EXPORT"
  snap "02-ingress" get ingress
}

# ---- step 3: configmap / secret injection ----------------------------------

step3() {
  banner 3 "ConfigMap / Secret injection" "C1, C2"

  lane "MANIFEST: envFrom wiring"
  echo "  Templates only ever REFERENCE a Secret by name -- they never read or"
  echo "  render a credential, so 'helm template' emits zero Secrets:"
  src "$REPO_ROOT/helm/veloshare/charts/trip/templates/deployment.yaml" 'envFrom:' 8
  echo "  The Secrets themselves are created out-of-band from gitignored"
  echo "  env/*.env files (only *.env.template is committed):"
  src "$REPO_ROOT/scripts/apply-secrets.sh" 'create secret generic' 4

  lane "LIVE: cluster state"
  run kubectl -n "$NS" get configmap
  echo "  Names + types only -- VALUES are never printed:"
  run kubectl -n "$NS" get secret
  echo "  trip's envFrom: DB Secret + own ConfigMap + shared auth Secret:"
  shrun "kubectl -n $NS get deploy trip -o jsonpath='{range .spec.template.spec.containers[?(@.name==\"trip\")].envFrom[*]}  {.secretRef.name}{.configMapRef.name}{\"\n\"}{end}'"
  echo "  pricing's envFrom: ConfigMap only (stateless, needs no DB credential):"
  shrun "kubectl -n $NS get deploy pricing-blue -o jsonpath='{range .spec.template.spec.containers[?(@.name==\"pricing\")].envFrom[*]}  {.configMapRef.name}{\"\n\"}{end}'"
  echo "  'describe secret' shows key NAMES and byte counts, never the value:"
  shrun "kubectl -n $NS describe secret trip-db | sed -n '/^Data/,\$p'"
  echo "  Proof that the chart renders no Secret at all (expect 0):"
  shrun "echo \"  kind: Secret objects rendered by the chart: \$(helm template $RELEASE $REPO_ROOT/helm/veloshare -n $NS | grep -c '^kind: Secret' || true)\""

  lane "EXPORT"
  snap "03-configmap-trip" get configmap trip
  secret_snap "trip-db"
  secret_snap "veloshare-auth"
}

# ---- step 4: probes ---------------------------------------------------------

step4() {
  banner 4 "Probe behaviour" "O1, O2, O3"

  lane "MANIFEST: liveness + readiness on every long-running workload"
  src "$REPO_ROOT/helm/veloshare/charts/rider/templates/deployment.yaml" 'livenessProbe:' 16
  echo "  postgres uses an exec probe (pg_isready) rather than HTTP:"
  src "$REPO_ROOT/helm/veloshare/charts/postgres/templates/statefulset.yaml" 'readinessProbe:' 10

  lane "LIVE: cluster state"
  shrun "kubectl -n $NS get deploy rider -o jsonpath='{.spec.template.spec.containers[?(@.name==\"rider\")].livenessProbe}'; echo"
  shrun "kubectl -n $NS get deploy rider -o jsonpath='{.spec.template.spec.containers[?(@.name==\"rider\")].readinessProbe}'; echo"
  shrun "kubectl -n $NS get statefulset postgres -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}'; echo"
  echo "  O3 (startupProbe) is RECOMMENDED, not required. The only genuinely"
  echo "  slow starters are elasticsearch/kibana, which are off by default;"
  echo "  a standalone startup-probe lab lives at k8s/labs/probes-demo.yaml:"
  src "$REPO_ROOT/k8s/labs/probes-demo.yaml" 'startupProbe:' 8

  lane "EXPORT"
  snap "04-deploy-rider" get deploy rider
  snap "04-statefulset-postgres" get statefulset postgres

  lane "LIVE (destructive, self-healing): readiness gates the Endpoint"
  if confirm "delete the running rider Pod and watch its Service Endpoint drop, then reappear once the replacement Pod passes readiness?"; then
    local pod
    pod=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=rider -o jsonpath='{.items[0].metadata.name}')
    run kubectl -n "$NS" delete pod "$pod"
    echo "  rider endpoints right after the delete (may already be empty):"
    run kubectl -n "$NS" get endpointslices -l kubernetes.io/service-name=rider
    run kubectl -n "$NS" rollout status deploy/rider --timeout=90s
    echo "  rider endpoints once the new Pod passes its readiness probe:"
    run kubectl -n "$NS" get endpointslices -l kubernetes.io/service-name=rider
  fi
}

# ---- step 5: rolling update / blue-green -----------------------------------

step5() {
  banner 5 "Rolling update / blue-green switch" "P2, P3, D6"

  lane "MANIFEST: two colours of the real pricing service, one Service selector"
  echo "  The chart sets replicas + selector but no explicit 'strategy:' block,"
  echo "  so the Deployment takes the API default (RollingUpdate) -- confirmed"
  echo "  against the live object below rather than asserted here:"
  src "$REPO_ROOT/helm/veloshare/charts/pricing/templates/deployment.yaml" '^  replicas:' 6
  echo "  Blue/green runs on the REAL pricing service, not a placeholder: one"
  echo "  template body renders pricing-blue and pricing-green, sharing"
  echo "  app.kubernetes.io/name=pricing and differing only by 'color'."
  src "$REPO_ROOT/helm/veloshare/charts/pricing/values.yaml" '^blueGreen:' 10
  echo "  The Service selector is the switch -- it names the active colour:"
  src "$REPO_ROOT/helm/veloshare/charts/pricing/templates/service.yaml" '^  selector:' 5

  lane "LIVE: both colours, running genuinely different images"
  shrun "kubectl -n $NS get deploy -l app.kubernetes.io/name=pricing -o custom-columns=NAME:.metadata.name,COLOR:.metadata.labels.color,IMAGE:.spec.template.spec.containers[0].image,READY:.status.readyReplicas"
  echo "  Each colour reports its own baked-in APP_VERSION, so neither can lie"
  echo "  about which image it is running:"
  shrun "kubectl -n $NS exec deploy/pricing-blue  -c ambassador -- curl -sS --max-time 5 127.0.0.1:8080/version; echo"
  shrun "kubectl -n $NS exec deploy/pricing-green -c ambassador -- curl -sS --max-time 5 127.0.0.1:8080/version; echo"

  lane "LIVE: rollout strategy and history"
  echo "  The defaulted strategy, read back from the live object:"
  shrun "kubectl -n $NS get deploy pricing-blue -o jsonpath='{.spec.strategy}'; echo"
  run kubectl -n "$NS" rollout history deploy/pricing-blue

  lane "EXPORT"
  snap "05-deploy-pricing" get deploy pricing-blue
  snap "05-deploy-pricing-green" get deploy pricing-green

  lane "LIVE (destructive, self-healing): rolling update"
  if confirm "rolling-restart deploy/pricing-blue?"; then
    run kubectl -n "$NS" rollout restart deploy/pricing-blue
    run kubectl -n "$NS" rollout status deploy/pricing-blue --timeout=90s
    run kubectl -n "$NS" rollout history deploy/pricing-blue
  fi

  lane "LIVE (destructive): blue/green cutover on the live pricing Service"
  if confirm "flip Service pricing blue -> green -> blue (no Deployment is touched)?"; then
    shrun "kubectl -n $NS get svc pricing -o jsonpath='{.spec.selector}'; echo"
    snap "05-bluegreen-svc-before" get svc pricing
    echo "  which colour's Pod is actually behind the Service right now:"
    shrun "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=pricing -o jsonpath='{range .items[*].endpoints[*]}  {.targetRef.name}{\"\n\"}{end}'"
    echo "  through the Service, from a Pod the NetworkPolicy allows (expect 0.1.0):"
    shrun "kubectl -n $NS exec deploy/trip -c ambassador -- curl -sS --max-time 5 http://pricing/version; echo"
    echo "  ...and end to end through ingress-nginx -> frontend -> pricing:"
    shrun "curl -sS --max-time 5 http://localhost/api/pricing/version; echo"

    echo "  the cutover -- one selector patch, no Pod touched:"
    run kubectl -n "$NS" patch svc pricing -p '{"spec":{"selector":{"color":"green"}}}'
    snap "05-bluegreen-svc-after" get svc pricing
    sleep 2
    shrun "kubectl -n $NS get endpointslices -l kubernetes.io/service-name=pricing -o jsonpath='{range .items[*].endpoints[*]}  {.targetRef.name}{\"\n\"}{end}'"
    echo "  same two requests again -- same Service, same DNS name, new version:"
    shrun "kubectl -n $NS exec deploy/trip -c ambassador -- curl -sS --max-time 5 http://pricing/version; echo"
    shrun "curl -sS --max-time 5 http://localhost/api/pricing/version; echo"

    echo "  rollback is the same patch in reverse -- this is why blue/green beats"
    echo "  a rolling update when you need an instant, complete undo:"
    run kubectl -n "$NS" patch svc pricing -p '{"spec":{"selector":{"color":"blue"}}}'
    sleep 2
    shrun "curl -sS --max-time 5 http://localhost/api/pricing/version; echo"
  fi
}

# ---- step 6: HPA -------------------------------------------------------------

step6() {
  banner 6 "HPA object present and computing metrics" "P4"

  lane "MANIFEST: HorizontalPodAutoscaler"
  echo "  autoscaling/v2 (the v2beta* versions are removed -- O5):"
  src "$REPO_ROOT/helm/veloshare/charts/pricing/templates/hpa.yaml" 'apiVersion:' 8
  src "$REPO_ROOT/helm/veloshare/charts/pricing/templates/hpa.yaml" 'metrics:' 12

  lane "LIVE: cluster state"
  echo "  TARGETS must show a real percentage, not '<unknown>'. If it reads"
  echo "  <unknown>, metrics-server is missing -- run 'make metrics-server'."
  run kubectl -n "$NS" get hpa
  echo "  In 'describe', the line that matters is Conditions: ScalingActive=True"
  echo "  with reason ValidMetricFound. The Events list may still carry older"
  echo "  FailedGetResourceMetric warnings from before metrics-server was"
  echo "  installed -- check their Age; they age out on their own."
  run kubectl -n "$NS" describe hpa pricing
  echo "  The metric source the HPA reads (also powers 'kubectl top'):"
  run kubectl -n "$NS" top pods

  lane "EXPORT"
  snap "06-hpa-pricing" get hpa pricing
}

# ---- step 7: NetworkPolicy ---------------------------------------------------

step7() {
  banner 7 "NetworkPolicy: allowed vs. denied path" "N4"

  lane "MANIFEST: a real namespace default-deny, plus scoped allow-policies"
  echo "  podSelector: {} selects EVERY Pod in the namespace, both policyTypes"
  echo "  are named, and there are NO rules at all -- so the starting position"
  echo "  for any Pod here, including one applied by hand, is 'no network':"
  src "$REPO_ROOT/helm/veloshare/templates/networkpolicy-default-deny.yaml" '^spec:' 6
  echo "  Policies are additive, so each allow-policy is an exception to that"
  echo "  baseline. The backend one: ingress-nginx, frontend and backend peers"
  echo "  only, on the ambassador/app ports:"
  src "$REPO_ROOT/helm/veloshare/templates/networkpolicy-backend.yaml" '^  ingress:' 20
  echo "  DNS has to be namespace-wide -- a Pod that cannot resolve 'rider'"
  echo "  cannot use the policy that permits reaching it either:"
  src "$REPO_ROOT/helm/veloshare/templates/networkpolicy-allow-dns.yaml" '^  egress:' 12

  lane "LIVE: cluster state"
  run kubectl -n "$NS" get networkpolicy
  echo "  the default-deny really does carry no rules:"
  shrun "kubectl -n $NS get netpol default-deny -o jsonpath='{.spec}'; echo"

  lane "EXPORT"
  snap "07-networkpolicy" get networkpolicy

  lane "LIVE: the actual allowed-vs-denied proof"
  echo "  DENIED -- throwaway pod with a non-matching label calling rider."
  echo "  Expect a timeout: no allow-policy names this Pod, so the default-deny"
  echo "  is all that applies to it -- in BOTH directions."
  run kubectl -n "$NS" run probe-denied --rm -i --restart=Never --image=curlimages/curl \
    --labels=app.kubernetes.io/name=probe -- curl -sS --max-time 5 http://rider/healthz
  echo "  ALLOWED -- same image, same URL, only the LABEL differs. Expect 200:"
  echo "  two policies have to agree for this to work at all -- rider's ingress"
  echo "  allows from name=frontend, and frontend-isolation allows egress to the"
  echo "  backends. Both match on the label, not on which image is running."
  run kubectl -n "$NS" run probe-allowed --rm -i --restart=Never --image=curlimages/curl \
    --labels=app.kubernetes.io/name=frontend -- curl -sS --max-time 5 http://rider/healthz
  echo "  DENIED (egress) -- the same allowed pod cannot reach the internet:"
  echo "  no policy in this namespace permits 0.0.0.0/0 except the RBAC CronJob's,"
  echo "  and that one is restricted to the API server's ports."
  run kubectl -n "$NS" run probe-egress --rm -i --restart=Never --image=curlimages/curl \
    --labels=app.kubernetes.io/name=frontend -- curl -sS --max-time 5 https://example.com
}

# ---- step 8: PVC persistence -------------------------------------------------

step8() {
  banner 8 "PVC persistence across Pod delete/recreate" "D5"

  lane "MANIFEST: volumeClaimTemplate"
  echo "  A StatefulSet volumeClaimTemplate gives each replica its own PVC that"
  echo "  survives the Pod -- deleting the Pod does not delete the claim:"
  src "$REPO_ROOT/helm/veloshare/charts/postgres/templates/statefulset.yaml" 'volumeClaimTemplates:' 14

  lane "LIVE: cluster state"
  run kubectl -n "$NS" get pvc
  run kubectl -n "$NS" get pv

  lane "EXPORT"
  snap "08-pvc" get pvc

  lane "LIVE (destructive, self-healing): write, kill the Pod, re-read"
  local marker
  marker="demo-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "  Writing a marker row into public.pvc_demo (its own table, separate"
  echo "  from every app schema):"
  run kubectl -n "$NS" exec postgres-0 -- psql -U postgres -d veloshare -c \
    "CREATE TABLE IF NOT EXISTS public.pvc_demo (id serial PRIMARY KEY, note text, created_at timestamptz DEFAULT now()); INSERT INTO public.pvc_demo (note) VALUES ('$marker');"
  run kubectl -n "$NS" exec postgres-0 -- psql -U postgres -d veloshare -c "SELECT * FROM public.pvc_demo ORDER BY id;"
  if confirm "delete pod/postgres-0 so the StatefulSet recreates it, then re-read the marker row from the same PVC?"; then
    run kubectl -n "$NS" delete pod postgres-0
    run kubectl -n "$NS" wait --for=condition=Ready pod/postgres-0 --timeout=120s
    echo "  Marker row after recreate -- still present means the PVC's data"
    echo "  outlived the Pod:"
    run kubectl -n "$NS" exec postgres-0 -- psql -U postgres -d veloshare -c "SELECT * FROM public.pvc_demo ORDER BY id;"
  fi
}

# ---- step 9: helm rollback / kustomize overlay -------------------------------

step9() {
  banner 9 "Helm history/rollback and Kustomize overlay apply" "P5, P6"

  lane "MANIFEST: umbrella chart and Kustomize overlays"
  echo "  The umbrella chart declares every service as a subchart dependency:"
  src "$REPO_ROOT/helm/veloshare/Chart.yaml" 'dependencies:' 10
  echo "  The REAL overlays, over the real services: k8s/base is generated from"
  echo "  that same chart by scripts/gen-k8s.sh, and prod patches image tag,"
  echo "  replicas, AND the namespace quota (a strategic-merge patch):"
  src "$REPO_ROOT/k8s/overlays/prod/kustomization.yaml" '^images:' 6
  src "$REPO_ROOT/k8s/overlays/prod/kustomization.yaml" '^replicas:' 4
  src "$REPO_ROOT/k8s/overlays/prod/resourcequota-patch.yaml" '^spec:' 7
  echo "  The version string is baked into the image at build time, so a Pod"
  echo "  cannot misreport which image it is running:"
  src "$REPO_ROOT/services/pricing/Dockerfile" '^ARG APP_VERSION' 2

  lane "LIVE: Helm release history"
  run helm -n "$NS" history "$RELEASE"

  lane "EXPORT"
  shrun "helm -n $NS get manifest $RELEASE > $(rel "$EXPORT_DIR")/09-helm-manifest.yaml && echo '    wrote $(rel "$EXPORT_DIR")/09-helm-manifest.yaml'"
  shrun "helm -n $NS get values $RELEASE --all > $(rel "$EXPORT_DIR")/09-helm-values.yaml && echo '    wrote $(rel "$EXPORT_DIR")/09-helm-values.yaml'"
  echo "  Both overlays rendered, no cluster needed:"
  shrun "kubectl kustomize $REPO_ROOT/k8s/overlays/dev  > $(rel "$EXPORT_DIR")/09-kustomize-dev.yaml && echo '    wrote $(rel "$EXPORT_DIR")/09-kustomize-dev.yaml'"
  shrun "kubectl kustomize $REPO_ROOT/k8s/overlays/prod > $(rel "$EXPORT_DIR")/09-kustomize-prod.yaml && echo '    wrote $(rel "$EXPORT_DIR")/09-kustomize-prod.yaml'"
  echo "  What the two overlays actually change (the whole point of P5) --"
  echo "  image tag, replica counts, and the namespace ResourceQuota:"
  shrun "diff $(rel "$EXPORT_DIR")/09-kustomize-dev.yaml $(rel "$EXPORT_DIR")/09-kustomize-prod.yaml | grep -E '^[<>].*(image:|replicas:|cpu|memory|pods)' || true"
  echo "  Only pricing is pinned per-environment, and both tags really exist:"
  shrun "docker images --format '  {{.Repository}}:{{.Tag}}' | grep veloshare/pricing || echo '  (run: make images-demo-tag)'"
  echo "  Which image the RUNNING Pod actually has, straight from the container:"
  shrun "kubectl -n $NS get deploy pricing-blue -o jsonpath='  spec image: {.spec.template.spec.containers[0].image}{\"\n\"}'"
  run kubectl -n "$NS" exec deploy/pricing-blue -c ambassador -- curl -sS --max-time 5 http://127.0.0.1:8080/version

  lane "LIVE (destructive, restored after): Helm rollback"
  local current_rev prev_rev
  current_rev=$(helm -n "$NS" history "$RELEASE" -o json 2>/dev/null | grep -o '"revision":[0-9]*' | grep -o '[0-9]*' | tail -1 || true)
  if [ -z "$current_rev" ] || [ "$current_rev" -le 1 ]; then
    echo "  Only one revision on record -- nothing to roll back to yet."
    echo "  (run 'make deploy' again to create revision 2, then re-run this step)"
  else
    prev_rev=$((current_rev - 1))
    if confirm "roll back '$RELEASE' from revision $current_rev to $prev_rev, show it took effect, then roll forward again to restore revision $current_rev's content?"; then
      run helm -n "$NS" rollback "$RELEASE" "$prev_rev" --wait --timeout 3m
      run helm -n "$NS" history "$RELEASE"
      echo "  restoring: rolling forward again to revision $current_rev's content:"
      run helm -n "$NS" rollback "$RELEASE" "$current_rev" --wait --timeout 3m
      run helm -n "$NS" history "$RELEASE"
    fi
  fi

  lane "LIVE (destructive): Kustomize base -> overlay, applied for real"
  echo "  This APPLIES the standalone lab in k8s/labs/kustomize-demo/, not the"
  echo "  real k8s/overlays/ shown above. Applying the real overlays here would"
  echo "  put kubectl and the running Helm release in charge of the same objects"
  echo "  -- exactly what scripts/deploy.sh refuses to allow. The lab overlays a"
  echo "  throwaway public-image Deployment, so it demonstrates the same"
  echo "  base -> overlay mechanics with nothing to fight over."
  if confirm "apply the lab's Kustomize base, then its 'prod' overlay (replicas: 3, pinned tag, bigger resources), then delete both to restore the original (empty) state?"; then
    run kubectl apply -k "$REPO_ROOT/k8s/labs/kustomize-demo/base"
    run kubectl -n "$NS" rollout status deploy/kustomize-demo-app --timeout=60s
    echo "  base:"
    shrun "kubectl -n $NS get deploy kustomize-demo-app -o jsonpath='  replicas={.spec.replicas}  image={.spec.template.spec.containers[0].image}{\"\n\"}'"
    run kubectl apply -k "$REPO_ROOT/k8s/labs/kustomize-demo/overlays/prod"
    run kubectl -n "$NS" rollout status deploy/kustomize-demo-app --timeout=120s
    echo "  prod overlay:"
    shrun "kubectl -n $NS get deploy kustomize-demo-app -o jsonpath='  replicas={.spec.replicas}  image={.spec.template.spec.containers[0].image}{\"\n\"}'"
    echo "  restoring: removing the demo objects:"
    run kubectl delete -k "$REPO_ROOT/k8s/labs/kustomize-demo/overlays/prod"
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
  echo "   exports: $(rel "$EXPORT_DIR")/"
fi

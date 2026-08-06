#!/usr/bin/env bash
# Deploy VeloShare into the cluster by EITHER path: Helm, or raw kubectl.
#
# capstone-requirements.md §6.1 asks for scripts/deploy.sh that applies
# "Kustomize/Helm into namespace". Both paths describe the same platform --
# k8s/ is generated from helm/veloshare by scripts/gen-k8s.sh -- but they are
# ALTERNATIVES, not layers.
#
# WHY THIS SCRIPT REFUSES TO MIX THEM
# -----------------------------------
# Helm and kubectl each believe they own the objects they create. Install the
# chart over a kubectl-applied namespace and Helm adopts (or fights over)
# resources it did not create; apply k8s/ over a Helm release and the next
# `helm upgrade` reverts your changes, or `helm uninstall` deletes objects the
# raw path still expects. Neither failure is loud. So: pick one, and this
# script blocks the other until you tear the first one down.
#
# Usage:
#   scripts/deploy.sh helm                 helm upgrade --install (default)
#   scripts/deploy.sh kubectl              kubectl apply -k k8s/overlays/dev
#   scripts/deploy.sh kubectl prod         kubectl apply -k k8s/overlays/prod
#   scripts/deploy.sh helm --set k=v ...   extra args pass through to helm
#   FORCE=1 scripts/deploy.sh kubectl      skip the ownership check (you asked)
#
# Env: NAMESPACE (default veloshare), RELEASE (default veloshare).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NAMESPACE="${NAMESPACE:-veloshare}"
RELEASE="${RELEASE:-veloshare}"
CHART="${CHART:-$REPO_ROOT/helm/veloshare}"

MODE="${1:-helm}"
[ $# -gt 0 ] && shift

helm_release_exists() {
  helm -n "$NAMESPACE" list -a -q 2>/dev/null | grep -qx "$RELEASE"
}

# A kubectl-applied platform leaves no release record, so we detect it the way a
# human would: core objects present in the namespace that Helm does not claim.
kubectl_owned_objects_exist() {
  local mgr
  mgr=$(kubectl -n "$NAMESPACE" get deploy rider \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
  # rider exists, and is NOT labelled managed-by: Helm -> raw path owns it.
  kubectl -n "$NAMESPACE" get deploy rider >/dev/null 2>&1 && [ "$mgr" != "Helm" ]
}

require_secrets() {
  # Neither path renders a credential; both need `make secrets` to have run.
  local missing=()
  for s in postgres rider-db station-db trip-db veloshare-auth; do
    kubectl -n "$NAMESPACE" get secret "$s" >/dev/null 2>&1 || missing+=("$s")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "warning: missing Secret(s) in $NAMESPACE: ${missing[*]}" >&2
    echo "         Pods will stay in CreateContainerConfigError until you run:" >&2
    echo "           make env-init   # once, then edit env/*.env" >&2
    echo "           make secrets" >&2
    echo >&2
  fi
}

case "$MODE" in
  helm)
    if [ "${FORCE:-0}" != "1" ] && kubectl_owned_objects_exist; then
      cat >&2 <<EOF
error: this namespace already holds a kubectl/Kustomize-deployed VeloShare.

  Installing the chart on top would make Helm adopt objects it did not create.
  Tear the raw path down first:

      kubectl delete -k k8s/overlays/dev      # or overlays/prod

  Then re-run: scripts/deploy.sh helm
  (Override with FORCE=1 if you know what you are doing.)
EOF
      exit 1
    fi
    kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 && require_secrets
    echo "==> helm upgrade --install $RELEASE $CHART -n $NAMESPACE"
    helm lint "$CHART"
    helm upgrade --install "$RELEASE" "$CHART" -n "$NAMESPACE" --create-namespace "$@"
    echo
    echo "Deployed via Helm. History: helm -n $NAMESPACE history $RELEASE"
    ;;

  kubectl|kustomize)
    OVERLAY="${1:-dev}"
    [ $# -gt 0 ] && shift
    DIR="$REPO_ROOT/k8s/overlays/$OVERLAY"
    if [ ! -d "$DIR" ]; then
      echo "error: no such overlay: k8s/overlays/$OVERLAY (have: $(ls "$REPO_ROOT/k8s/overlays" | tr '\n' ' '))" >&2
      exit 1
    fi
    if [ "${FORCE:-0}" != "1" ] && helm_release_exists; then
      cat >&2 <<EOF
error: Helm release '$RELEASE' already owns namespace '$NAMESPACE'.

  Applying k8s/ on top would leave two owners for the same objects: the next
  'helm upgrade' would revert this apply, and 'helm uninstall' would delete
  resources the raw path still expects. Remove the release first:

      helm uninstall $RELEASE -n $NAMESPACE

  Then re-run: scripts/deploy.sh kubectl $OVERLAY
  (Override with FORCE=1 if you know what you are doing.)
EOF
      exit 1
    fi
    kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 && require_secrets
    echo "==> kubectl apply -k k8s/overlays/$OVERLAY"
    kubectl apply -k "$DIR" "$@"
    echo
    echo "Deployed via kubectl/Kustomize (overlay: $OVERLAY)."
    echo "Watch it settle: kubectl -n $NAMESPACE get pods -w"
    ;;

  -h|--help)
    sed -n '2,25p' "$0"
    exit 0
    ;;

  *)
    echo "error: unknown mode '$MODE' (expected: helm | kubectl)" >&2
    exit 1
    ;;
esac

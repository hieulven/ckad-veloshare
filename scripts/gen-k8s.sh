#!/usr/bin/env bash
# Regenerate k8s/ (the raw-manifest deploy path) from the Helm chart.
#
# WHY THIS EXISTS
# ---------------
# capstone-requirements.md §6.1 asks for a k8s/ tree (base + overlays + network
# /security/quota/storage) alongside helm/. Hand-maintaining both would mean two
# sources of truth that silently drift. Instead, `helm template` IS the source of
# truth and this script splits its output into the §6.1 directory layout, so the
# two deploy paths always describe the same platform.
#
# Regenerate after ANY chart change:
#     scripts/gen-k8s.sh        (or: make gen-k8s)
#
# What it rewrites on the way through:
#   - drops `app.kubernetes.io/managed-by: Helm` and `helm.sh/chart:` labels --
#     these objects are not managed by Helm on this path, and claiming otherwise
#     would confuse both humans and `helm` itself.
#   - drops the Helm-injected `app.kubernetes.io/version` (chart appVersion) --
#     kept out so the raw path has no chart-derived metadata at all.
#
# Secrets are NOT part of either path: they come from gitignored env/*.env via
# `scripts/apply-secrets.sh` in both cases. See README "Prerequisites".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RELEASE="${RELEASE:-veloshare}"
NAMESPACE="${NAMESPACE:-veloshare}"
CHART="${CHART:-$REPO_ROOT/helm/veloshare}"
OUT="${OUT:-$REPO_ROOT/k8s}"

command -v helm >/dev/null || { echo "error: helm not found in PATH" >&2; exit 1; }

echo "rendering $CHART -> $OUT/"
helm template "$RELEASE" "$CHART" -n "$NAMESPACE" \
  | OUT="$OUT" NAMESPACE="$NAMESPACE" python3 "$SCRIPT_DIR/gen-k8s.py"

echo
echo "validating the generated tree with kubectl kustomize ..."
for d in base overlays/dev overlays/prod; do
  if kubectl kustomize "$OUT/$d" >/dev/null; then
    echo "  ok  k8s/$d"
  else
    echo "  FAILED  k8s/$d" >&2
    exit 1
  fi
done
echo
echo "done. Deploy the raw path with: scripts/deploy.sh kubectl [dev|prod]"

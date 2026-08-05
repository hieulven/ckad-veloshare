#!/usr/bin/env bash
# Applies env/*.env to the cluster as per-service Secrets — never via Helm
# or git (see CLAUDE.md "Secrets"). Each file becomes exactly one Secret,
# applied with --dry-run=client | kubectl apply so re-running this after
# editing an env file updates the Secret in place instead of failing on
# "already exists".
#
# Usage: scripts/apply-secrets.sh
# Env overrides: NAMESPACE, ENV_DIR (match the Makefile's own defaults).
set -euo pipefail

NAMESPACE="${NAMESPACE:-veloshare}"
ENV_DIR="${ENV_DIR:-env}"

# secret-name:env-file pairs — keep in sync with CLAUDE.md's secrets table.
MAPPINGS=(
  "postgres:postgres.env"
  "rider-db:rider.env"
  "station-db:station.env"
  "trip-db:trip.env"
  "veloshare-auth:auth.env"
)

missing=0
for m in "${MAPPINGS[@]}"; do
  f="${m#*:}"
  [ -f "$ENV_DIR/$f" ] || { echo "missing $ENV_DIR/$f"; missing=1; }
done
if [ "$missing" -ne 0 ]; then
  echo "-> run 'make env-init' to create them from the templates, then edit the values"
  exit 1
fi

if grep -rlqE '^[A-Za-z_][A-Za-z0-9_]*=change-me' "$ENV_DIR"/*.env 2>/dev/null; then
  echo "refusing: these $ENV_DIR/*.env values are still template placeholders:"
  grep -rnE '^[A-Za-z_][A-Za-z0-9_]*=change-me' "$ENV_DIR"/*.env | sed 's/^/    /'
  exit 1
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

for m in "${MAPPINGS[@]}"; do
  name="${m%%:*}"
  file="${m#*:}"
  kubectl -n "$NAMESPACE" create secret generic "$name" \
    --from-env-file="$ENV_DIR/$file" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "  secret/$name <- $ENV_DIR/$file"
done

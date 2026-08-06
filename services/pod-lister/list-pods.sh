#!/bin/bash
set -euo pipefail

# CKAD demo: talk to the Kubernetes API server directly with this Pod's
# mounted ServiceAccount token, instead of going through a kubectl binary,
# so the SA-token -> Authorization header -> API call chain is visible.
SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
NAMESPACE=$(cat "$SA_DIR/namespace")
API_SERVER="https://kubernetes.default.svc"

echo "--- $(date -u +%Y-%m-%dT%H:%M:%SZ) pods in ${NAMESPACE} (via SA token) ---"
response=$(curl -sS --cacert "$SA_DIR/ca.crt" \
  -H "Authorization: Bearer $(cat "$SA_DIR/token")" \
  "${API_SERVER}/api/v1/namespaces/${NAMESPACE}/pods")
summary=$(echo "$response" | jq -r '.items[]? | "  \(.metadata.name)\t\(.status.phase)"' 2>/dev/null || true)
if [ -n "$summary" ]; then
  printf '%s\n' "$summary"
else
  echo "  (unexpected response: $(echo "$response" | jq -r '.message // "could not parse body"' 2>/dev/null))"
fi

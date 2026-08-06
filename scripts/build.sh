#!/usr/bin/env bash
# Build and tag every service image, then load it into the kind cluster.
#
# capstone-requirements.md §6.1 asks for scripts/build.sh; this is that entry
# point. `make images` / `make load` call the same docker/kind commands.
#
# Usage:
#   scripts/build.sh                 build + load every service
#   scripts/build.sh rider trip      build + load only these
#   NO_LOAD=1 scripts/build.sh       build only, skip `kind load`
#
# Env: REGISTRY (default veloshare), TAG (default 0.1.0), CLUSTER (default
# veloshare). The tag is deliberately explicit and never `:latest` -- §3.2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REGISTRY="${REGISTRY:-veloshare}"
TAG="${TAG:-0.1.0}"
CLUSTER="${CLUSTER:-veloshare}"

ALL_SERVICES="pricing rider station trip fleet-monitor frontend pod-lister"
SERVICES=("$@")
[ ${#SERVICES[@]} -eq 0 ] && read -r -a SERVICES <<<"$ALL_SERVICES"

command -v docker >/dev/null || { echo "error: docker not found in PATH" >&2; exit 1; }
if [ "${NO_LOAD:-0}" != "1" ]; then
  command -v kind >/dev/null || { echo "error: kind not found in PATH (use NO_LOAD=1 to build only)" >&2; exit 1; }
fi

for svc in "${SERVICES[@]}"; do
  ctx="$REPO_ROOT/services/$svc"
  if [ ! -d "$ctx" ]; then
    echo "error: no such service: services/$svc" >&2
    exit 1
  fi
  echo "==> building $REGISTRY/$svc:$TAG  (context: services/$svc)"
  # APP_VERSION is passed to every service so the tag and the version a container
  # reports can never disagree. Dockerfiles that declare no such ARG simply
  # ignore it (docker warns, harmlessly); today only pricing consumes it, via
  # GET /version. Doing it uniformly means adding /version to another service is
  # a one-line Dockerfile change, not a build-script change.
  docker build --build-arg "APP_VERSION=$TAG" -t "$REGISTRY/$svc:$TAG" "$ctx"
done

if [ "${NO_LOAD:-0}" = "1" ]; then
  echo "NO_LOAD=1 -- skipping 'kind load'."
  exit 0
fi

# kind nodes have their own image store: a freshly built image is invisible to
# the cluster until it is loaded. And because the tag never changes (0.1.0),
# Kubernetes will not notice new bits on its own -- restart the workload after
# loading. See README "Build & deploy".
for svc in "${SERVICES[@]}"; do
  echo "==> loading $REGISTRY/$svc:$TAG into kind cluster '$CLUSTER'"
  kind load docker-image "$REGISTRY/$svc:$TAG" --name "$CLUSTER"
done

echo
echo "Built and loaded: ${SERVICES[*]}"
echo "The image tag did not change, so running Pods still use the old layers."
echo "Roll them to pick up the new build, e.g.:"
for svc in "${SERVICES[@]}"; do
  case "$svc" in
    fleet-monitor|pod-lister) echo "  (CronJob '$svc' picks it up on its next scheduled run)" ;;
    *) echo "  kubectl -n veloshare rollout restart deploy/$svc" ;;
  esac
done

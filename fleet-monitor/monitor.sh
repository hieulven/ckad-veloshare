#!/usr/bin/env bash
# fleet-monitor — polls each service's /healthz and flags dead ones.
# Runs as a CronJob (*/5 * * * *). See CLAUDE.md.
set -euo pipefail

TARGETS="${TARGETS:-pricing rider station trip}"

failures=0

for target in $TARGETS; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://${target}.veloshare.svc.cluster.local/healthz" || echo "000")

  if [ "$code" = "200" ]; then
    echo "OK ${target}"
  else
    echo "DEAD ${target} (${code})"
    failures=$((failures + 1))
  fi
done

if [ "$failures" -gt 0 ]; then
  echo "fleet-monitor: ${failures} dead target(s)"
  exit 1
fi

echo "fleet-monitor: all targets healthy"

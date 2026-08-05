#!/usr/bin/env bash
# Seeds VeloShare with demo data: a handful of stations, one rider per tier,
# and a couple of completed trips — so the dashboard, fleet-monitor's daily
# report, and Kibana all have something real to show instead of being empty.
#
# Goes through http://localhost/api/* — the same path the real frontend
# uses (ingress -> frontend -> service) — rather than calling a backend
# directly, so it exercises the real request path and needs no in-cluster
# access of its own.
#
# Idempotent for stations/riders (skips anything that already exists by
# name/email); the trip section is NOT idempotent — each run starts and
# completes one more trip per seeded rider, which is intentional (more
# history for the report) but means trip counts grow on repeated runs.
#
# Usage: scripts/seed-data.sh
# Env override: BASE_URL (default http://localhost)
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost}"

# grep -o exits 1 on zero matches, which is a normal outcome here (e.g. no
# stations yet) — `|| true` keeps that from tripping `set -e -o pipefail`.
ids_from() { grep -o '"id":[0-9]*' | grep -o '[0-9]*' || true; }

# ---- stations ----------------------------------------------------------
echo "== stations =="
existing_station_count=$(curl -sf "$BASE_URL/api/stations/stations" | ids_from | wc -l)
if [ "$existing_station_count" -gt 0 ]; then
  echo "  $existing_station_count already present, skipping creation"
else
  for row in \
    "Downtown Hub:20" \
    "Riverside Park:12" \
    "University Ave:15" \
    "Central Station:25" \
    "Harbor View:10"
  do
    name="${row%%:*}"
    capacity="${row##*:}"
    curl -sf -X POST "$BASE_URL/api/stations/stations" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"$name\",\"capacity\":$capacity}" >/dev/null
    echo "  created: $name (capacity $capacity)"
  done
fi
station_ids=($(curl -sf "$BASE_URL/api/stations/stations" | ids_from))
echo "  station ids on hand: ${station_ids[*]}"

# ---- riders --------------------------------------------------------------
echo "== riders =="
# name -> email:tier:password (must be a valid pricing tier, see
# pricing.fare.tierRatesJson: standard/member/day_pass)
declare -A RIDERS=(
  ["Alice Nguyen"]="alice@example.com:standard:pass1234"
  ["Binh Tran"]="binh@example.com:member:pass1234"
  ["Chi Le"]="chi@example.com:day_pass:pass1234"
)

existing_emails=$(curl -sf "$BASE_URL/api/riders/riders" | grep -o '"email":"[^"]*"' | sed 's/"email":"//;s/"$//' || true)

for name in "${!RIDERS[@]}"; do
  IFS=':' read -r email tier password <<< "${RIDERS[$name]}"
  if echo "$existing_emails" | grep -qx "$email"; then
    echo "  $email already exists, skipping"
    continue
  fi
  curl -sf -X POST "$BASE_URL/api/riders/riders" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$name\",\"email\":\"$email\",\"tier\":\"$tier\",\"password\":\"$password\"}" >/dev/null
  echo "  created: $name <$email> ($tier)"
done

# ---- a couple of completed trips ------------------------------------------
echo "== trips =="
if [ "${#station_ids[@]}" -lt 2 ]; then
  echo "  fewer than 2 stations on hand, skipping trip seeding"
else
  start_station="${station_ids[0]}"
  end_station="${station_ids[1]}"
  for name in "${!RIDERS[@]}"; do
    IFS=':' read -r email tier password <<< "${RIDERS[$name]}"
    token=$(curl -sf -X POST "$BASE_URL/api/riders/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"$email\",\"password\":\"$password\"}" \
      | grep -o '"access_token":"[^"]*"' | sed 's/"access_token":"//;s/"$//' || true)
    if [ -z "$token" ]; then
      echo "  $email: login failed, skipping trip"
      continue
    fi
    # trip's response uses "trip_id", not "id" (unlike stations/riders) —
    # ids_from() would silently find nothing here.
    trip_id=$(curl -sf -X POST "$BASE_URL/api/trips/trips/start" \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      -d "{\"station_id\":$start_station,\"tier\":\"$tier\"}" \
      | grep -o '"trip_id":[0-9]*' | grep -o '[0-9]*' || true)
    if [ -z "$trip_id" ]; then
      echo "  $email: could not start trip (already has an active one?), skipping"
      continue
    fi
    curl -sf -X POST "$BASE_URL/api/trips/trips/$trip_id/end" \
      -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      -d "{\"end_station_id\":$end_station}" >/dev/null
    echo "  $email: completed trip #$trip_id ($start_station -> $end_station)"
  done
fi

echo "== done =="

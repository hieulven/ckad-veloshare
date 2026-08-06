#!/usr/bin/env bash
# usage-report — bao cao chi so nguoi dung / nghiep vu cua VeloShare cho quan ly.
#
# Doc so lieu tong hop tren TAT CA schema (voi quyen postgres admin — day la mot
# job bao cao, khong phai service, nen viec doc cheo schema la hop le) va in bao
# cao ra stdout. Chay hang ngay (0 0 * * *); kich hoat thu cong bat ky luc nao:
#   kubectl -n veloshare create job --from=cronjob/fleet-monitor report-now
#   kubectl -n veloshare logs job/report-now
#
# (Nhan dieu chinh: nhan chu khong dau de can le on dinh trong log/alpine LANG=C.)
set -euo pipefail

: "${POSTGRES_USER:?POSTGRES_USER chua duoc set (Secret postgres)}"
: "${POSTGRES_DB:?POSTGRES_DB chua duoc set (Secret postgres)}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD chua duoc set (Secret postgres)}"
export PGPASSWORD="$POSTGRES_PASSWORD"
DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"

psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
     -v ON_ERROR_STOP=1 --no-psqlrc -P border=2 -P footer=off <<'SQL'
\echo ''
\echo '=================================================================='
\echo '   VELOSHARE — BAO CAO CHI SO NGUOI DUNG (cho quan ly)'
\echo '=================================================================='
SELECT to_char(now(), 'YYYY-MM-DD HH24:MI') AS "Thoi diem tao bao cao";

\echo ''
\echo '--- NGUOI DUNG ---'
SELECT count(*) AS "Tong nguoi dung" FROM riders.riders;
SELECT tier AS "Hang", count(*) AS "So luong"
FROM riders.riders GROUP BY tier ORDER BY count(*) DESC;

\echo ''
\echo '--- TRAM & CHO DO ---'
SELECT count(*) AS "So tram",
       coalesce(sum(capacity), 0) AS "Tong suc chua",
       coalesce(sum(docks_available), 0) AS "Cho trong hien tai"
FROM stations.stations;

\echo ''
\echo '--- CHUYEN DI ---'
SELECT count(*) AS "Tong chuyen",
       count(*) FILTER (WHERE status = 'completed')                 AS "Hoan tat",
       count(*) FILTER (WHERE status = 'active')                    AS "Dang chay",
       count(*) FILTER (WHERE started_at::date = current_date)      AS "Bat dau hom nay"
FROM trips.trips;

\echo ''
\echo '--- DOANH THU (chuyen da hoan tat) ---'
SELECT '$' || to_char(coalesce(sum(fare_cents), 0) / 100.0, 'FM999,999,990.00') AS "Doanh thu luy ke",
       '$' || to_char(coalesce(sum(fare_cents) FILTER (WHERE ended_at::date = current_date), 0) / 100.0, 'FM999,999,990.00') AS "Doanh thu hom nay",
       '$' || to_char(coalesce(avg(fare_cents), 0) / 100.0, 'FM990.00') AS "Cuoc trung binh",
       round(coalesce(avg(extract(epoch FROM (ended_at - started_at)) / 60.0), 0)::numeric, 1) AS "Thoi luong TB (phut)"
FROM trips.trips WHERE status = 'completed';

\echo ''
\echo '--- THEO HANG THANH VIEN ---'
SELECT tier AS "Hang",
       count(*) AS "So chuyen",
       '$' || to_char(coalesce(sum(fare_cents), 0) / 100.0, 'FM999,999,990.00') AS "Doanh thu"
FROM trips.trips WHERE status = 'completed'
GROUP BY tier ORDER BY sum(fare_cents) DESC NULLS LAST;

\echo '=================================================================='
SQL

echo ""
echo "usage-report: bao cao hoan tat luc $(date -u '+%Y-%m-%d %H:%M UTC')"

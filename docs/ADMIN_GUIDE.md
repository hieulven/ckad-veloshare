# VeloShare Admin Guide

Operator reference for deploying, configuring, and troubleshooting the VeloShare platform on a local `kind` cluster.

## Table of contents

- [Architecture](#architecture)
- [Cluster layout](#cluster-layout)
- [Operations (Makefile)](#operations-makefile)
- [Admin dashboard](#admin-dashboard)
- [Logging with Kibana](#logging-with-kibana)
- [Log event reference](#log-event-reference)
- [Configuration reference](#configuration-reference)
- [Troubleshooting runbook](#troubleshooting-runbook)
- [Security posture](#security-posture)

## Architecture

VeloShare is five services fronted by an nginx frontend, backed by shared Postgres and Redis:

| Service | Language | Responsibility |
|---|---|---|
| `pricing` | Python/FastAPI | Stateless fare calculation: `{minutes, tier, surge} -> {cents}` |
| `rider` | Python/FastAPI | Rider CRUD, tier lookup, **auth/JWT issuer** |
| `station` | Python/FastAPI | Station & dock inventory |
| `trip` | Python/FastAPI | Trip lifecycle; calls `pricing` and `rider`; uses Redis + Postgres |
| `fleet-monitor` | Bash (psql) | CronJob, generates a **daily user-metrics report** for the manager (riders, trips, revenue by tier) to the Job logs |

**Data layer:**
- One **Postgres** StatefulSet, shared, with a separate schema and DB user per service (`riders`, `stations`, `trips`).
- One **Redis** Deployment:
  - Stream `trip.completed` — published by `trip` on ride completion (fan-out, not durable storage).
  - Key `trip:active:{rider_id}` with a 7200s TTL — fast "is this rider already riding?" check.
  - Durable trip records always live in Postgres, never only in Redis.

**Frontend:** nginx serves a vanilla-JS dashboard and reverse-proxies `/api/*` to the backend services. Because the browser talks to the same origin (`http://localhost/`) for both the UI and the API, there is no CORS to configure.

**Logging:** every app pod runs a Fluent Bit sidecar (`log-agent`) that tails `/var/log/veloshare/app.log` and ships it to Elasticsearch (index `veloshare-logs`), viewable in Kibana.

## Cluster layout

Local `kind` cluster named `veloshare`, defined in `kind-config.yaml`: 3 nodes.

- **1 control-plane node** — tainted `NoSchedule`, so no application pods are scheduled there. It runs `ingress-nginx` and maps host ports **80** and **443** into the cluster.
- **2 worker nodes** — run the application pods.

## Operations (Makefile)

All operations go through `make`:

```bash
make up            # cluster-up -> ingress -> images -> load -> deploy (full bring-up)
make cluster-up     # create the kind cluster
make ingress        # install ingress-nginx and wait for it
make images          # docker build every service image (veloshare/<svc>:0.1.0)
make load            # kind load docker-image for every service, into cluster `veloshare`
make lint            # helm lint ./helm/veloshare
make template        # helm template (dry-run render, no cluster needed)
make deploy           # lint, then helm upgrade --install veloshare ./helm/veloshare -n veloshare --create-namespace
make uninstall        # helm uninstall veloshare -n veloshare
make cluster-down     # kind delete cluster --name veloshare
```

### Redeploying after a code change

Images are loaded straight into `kind` (no registry) and `imagePullPolicy` is `IfNotPresent`. The image tag stays `0.1.0` regardless of code changes, so Kubernetes will **not** notice a new image on its own. After changing a service's code:

```bash
make images
make load
kubectl -n veloshare rollout restart deploy/<service>
```

## Admin dashboard

Log in at `http://localhost/` with the admin credentials (see [Security posture](#security-posture)). The admin dashboard adds capabilities beyond the rider view:

- **Riders** — create a rider (name, email, tier, password) and list all riders. The password set here is what lets that rider log in.
- **Stations** — create a station (name, capacity), list stations, update docks available.
- **Fare calculator** — compute `minutes + tier + surge -> cents` directly, without creating a trip.
- **All trips** — view every rider's trips, not just your own.
- **Start/end a trip on behalf of a rider** — supply `rider_id` explicitly.
- **Kibana link** — jumps to `http://localhost/kibana` for log search.

## Logging with Kibana

Open `http://localhost/kibana`.

**First-time setup:** create a data view named `veloshare-*` with time field `@timestamp` (**Stack Management -> Data Views**), then use **Discover**.

Useful queries:

| Query | Purpose |
|---|---|
| `event: trip_completed` | All completed trips |
| `service: pricing` | All log lines from the pricing service |
| `event: login and outcome: failure` | Failed login attempts |
| `request_id: "<id>"` | **One user transaction across every service it touched** |

The `request_id` query is the most useful one for debugging: `trip` forwards its `X-Request-ID` header to `rider` and `pricing`, so searching one request ID returns `trip`'s `trip_completed` event alongside `pricing`'s `fare_computed` event for the same request. Every API response also carries an `x-request-id` header — grab it from a failing browser request (dev tools -> Network tab) and search it directly in Kibana.

## Log event reference

Every log line includes a `request` event for each HTTP call, with `method`, `path`, `status`, `duration_ms`, and `request_id`. On top of that, these business events are emitted:

| Event | Emitted by |
|---|---|
| `login` | rider |
| `rider_created` | rider |
| `station_created` | station |
| `docks_updated` | station |
| `trip_started` | trip |
| `trip_completed` | trip |
| `fare_computed` | pricing |

## Configuration reference

| Setting | Value |
|---|---|
| Namespace | `veloshare` |
| Images | `veloshare/<service>:0.1.0` |
| App service ports | container `8000`, ClusterIP Service `80` |
| Global values file | `helm/veloshare/values.yaml` |

Global values keys (`.Values.global.*`):

- `namespace`
- `image.registry`, `image.tag`, `image.pullPolicy`
- `ingress.enabled`, `ingress.host` (empty = matches any Host), `ingress.className`
- `logging.enabled`
- `auth.jwtSecret`, `auth.jwtTtlSeconds`, `auth.adminEmail`, `auth.adminPassword`

Per-service tunables:

| Service | Env var | Purpose |
|---|---|---|
| pricing | `PRICING_UNLOCK_FEE_CENTS` | Flat unlock fee (default 100) |
| pricing | `PRICING_TIER_RATES` | Per-minute cents by tier, JSON (default `{"standard": 15, "member": 8, "day_pass": 5}`) |
| trip | `ACTIVE_TTL_SECONDS` | TTL on the `trip:active:{rider_id}` Redis key (default 7200) |
| trip | `PRICING_URL`, `RIDER_URL` | In-cluster DNS URLs for the services trip calls |
| trip | `REDIS_*` | Redis connection settings |

Service-to-service calls use in-cluster DNS, e.g. `http://pricing.veloshare.svc.cluster.local`.

## Troubleshooting runbook

**`fleet-monitor` pods show `0/1 Completed`.**
This is normal — a finished CronJob pod has no running container once it exits 0. `fleet-monitor` is
the daily user-metrics report; the report itself is the Job's log output. Read the latest, or run one
on demand:

```bash
kubectl -n veloshare logs job/<job-name>                              # read a past daily report
kubectl -n veloshare create job report-now --from=cronjob/fleet-monitor
kubectl -n veloshare wait --for=condition=complete job/report-now --timeout=60s
kubectl -n veloshare logs job/report-now
```

**HPA on `pricing` shows `cpu <unknown>`.**
`metrics-server` is deliberately not installed in this cluster, so the HPA has no metrics and will never scale. This is expected in this environment.

**Elasticsearch is slow to start.**
It's a large image with real boot time, and it needs a privileged init container to set `vm.max_map_count=262144` before the main container can start. Give it a couple of minutes.

**App pods show `2/2` — that's expected, not a problem.**
Each app pod runs the service container plus a `log-agent` Fluent Bit sidecar. To check the sidecar specifically:

```bash
kubectl -n veloshare logs <pod> -c log-agent
```

**General inspection commands:**

```bash
kubectl -n veloshare get pods -o wide
kubectl -n veloshare logs deploy/<service> -c <service>
kubectl -n veloshare exec postgres-0 -- psql -U postgres -d veloshare -c '...'
```

## Security posture

This deployment is **dev-grade only** — do not point it at real users or data.

What is handled properly:

- **No credential lives in git or in the chart.** Every secret (DB passwords, JWT signing key,
  admin login) sits only in the local, gitignored `env/*.env` files and is applied straight to
  the cluster by `make secrets`. Helm only references Secrets by name via `envFrom`, so
  `helm template` renders **zero** Secrets and cannot leak a value into a manifest.
- Rider passwords are hashed with `scrypt`; passwords never appear in logs (the `login` event
  records only an `outcome`) and never in a pod spec.

What is still dev-grade:

- Everything runs over plain HTTP; there is no TLS.
- Kubernetes Secrets are only base64-encoded in etcd, not encrypted at rest.
- Elasticsearch has `xpack.security` disabled — no auth on log access.
- There is no way to revoke a JWT before it expires (1h TTL).

**Before any real use**, at minimum:

1. Manage secrets with Sealed Secrets / External Secrets / Vault instead of local `.env` files,
   and enable etcd encryption-at-rest.
2. Put TLS in front of the ingress.
3. Enable Elasticsearch security (`xpack.security.enabled: true`) and set real credentials for
   Kibana/Elasticsearch.
4. Generate unique high-entropy values for every `env/*.env` entry (`openssl rand -hex 32`) and
   rotate them regularly.

### Managing secrets

Each pod's config + credentials live in one file under `env/` (gitignored; only
`env/*.env.template` is tracked):

| File | Secret | Consumed by |
|---|---|---|
| `env/postgres.env` | `postgres` | postgres StatefulSet (+ its init script creates the per-service roles) |
| `env/rider.env` | `rider-db` | rider |
| `env/station.env` | `station-db` | station |
| `env/trip.env` | `trip-db` | trip |
| `env/auth.env` | `veloshare-auth` | rider (signs JWTs) + trip (verifies them) |

```sh
make env-init     # create env/*.env from the templates
# edit env/*.env and replace every change-me value
make secrets      # kubectl create secret generic --from-env-file, one per file
```

`make secrets` refuses to run while any `change-me` placeholder remains. To rotate a value: edit
the file, re-run `make secrets`, then `kubectl -n veloshare rollout restart deploy/<service>`.

Note `env/postgres.env` only takes effect on **first initdb**; changing a role password later
needs `ALTER ROLE` (or deleting the PVC to re-initialise). `DB_PASSWORD` in each service file
must match the matching `*_PASSWORD` in `env/postgres.env`.

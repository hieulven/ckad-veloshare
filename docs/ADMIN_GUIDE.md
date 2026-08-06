# VeloShare Admin Guide

Operator reference for deploying, configuring, and troubleshooting the VeloShare platform on a local `kind` cluster.

## Table of contents

- [Architecture](#architecture)
- [Cluster layout](#cluster-layout)
- [Operations (Makefile)](#operations-makefile)
- [Rolling updates](#rolling-updates)
- [Helm upgrade and rollback](#helm-upgrade-and-rollback)
- [Admin dashboard](#admin-dashboard)
- [Logging with Kibana](#logging-with-kibana)
- [Log event reference](#log-event-reference)
- [Configuration reference](#configuration-reference)
- [Troubleshooting runbook](#troubleshooting-runbook)
- [Security posture](#security-posture)

## Architecture

> Full service diagram, sync-vs-async breakdown, pod composition, and data ownership live in
> [`docs/architecture.md`](./architecture.md). This section is the short operator-facing summary.

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

`rollout restart` re-rolls the **same Pod spec** — it does not change which image tag the
Deployment references. It works here only because every image keeps the fixed tag `0.1.0` and
`imagePullPolicy: IfNotPresent`: `kind load docker-image` replaces the tag's content on the node,
and `rollout restart` forces new Pods that re-pull (find) that already-loaded tag. It is **not**
the same operation as changing the image a Deployment points at — see below.

## Rolling updates

Use this procedure when you want the Deployment's spec itself to change (a real new image tag),
and to demonstrate the CKAD rolling-update surface: `kubectl set image`, `rollout status`,
`rollout undo`, `rollout history`.

**1. Build and load a new, distinct tag** (don't reuse `0.1.0` — that's what makes this a real
rolling update instead of a same-spec restart).

`pricing` already ships this second tag, so these commands run as-is:

```bash
make images                               # builds every service at 0.1.0, plus pricing:0.2.0
docker images | grep veloshare/pricing    # 0.1.0 and 0.2.0 both present
# (make images-demo-tag rebuilds only the 0.2.0 tag, if that's all you need)
```

**2. Point the Deployment at the new tag and watch the rollout:**

```bash
kubectl -n veloshare set image deploy/pricing-blue pricing=veloshare/pricing:0.2.0
kubectl -n veloshare rollout status deploy/pricing-blue
```

(`pricing` runs as two Deployments, `pricing-blue` and `pricing-green` — see "Blue/green
cutover" below. `pricing-blue` is the one serving traffic by default.)

`set image` patches only the named container's `image:` field — this is the actual spec change
that `rollout restart` never makes. `rollout status` blocks until every new-generation Pod is
Ready and the old ReplicaSet is scaled to zero (or reports the failure if it can't).

**Confirm the new image is really what's serving.** `pricing` bakes its image tag in at build
time (`ARG APP_VERSION` in `services/pricing/Dockerfile`) and reports it on `/version`, so this
cannot be fooled by a stale Pod:

```bash
kubectl -n veloshare exec deploy/pricing-blue -c ambassador -- curl -s 127.0.0.1:8080/version
# {"service":"pricing","version":"0.2.0"}
```

Return to the baseline tag when you're done demonstrating:

```bash
kubectl -n veloshare set image deploy/pricing-blue pricing=veloshare/pricing:0.1.0
kubectl -n veloshare rollout status deploy/pricing-blue
```

### Blue/green cutover (the no-restart alternative)

Everything above is a **rolling** update: Pods are replaced in place, and for a few seconds both
versions serve. Blue/green trades that for a switch with no Pod churn at all.

`pricing` runs two Deployments at once — `pricing-blue` (image `0.1.0`) and `pricing-green`
(image `0.2.0`). Both are labelled `app.kubernetes.io/name: pricing` and differ only by `color`.
The `pricing` Service selects one color; moving traffic is a patch to that selector, and nothing
else changes — same Service, same ClusterIP, same DNS name, no Pod replaced:

```bash
make bluegreen-status     # which color is serving, and what each color is running
make bluegreen            # blue -> green, printing before/after evidence
make bluegreen-rollback   # green -> blue
```

By hand, with the proof:

```bash
curl -s http://localhost/api/pricing/version
# {"service":"pricing","version":"0.1.0"}

kubectl -n veloshare patch svc pricing -p '{"spec":{"selector":{"color":"green"}}}'

curl -s http://localhost/api/pricing/version
# {"service":"pricing","version":"0.2.0"}

# same two Pods, same AGE -- nothing was restarted:
kubectl -n veloshare get pods -l app.kubernetes.io/name=pricing
# only the Service's endpoints moved:
kubectl -n veloshare get endpointslices -l kubernetes.io/service-name=pricing
```

Rolling back is the same patch in reverse, and it is instant — the old version never stopped
running. That is the property you are buying with the extra idle Pod.

**A `kubectl patch` cutover is live-only.** The next `make deploy` resets the selector to
`values.yaml`. To make green the persistent default:

```bash
helm upgrade veloshare ./helm/veloshare -n veloshare --set pricing.blueGreen.activeColor=green
```

The `pricing` HPA follows `activeColor`, so it autoscales whichever color is serving.

**3. Roll back if the new version is bad:**

```bash
kubectl -n veloshare rollout history deploy/trip
kubectl -n veloshare rollout undo deploy/trip
kubectl -n veloshare rollout status deploy/trip
```

`rollout undo` (optionally `--to-revision=<N>` from the `rollout history` list) reverts the
Deployment to the previous ReplicaSet's Pod spec — including its image tag — and is itself a
rolling update in the other direction.

> Note: `helm.sh` is the source of truth for this chart's rendered manifests — a `kubectl set
> image` done outside Helm will be **overwritten** by the next `helm upgrade` / `make deploy`
> (which re-renders `.Values.global.image.tag`, currently pinned to `0.1.0`). Use `kubectl set
> image` for the live demo above, then either bump `global.image.tag` in
> `helm/veloshare/values.yaml` to make it stick, or `helm upgrade ... --set
> global.image.tag=0.2.0` (see below).

## Helm upgrade and rollback

Every `make deploy` is a Helm release upgrade (`helm upgrade --install veloshare
./helm/veloshare -n veloshare`), so the release has revision history independent of any single
Deployment's rollout history:

```bash
helm -n veloshare history veloshare
```

**Override values at upgrade time** without editing `values.yaml` — useful for a quick demo of
scaling one service:

```bash
helm upgrade veloshare ./helm/veloshare -n veloshare --set pricing.blueGreen.blue.replicaCount=3
kubectl -n veloshare get deploy pricing-blue
```

(`pricing.replicaCount` only applies when `pricing.blueGreen.enabled=false`; with blue/green on,
each color has its own `blueGreen.<color>.replicaCount`. For any other service it's the plain
`<service>.replicaCount`.)

**Roll the whole release back** to a previous revision (reverts every templated resource the
chart owns, not just one Deployment's image):

```bash
helm -n veloshare rollback veloshare <REVISION>
helm -n veloshare history veloshare      # confirm the rollback landed as a new revision
```

`helm rollback` creates a **new** revision that reproduces an old one's rendered manifests — it
does not delete history, so `helm history` keeps growing. This is the release-level counterpart
to `kubectl rollout undo`: use `kubectl rollout undo` to revert one Deployment's Pod spec quickly;
use `helm rollback` when a bad `helm upgrade` (a values change, a template change, a chart
version bump) needs to be undone across every resource it touched.

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
`metrics-server` is not part of `make up`, so until it's installed the HPA has no metrics to read
and will never scale. Install it and the target resolves to a real percentage:

```bash
make metrics-server
kubectl -n veloshare get hpa pricing -w
```

`make metrics-server` also patches in `--kubelet-insecure-tls`, which kind needs because its
kubelet serving certificates aren't signed by the cluster CA — without that patch the
metrics-server Pod runs but every scrape fails.

**There are no `elasticsearch` / `kibana` pods.**
Expected — `global.logging.enabled` defaults to `false` because Elasticsearch and Kibana
together exceed the namespace `ResourceQuota`. The Fluent Bit sidecar still runs on every
app pod and writes to its own stdout (`kubectl -n veloshare logs deploy/<svc> -c log-agent`).
To run the full EFK stack, enable logging *and* raise the quota in the same command — see
the worked `--set` example in `helm/veloshare/values.yaml`.

**Elasticsearch is slow to start (when logging is enabled).**
It's a large image with real boot time, and it needs a privileged init container to set `vm.max_map_count=262144` before the main container can start. A `startupProbe` allows up to 5 minutes before the pod is declared failed, so give it a couple of minutes.

**App pods show `3/3` — that's expected, not a problem.**
Each app pod runs the service container plus two sidecars: `ambassador` (an nginx reverse
proxy on 8080 that the Service actually targets) and `log-agent` (Fluent Bit). Because
there is more than one container, `kubectl logs` always needs an explicit `-c`:

```bash
kubectl -n veloshare logs <pod> -c <service>     # the app itself
kubectl -n veloshare logs <pod> -c ambassador    # the nginx sidecar
kubectl -n veloshare logs <pod> -c log-agent     # Fluent Bit — with logging off, the
                                                 # app's JSON log lines land here
```

**General inspection commands:**

```bash
kubectl -n veloshare get pods -o wide
kubectl -n veloshare logs deploy/<service> -c <service>
kubectl -n veloshare exec postgres-0 -- psql -U postgres -d veloshare -c '...'
```

**Pod won't start, or a probe keeps failing — read `describe` and cluster `events` before logs.**
`logs` only shows what the container itself printed; `describe` shows what the *kubelet/scheduler*
did to it (image pull errors, probe failures with their HTTP status, OOMKilled, volume mount
errors, which node it landed on) and is usually the faster first step for anything that never
reaches Running:

```bash
kubectl -n veloshare describe pod <pod>
kubectl -n veloshare get events --sort-by=.lastTimestamp
```

`get events` sorted by time gives a namespace-wide timeline (scheduling, pulls, probe failures,
OOM kills, ReplicaSet scale events) — useful for correlating "which Deployment's rollout caused
this" when several things changed at once.

**Resource usage — `top` needs `metrics-server`.**

```bash
kubectl -n veloshare top pods
kubectl -n veloshare top nodes
```

This cluster does not install `metrics-server` by default (see the `pricing` HPA note above); it
is installed with `make metrics-server`. Without it, both `top` commands fail with `error: Metrics
API not available` — that error means "no metrics-server," not "no pods."

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

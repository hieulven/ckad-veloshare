# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# VeloShare — Project Conventions

City bike-share platform. Practice project for learning Kubernetes with Helm (CKAD prep).
Riders unlock a bike from a dock, ride, return it, and get charged by duration and tier.
Fully deployed on a local 3-node `kind` cluster. Detailed narrative docs (in Vietnamese)
live in [`README.md`](./README.md); operator/user reference (English) is in
[`docs/ADMIN_GUIDE.md`](./docs/ADMIN_GUIDE.md) and [`docs/USER_GUIDE.md`](./docs/USER_GUIDE.md).

## Commands

```sh
make up                # full bring-up: cluster -> ingress -> secrets -> images -> load -> deploy
make env-init           # create env/*.env from templates (once, local only, gitignored)
make secrets            # apply env/*.env to the cluster as per-pod Secrets (refuses on leftover change-me)
make images             # docker build every service image veloshare/<svc>:0.1.0, plus pricing:0.2.0
                          # (needed by pricing-green and by k8s/overlays/prod)
make images-demo-tag    # build+load ONLY the second pricing tag (DEMO_TAG, 0.2.0)
make load               # kind load docker-image for every service into cluster `veloshare`
make lint               # helm lint ./helm/veloshare
make template           # helm template (dry-run render, no cluster needed)
make deploy             # lint, then helm upgrade --install veloshare ./helm/veloshare -n veloshare
make gen-k8s             # scripts/gen-k8s.sh — regenerate k8s/ raw manifests from the Helm chart
make deploy-kubectl      # scripts/deploy.sh kubectl [dev|prod] — deploy via k8s/overlays instead of
                          # Helm; refuses to run while the other path owns the namespace (FORCE=1 to override)
make history            # helm history veloshare -n veloshare
make rollback REV=<n>   # helm rollback veloshare <n> -n veloshare
make metrics-server     # install metrics-server (kind needs --kubelet-insecure-tls) so the HPA works
make smoke-test         # scripts/smoke-test.sh — non-interactive E2E check, non-zero exit on failure
make demo               # scripts/demo.sh — step-by-step walkthrough of the CKAD demo checklist
make lab                # lab/run-lab.sh — instructor's Day 3-5 CKAD labs, step by step
                          # (make lab LAB=4.3 or LAB=day4 for one lab/day; lab-auto, lab-list,
                          # lab-clean). Runs in namespace `veloshare-lab`, never `veloshare`.
make evidence           # AUTO=1 scripts/demo.sh — read-only pass, refreshes docs/evidence/*.yaml
make bluegreen-status   # which pricing color the Service points at, both colors' images/versions
make bluegreen          # cut pricing over blue -> green by patching the Service selector (real service)
make bluegreen-rollback # flip it back green -> blue
make bluegreen-demo     # apply k8s/labs/bluegreen-demo.yaml (standalone nginx lab, not part of the chart)
make uninstall          # helm uninstall veloshare -n veloshare  (ask before running)
make cluster-down       # kind delete cluster --name veloshare   (ask before running)
```

There is no test suite or linter for the Python services in this repo — verification is
`helm lint` / `helm template` for charts, `scripts/smoke-test.sh` against a running cluster,
and hitting the running service through `kubectl port-forward` or the ingress for app code.

**After changing one service's code**, the image tag stays `0.1.0` so Kubernetes won't
notice a new image on its own:

```sh
docker build -t veloshare/<service>:0.1.0 ./services/<service>
kind load docker-image veloshare/<service>:0.1.0 --name veloshare
kubectl -n veloshare rollout restart deploy/<service>
```

For `pricing` the Deployment is `pricing-blue` (and `pricing-green`, which runs the `0.2.0`
build) — see Blue/green below. Rebuilding `pricing` at `0.1.0` and restarting `pricing-blue`
is the equivalent step.

**Diagnostics:**

```sh
kubectl -n veloshare get pods -o wide
kubectl -n veloshare get svc,endpoints                      # a Service with no endpoints = selector bug
kubectl -n veloshare describe pod <pod>                     # Events at the bottom explain most failures
kubectl -n veloshare get events --sort-by=.lastTimestamp
kubectl -n veloshare top pods                               # needs metrics-server (`make metrics-server`)
kubectl -n veloshare logs deploy/<service> -c <service>     # app pods are 3/3 — see logging below
kubectl -n veloshare logs deploy/<service> -c log-agent     # the Fluent Bit sidecar
kubectl -n veloshare exec postgres-0 -- psql -U postgres -d veloshare -c '...'
kubectl -n veloshare exec deploy/redis -- redis-cli XRANGE trip.completed - +
kubectl -n veloshare create job report-now --from=cronjob/fleet-monitor   # trigger the daily report now
kubectl -n veloshare create job pods-now --from=cronjob/pod-lister        # trigger the RBAC demo now
```

## Architecture

Five app services + a static frontend, fronted by ingress-nginx, backed by shared
Postgres and Redis, with a Fluent Bit -> Elasticsearch -> Kibana logging stack sidecar'd
onto every app pod.

| Service | Language | Responsibility | State |
|---|---|---|---|
| `rider` | Python / FastAPI | Rider CRUD, tier lookup, **JWT issuer** (`/auth/login`, `/auth/me`) | Postgres schema `riders` |
| `station` | Python / FastAPI | Station & dock inventory | Postgres schema `stations` |
| `trip` | Python / FastAPI | Start/end trip, calls `rider` + `pricing`, publishes events | Postgres schema `trips`, Redis |
| `pricing` | Python / FastAPI | Fare calculation `{minutes, tier, surge} -> {cents}` | Stateless |
| `fleet-monitor` | Bash (psql) | CronJob (`0 0 * * *`) — daily user/business metrics report to Job logs | Stateless |
| `frontend` | nginx + vanilla JS | Serves the dashboard, reverse-proxies `/api/*` (same-origin, no CORS) | Stateless |
| `logging` | Elasticsearch + Kibana | Central log store + UI, index `veloshare-logs`. **Off by default** — see Logging below | Elasticsearch StatefulSet |

`fleet-monitor` used to poll `/healthz` every 5 minutes and log DEAD/ALIVE — redundant
with liveness/readiness probes that actually act on failure. It was repurposed into the
daily report job; the name stayed to avoid churn in the umbrella chart, so it's now a
mild misnomer.

### Auth

- `rider` **issues** JWTs (`POST /auth/login`, HS256, 1h TTL by default); `trip` only
  **verifies** them — both read the same `veloshare-auth` Secret (`JWT_SECRET`), so they
  cannot drift apart.
- The admin account (`ADMIN_EMAIL`/`ADMIN_PASSWORD`) comes from that same Secret, not the
  `riders` table — nobody can create an admin account through the API.
- Rider passwords: `hashlib.scrypt`, stored as `scrypt$<salt>$<hash>` in `password_hash`.
- `trip` derives `rider_id` from the token, never from the request body; riders can only
  see/end their own trips (403 otherwise), admins see everything.
- Every request gets a `request_id` (from `X-Request-ID` or generated); `trip` forwards it
  to `rider` and `pricing` so one transaction is traceable end-to-end in Kibana.

### Data layer

One Postgres StatefulSet (PVC, headless Service), **one schema + one DB role per service**
(`riders`/`rider`, `stations`/`station`, `trips`/`trip`), each role's `search_path` fixed
to its own schema — no cross-schema queries from app code. `fleet-monitor` is the one
deliberate exception: it authenticates as the `postgres` admin role to aggregate across
schemas for its report, which is legitimate for a reporting job.

Redis (single Deployment), non-durable, two uses:
- `trip:active:{rider_id}` (TTL, default 7200s) — fast "already riding?" check.
- `trip.completed` stream — fan-out event on trip end.
Trip records themselves always live in Postgres, never only in Redis.

Migrations run via an init container before each service's app container starts.

### Secrets (important: never via Helm or git)

Every credential — DB passwords, `JWT_SECRET`, admin login — lives in a local,
gitignored `env/<name>.env` file (only `env/<name>.env.template` is committed) and is
pushed straight into the cluster by `make secrets` as a plain Secret
(`kubectl create secret generic --from-env-file`). Helm templates only ever do
`envFrom: secretRef: name: <secret>` — they never read or render a credential, so
`helm template` / `helm get manifest` produce **zero** Secrets, even by accident.

| env file | Secret | Consumed by |
|---|---|---|
| `env/postgres.env` | `postgres` | postgres StatefulSet (init script creates per-service roles); also `fleet-monitor` |
| `env/rider.env` | `rider-db` | rider |
| `env/station.env` | `station-db` | station |
| `env/trip.env` | `trip-db` | trip |
| `env/auth.env` | `veloshare-auth` | rider (signs) + trip (verifies) |

`DB_PASSWORD` in each service's file must match the corresponding `*_PASSWORD` in
`env/postgres.env` — that's what the Postgres init script uses to create the LOGIN role.
`env/postgres.env` only takes effect on first `initdb`; changing a role password later
needs `ALTER ROLE` or deleting the PVC. `make secrets` refuses to run while any
`change-me` placeholder remains in `env/*.env`.

### Logging (EFK)

Every app pod is **3/3**: the app container, the `ambassador` nginx sidecar, and a
`log-agent` Fluent Bit sidecar — the latter rendered by the shared
`veloshare.loggingSidecar` / `veloshare.logVolumes` helpers in
`helm/veloshare/templates/_helpers.tpl`. The app writes JSON logs to a shared `emptyDir`
(`/var/log/veloshare/app.log`) as well as stdout; Fluent Bit tails that file.

**Elasticsearch + Kibana are OFF by default** (`global.logging.enabled: false`). The two
of them add ~350m CPU / 400Mi to requests, which does not fit the namespace
`ResourceQuota`. The sidecar and the shared `emptyDir` stay in place either way — only
the Fluent Bit *output* changes:

- **logging off (default)** — output is the sidecar's own stdout:
  `kubectl -n veloshare logs deploy/<service> -c log-agent`
- **logging on** — output is Elasticsearch (index `veloshare-logs`), searchable in Kibana
  at `/kibana`. Useful queries: `event: trip_completed`, `service: pricing`,
  `event: login and outcome: failure`, `request_id: "<id>"`.

Turning logging on requires raising the quota at the same time or the elasticsearch and
kibana Pods are rejected — there's a ready-made `--set` example in
`helm/veloshare/values.yaml`. Both paths are already handled by the
`fluent-bit-config` ConfigMap, so this is purely a values flip.

### Helm structure

Umbrella chart `helm/veloshare` declares 9 subchart dependencies in `Chart.yaml`
(`pricing`, `postgres`, `rider`, `station`, `trip`, `redis`, `fleet-monitor`, `frontend`,
`logging`) and owns global values (`namespace`, `image.registry/tag/pullPolicy`,
`ingress.host/className`, `logging.enabled`). Per-service tunables live in each
subchart's own `values.yaml`; templates read from `.Values`, never hardcode names/ports.
All naming/labelling goes through `_helpers.tpl` (`veloshare.fullname`,
`veloshare.labels`, `veloshare.selectorLabels`) so every resource gets consistent
`app.kubernetes.io/*` labels regardless of which subchart rendered it.

App containers listen on **8000**; the `ambassador` nginx sidecar listens on **8080** and
proxies to `127.0.0.1:8000`, and it is 8080 that the ClusterIP Service's `targetPort`
points at. Services expose port **80**. Every long-running workload has liveness +
readiness probes. `rider`, `station`, `trip`, `pricing` and `postgres` additionally have a
`startupProbe` (`veloshare.startupProbe` in `_helpers.tpl`, per-chart `startupProbe` values)
so a slow first boot — uvicorn import plus asyncpg pool creation, or Postgres running
`initdb` + `init.sql` — is never mistaken for a hang and restarted by liveness. Elasticsearch
and kibana have their own for the same reason (slow-starting JVM/Node apps). `frontend` and
`redis` deliberately have none: nginx and redis-server are listening in well under a second,
and a startup probe there would be ceremony, not protection.

### Blue/green

`pricing` runs as **two Deployments**, `pricing-blue` and `pricing-green`, rendered from one
template body (`charts/pricing/templates/deployment.yaml` ranges over the colors). Both carry
`app.kubernetes.io/name: pricing` — so the NetworkPolicy, the API Ingress and in-cluster DNS
match either — and differ only by a `color` label, which is also in each one's
`selector.matchLabels` so the two ReplicaSets never adopt each other's Pods.

The ClusterIP Service `pricing` selects `color: <activeColor>`. **Cutting traffic over is a
one-line patch to that selector** and nothing else moves — same Service name, same ClusterIP,
same DNS, no Deployment touched:

```sh
make bluegreen            # blue -> green, with before/after evidence
make bluegreen-rollback   # green -> blue
make bluegreen-status     # who's serving right now
```

The two colors run genuinely different images (blue `0.1.0`, green `0.2.0`, both built by
`make images` from the same source with `APP_VERSION` baked in), so `GET /version` proves
which one answered rather than asserting it. A `kubectl patch` cutover is **live-only** — the
next `make deploy` resets it to `values.yaml`; persist it with
`--set pricing.blueGreen.activeColor=green`. The HPA follows `activeColor`.

### Cluster layout

`kind` cluster named `veloshare`, defined in `kind-config.yaml`: 1 control-plane node
(tainted `NoSchedule` so no app pods land there; runs ingress-nginx, maps host ports
80/443) + 2 worker nodes (run all app pods). Ingress host is empty (`global.ingress.host: ""`)
so it matches any `Host` header — `http://localhost/` works with no `/etc/hosts` entry.

### Deliberate rough edges (don't "fix" without asking)

- `metrics-server` is **not part of `make up`** — install it with `make metrics-server`
  (which also patches in `--kubelet-insecure-tls`, required on kind). Until then the
  `pricing` HPA shows `cpu <unknown>` and never scales, and `kubectl top` errors with
  `Metrics API not available`.
- Elasticsearch + Kibana are **off by default** (`global.logging.enabled: false`) because
  they don't fit the namespace `ResourceQuota`. This is a values flip, not a missing
  feature — see the Logging section above.
- `k8s/overlays/` (`dev`/`prod`) are real Kustomize overlays over the actual veloshare
  services — generated from the Helm chart by `scripts/gen-k8s.sh` (`make gen-k8s`) — and
  are an alternative deploy path to Helm, never applied alongside it: `scripts/deploy.sh`
  refuses to run one path while the other owns the namespace (`FORCE=1` to override). The
  overlays now also pin a real per-environment image tag on the **active** pricing color:
  `dev` pins `pricing-blue` to `veloshare/pricing:0.1.0`, `prod` pins it to `:0.2.0` — both
  genuinely built and loaded via `make images`, so a running Pod's reported version
  (`GET /version`) proves which image it's actually running. That's a per-Deployment JSON
  patch rather than a top-level `images:` transformer on purpose: `images:` matches by image
  *name* and would rewrite both colors, dragging `pricing-green` backwards to `0.1.0` in dev
  and erasing the version difference blue/green exists to demonstrate. The other six services
  stay unpinned (one tag, `0.1.0`, ever exists in the kind cluster; pinning an
  untagged/never-loaded tag would render an unpullable manifest). `k8s/labs/kustomize-demo/`
  is a separate, minimal **standalone teaching lab** against a public nginx image, kept apart
  so it never competes for ownership with either deploy path. Same reasoning covers
  `k8s/labs/bluegreen-demo.yaml`, `k8s/labs/pvc-demo.yaml`, and `k8s/labs/probes-demo.yaml`:
  standalone labs applied by hand (or via `make bluegreen-demo`), not chart or overlay members.
- `k8s/labs/bluegreen-demo.yaml` is now **redundant with the real thing** (`make bluegreen`)
  and is kept only as a throwaway-nginx version of the same pattern for hands-on practice.
  Its `kubectl run` curl Pod is blocked by the namespace default-deny NetworkPolicy — run it
  with `--set global.networkPolicy.enabled=false` or read the color off the Service.
- The **namespace default-deny NetworkPolicy** (`networkpolicy-default-deny.yaml`) selects
  every Pod in `veloshare`, including anything applied by hand. Six allow-policies sit on
  top of it (DNS, backends, frontend, datastores, jobs, logging). Anything new that needs
  the network needs a rule — that's the point, not an oversight. Toggle the whole set with
  `global.networkPolicy.enabled`.
- The `pricing` Deployment has an optional `initCheck`-gated init container that waits
  for `rider` (TCP) and Postgres (`pg_isready`) before starting — even though `pricing`
  is stateless and calls neither. It exists purely to demonstrate the
  wait-for-dependency pattern; see the comment in
  `helm/veloshare/charts/pricing/templates/deployment.yaml`. Toggle via
  `pricing.initCheck.enabled`.
- Elasticsearch runs with `xpack.security.enabled=false`; everything is plain HTTP (no
  TLS); Secrets are only base64 in etcd. This is a local learning environment, not a
  security posture to replicate.

## Conventions for new/changed code

- **Python**: 3.12, FastAPI + uvicorn, Pydantic v2 models, async `asyncpg` pool
  (created in `lifespan`, closed on shutdown). Every service exposes `GET /healthz` ->
  `{"status": "ok"}` — keep that response shape exact; `scripts/smoke-test.sh` and probes
  compare it verbatim. `pricing` additionally exposes `GET /version` -> `{"service":
  "pricing", "version": "<tag>"}`, backed by the build-time `APP_VERSION` Docker `ARG`
  (`scripts/build.sh` passes `--build-arg APP_VERSION=$TAG` to every build; a service
  whose Dockerfile doesn't declare that `ARG` just ignores it). Config only from env vars
  (`require_env` fails fast for anything secret — no fallback default). JSON logging via
  `pythonjsonlogger`, one line per request plus named business events (`login`,
  `rider_created`, `trip_completed`, ...), each carrying `request_id`.
- **Docker**: `python:3.12-slim`, non-root user (`useradd --uid 10001`), entrypoint
  `uvicorn main:app --host 0.0.0.0 --port 8000`. `fleet-monitor` is `alpine` +
  `postgresql-client` (psql, not curl/jq — that was the old health-poll version).
  Build then `kind load docker-image <img> --name veloshare`.
- **Helm**: lint (`helm lint`) and render (`helm template` / `--dry-run`) before
  touching the cluster. Service-to-service calls use in-cluster DNS
  (`http://<service>.veloshare.svc.cluster.local`), built from values, never literals.
- Don't invent extra services or dependencies beyond the five above (+ frontend +
  logging, which are already built).
- Ask before destructive commands (`helm uninstall`, `kubectl delete`, `kind delete
  cluster`) and before touching anything under `env/*.env` in a way that could change a
  live credential.
- When creating or changing templates, show the rendered `helm template` output and
  briefly explain probe/port/resource/values choices.

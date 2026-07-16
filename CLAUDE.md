# VeloShare — Project Conventions

City bike-share platform. Practice project for learning Kubernetes with Helm.
Riders unlock a bike from a dock, ride, return it, and get charged by duration and tier.

Read this file before generating code, manifests, or charts. Follow these conventions unless I say otherwise.

## Services

| Service | Language | Responsibility | State |
|---|---|---|---|
| rider | Python / FastAPI | Rider CRUD, tier lookup | Postgres schema `riders` |
| station | Python / FastAPI | Station & dock inventory | Postgres schema `stations` |
| trip | Python / FastAPI | Start/end trip, fare orchestration, event publish | Postgres schema `trips`, Redis |
| pricing | Python / FastAPI | Fare calculation `{minutes, tier, surge} -> {cents}` | Stateless |
| fleet-monitor | Bash (curl, jq) | Poll `/healthz`, flag dead docks | Stateless, runs as CronJob |

Data layer: one **Postgres** StatefulSet (shared, schema-per-service) + one **Redis** Deployment.

## Tooling

- **kubectl** — install/inspect/debug the cluster (`get`, `logs`, `describe`, `port-forward`).
- **Helm** — package and deploy everything. All k8s objects are Helm templates, never raw `kubectl apply`.
- **kind** — local single-node cluster (cluster name `veloshare`).
- Prefer `helm upgrade --install` for the deploy loop.

## Repo layout

```
veloshare/
  rider/          main.py  requirements.txt  Dockerfile
  station/        main.py  requirements.txt  Dockerfile
  trip/           main.py  requirements.txt  Dockerfile
  pricing/        main.py  requirements.txt  Dockerfile
  fleet-monitor/  monitor.sh                 Dockerfile
  helm/
    veloshare/                 # umbrella chart for the whole platform
      Chart.yaml               # declares subchart dependencies
      values.yaml              # global values + per-service overrides
      templates/               # shared/global resources (namespace, ingress)
      charts/                  # subcharts, one per service
        rider/     Chart.yaml values.yaml templates/
        station/   Chart.yaml values.yaml templates/
        trip/      Chart.yaml values.yaml templates/
        pricing/   Chart.yaml values.yaml templates/
        fleet-monitor/ Chart.yaml values.yaml templates/
        postgres/  Chart.yaml values.yaml templates/
        redis/     Chart.yaml values.yaml templates/
  Makefile
  CLAUDE.md
```

The five service subcharts share the same template shape (deployment, service, configmap, secret,
probes) and differ only through their `values.yaml`. Factor common snippets into `_helpers.tpl`.

## Helm conventions

- Umbrella chart `veloshare` owns global values (namespace, image registry/tag, ingress host) and
  pulls each service in as a subchart dependency in `Chart.yaml`.
- Every value that varies per service lives in `values.yaml` — image, port, env, replicas, resources,
  probe paths. Templates must not hardcode names or ports; read them from `.Values`.
- Use `{{ include "veloshare.fullname" . }}` and shared `_helpers.tpl` for names and labels so all
  resources get consistent `app.kubernetes.io/*` labels.
- Standard labels on everything: `app.kubernetes.io/name`, `app.kubernetes.io/part-of: veloshare`.
- Postgres and Redis are subcharts too (either hand-written templates or a declared dependency);
  keep their config in their own `values.yaml`.
- Deploy with: `helm upgrade --install veloshare ./helm/veloshare -n veloshare --create-namespace`.
- Lint before every apply: `helm lint ./helm/veloshare` and inspect with `helm template` /
  `--dry-run` before touching the cluster.

## Python conventions

- Python 3.12. FastAPI + uvicorn. Pydantic v2 models for request/response.
- Async DB access with `asyncpg` (pool created at startup, closed at shutdown).
- Every service exposes `GET /healthz` returning 200 with `{"status": "ok"}`.
- All config comes from **environment variables**, never hardcoded. No secrets in code.
- Keep each `main.py` self-contained and small; this is a learning project, not production.

## Docker conventions

- Base image `python:3.12-slim`. Run as a **non-root** user.
- `pip install --no-cache-dir -r requirements.txt`.
- Entrypoint: `uvicorn main:app --host 0.0.0.0 --port 8000`.
- fleet-monitor uses `alpine:3.20` + `apk add --no-cache curl jq bash`.
- Build then load into kind: `kind load docker-image <img> --name veloshare`.

## Kubernetes conventions (expressed through Helm templates)

- One namespace: `veloshare` (created by the umbrella chart via `--create-namespace`).
- All app services listen on container port **8000**, exposed via ClusterIP Service on port **80**.
- Every Deployment has **liveness and readiness probes** hitting `/healthz` (paths from values).
- Set `resources.requests` and `resources.limits` on every container (from values).
- Config via **ConfigMap**; credentials via **Secret**. Mount as env vars.
- Service-to-service calls use in-cluster DNS: `http://<service>.veloshare.svc.cluster.local`
  (trip calls `pricing` and `rider`). Build these from template values, not literals.
- Postgres is a StatefulSet with a PVC and a headless Service. Redis is a plain Deployment.

## Database conventions

- Single Postgres instance, **one schema per service**, **one DB user per service**.
- Each service only touches its own schema — no cross-schema queries.
- Each service gets its own DB credential injected as its own Secret (templated per subchart).
- Migrations run via an **init container** before the app container starts.

## Redis conventions

- Stream `trip.completed` — trip publishes on ride completion (fan-out, not durable storage).
- Key `trip:active:{rider_id}` with TTL — fast "is this rider already riding?" check.
- Durable trip records live in **Postgres**, never only in Redis.

## Build order (do NOT scaffold everything at once)

1. `pricing` — stateless, no deps. Write its subchart, `helm upgrade --install`, get probes green.
2. Postgres subchart (StatefulSet + PVC).
3. `rider` subchart.
4. `station` subchart.
5. `trip` subchart + Redis — first service with service-to-service calls.
6. `fleet-monitor` CronJob subchart (`*/5 * * * *`).
7. Ingress in the umbrella chart, then an HPA on `pricing`.

Implement and verify one service end-to-end (image -> kind load -> helm upgrade -> port-forward -> curl)
before starting the next. Commit after each working service.

## Working style

- When creating templates, show me the rendered output (`helm template`) and briefly explain
  probe/port/resource choices.
- Ask before destructive commands (`helm uninstall`, `kubectl delete`, `kind delete cluster`).
- Don't invent extra services or dependencies beyond the five above.
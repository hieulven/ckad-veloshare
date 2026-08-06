# CKAD Checklist — Requirement → Evidence → Verification

Maps every §4 requirement ID from [`capstone-requirements.md`](../capstone-requirements.md)
to the repository path that implements it and a copy-pasteable command to verify it live.
Namespace is `veloshare`, Helm release is `veloshare`. Unless a row says otherwise, commands
assume `make up` has already been run (cluster + ingress + secrets + images + deploy).

All resource counts and paths below were checked against `helm template veloshare
./helm/veloshare -n veloshare` (default values) and, where marked, against `--set
global.logging.enabled=true`. Two defaults that matter for reading every row below:

- **`global.logging.enabled` defaults to `false`.** Elasticsearch/Kibana are not deployed;
  the `log-agent` Fluent Bit sidecar is still on every app Pod and ships to its own stdout
  instead (`kubectl -n veloshare logs deploy/<svc> -c log-agent`).
- **Every app Pod is 3/3**: the app container, the `ambassador` nginx sidecar (CKAD
  ambassador-pattern demo), and `log-agent`.

## Exported live state (`docs/evidence/`)

`make evidence` runs [`scripts/demo.sh`](../scripts/demo.sh) non-interactively (read-only:
every destructive sub-step is skipped) and writes the live objects behind the rows below to
`docs/evidence/*.yaml`. Use them to read a full resource without a cluster in front of you:

| File | Backs requirement |
|---|---|
| `01-pods.yaml`, `01-deployments.yaml`, `01-endpointslices.yaml` | N5, P1 |
| `02-ingress.yaml` | N2, N3 |
| `03-configmap-trip.yaml`, `secret-*.txt` | C1, C2 |
| `04-deploy-rider.yaml`, `04-statefulset-postgres.yaml` | O1, O2, C3, C6 |
| `05-deploy-pricing.yaml` | P2, D6 |
| `05-bluegreen-svc-{before,after}.yaml` — only written when the blue/green sub-step is actually run (interactive `make demo`, or `AUTO=1 FORCE_DESTRUCTIVE=1`) | P3 |
| `06-hpa-pricing.yaml` | P4 |
| `07-networkpolicy.yaml` | N4 |
| `08-pvc.yaml` | D5 |
| `09-helm-{manifest,values}.yaml`, `09-kustomize-{dev,prod}.yaml` | P5, P6 |

**Secrets are never exported as YAML.** `kubectl get secret -o yaml` would write base64
credentials into a tracked directory, and "Secrets committed in plaintext to git" is an
automatic-fail condition (§7). The exporter uses `kubectl describe secret` instead — key
names and byte counts, no values — into `docs/evidence/secret-*.txt`.

---

## 4.1 Application Design and Build

| ID | Requirement (short) | Where it's implemented | How to verify |
|---|---|---|---|
| D1 | Custom image per core service | `services/rider/Dockerfile`, `services/station/Dockerfile`, `services/trip/Dockerfile`, `services/pricing/Dockerfile`, `services/fleet-monitor/Dockerfile`, `services/frontend/Dockerfile`, `services/pod-lister/Dockerfile` — each non-root (`useradd --uid 10001` / nginx-unprivileged base), tag `0.1.0` (never `:latest`). Build/tag documented in `CLAUDE.md` "Commands" and `Makefile:55-58` (`images` target loops `SERVICES` in `Makefile:12`). `scripts/build.sh` passes `--build-arg APP_VERSION=$TAG` to every build, so `pricing` genuinely exists at two tags in the cluster — `0.1.0` and `0.2.0` (`make images-demo-tag`) — and reports which one it's running via `GET /version`, real evidence against `:latest` drift. | `make images` then `docker images | grep veloshare` — 7 images tagged `0.1.0`. `make images-demo-tag && docker images | grep pricing` — `pricing` also shows `0.2.0`. |
| D2 | Correct workload kinds | Deployments: rider/station/trip/pricing/frontend/redis. StatefulSet: `postgres` (`helm/veloshare/charts/postgres/templates/statefulset.yaml`). CronJobs: `fleet-monitor` (`helm/veloshare/charts/fleet-monitor/templates/cronjob.yaml`, daily report) and `pod-lister` (`helm/veloshare/templates/rbac-demo-cronjob.yaml`, RBAC demo, every 5 min). No DaemonSet used. | `kubectl -n veloshare get deploy,sts,cronjob` — expect 6 Deployments, 1 StatefulSet, 2 CronJobs. |
| D3 | Init container and/or sidecar | Both present on every one of rider/station/trip/pricing: **init** — `migrate` (schema migration, e.g. `helm/veloshare/charts/rider/templates/deployment.yaml:24-43`) and the shared `config-check` init helper (`helm/veloshare/templates/_helpers.tpl:160-183`); pricing additionally has a `wait-for-deps` init container (`helm/veloshare/charts/pricing/templates/deployment.yaml:25-56`, gated by `pricing.initCheck.enabled`). **Sidecars** — `ambassador` nginx proxy (`_helpers.tpl:200-219`) and `log-agent` Fluent Bit (`_helpers.tpl:112-131`), included from every app Deployment. | `kubectl -n veloshare get pod -l app.kubernetes.io/name=rider -o jsonpath='{.items[0].spec.initContainers[*].name} {.items[0].spec.containers[*].name}'` → `config-check migrate rider ambassador log-agent`. |
| D4 | Ephemeral volume (emptyDir) shared between containers | `logs` emptyDir shared by the app container and `log-agent` (declared in `veloshare.logVolumes`, `_helpers.tpl:137-143`; mounted read-write by the app at `/var/log/veloshare` and read-only by `log-agent`). Also `tmp`, `ambassador-tmp`, `ambassador-cache` emptyDirs supporting `readOnlyRootFilesystem: true`. | `kubectl -n veloshare exec deploy/rider -c rider -- ls /var/log/veloshare` then `kubectl -n veloshare logs deploy/rider -c log-agent | tail` — same log lines visible from both containers via the shared volume. |
| D5 | Persistent storage, survives Pod delete | PVCs: `postgres` data via `volumeClaimTemplates` (`helm/veloshare/charts/postgres/templates/statefulset.yaml:66-73`, 1Gi), `fleet-monitor-reports` (`helm/veloshare/charts/fleet-monitor/templates/pvc.yaml`, 100Mi), plus `elasticsearch` data PVC when logging is on (`helm/veloshare/charts/logging/templates/elasticsearch-statefulset.yaml:79-85`, 2Gi). Standalone hands-on lab: [`pvc-demo.yaml`](../k8s/labs/pvc-demo.yaml) (write data, delete Pod, recreate, verify). | `kubectl -n veloshare get pvc` (expect `data-postgres-0`, `fleet-monitor-reports`). Persistence demo: `kubectl apply -f k8s/labs/pvc-demo.yaml && kubectl -n veloshare exec pvc-demo-pod -- sh -c 'echo hi > /data/f'; kubectl -n veloshare delete pod pvc-demo-pod; kubectl apply -f k8s/labs/pvc-demo.yaml; kubectl -n veloshare exec pvc-demo-pod -- cat /data/f` → `hi`. |
| D6 | Labels for selection, rollout identity, blue/green readiness | `veloshare.selectorLabels` / `veloshare.labels` (`helm/veloshare/templates/_helpers.tpl:43-63`) put `app.kubernetes.io/name` + `app.kubernetes.io/instance` on every resource; Deployment `selector.matchLabels` uses the immutable subset so it survives upgrades. Blue/green readiness demoed standalone at [`bluegreen-demo.yaml`](../k8s/labs/bluegreen-demo.yaml) — two Deployments labelled `color: blue`/`color: green`, one Service selecting on `color`. | `kubectl -n veloshare get pods --show-labels -l app.kubernetes.io/name=rider`. Blue/green flip: `kubectl apply -f k8s/labs/bluegreen-demo.yaml && kubectl -n veloshare patch svc bluegreen-demo -p '{"spec":{"selector":{"color":"green"}}}'`. |

## 4.2 Application Deployment

| ID | Requirement (short) | Where it's implemented | How to verify |
|---|---|---|---|
| P1 | Deployments, ≥1 replica | `replicaCount: 1` in every app subchart's `values.yaml` (rider, station, trip, pricing, frontend, redis — confirmed by grep across `helm/veloshare/charts/*/values.yaml`). | `kubectl -n veloshare get deploy -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas`. |
| P2 | Documented rolling update procedure | `CLAUDE.md` "After changing one service's code" and `docs/ADMIN_GUIDE.md` "Redeploying after a code change" both give the same three-step procedure (rebuild → `kind load` → `kubectl rollout restart`); Deployments use the default `RollingUpdate` strategy (unset = default in `apps/v1`). A bare `rollout restart` re-pulls the same tag, though — for a demo of an actual image change, `make images-demo-tag` builds+loads `pricing:0.2.0`, then `kubectl -n veloshare set image deploy/pricing pricing=veloshare/pricing:0.2.0` (or apply `k8s/overlays/prod`) triggers a real rollout you can prove via `GET /version`. | `docker build -t veloshare/pricing:0.1.0 ./pricing && kind load docker-image veloshare/pricing:0.1.0 --name veloshare && kubectl -n veloshare rollout restart deploy/pricing && kubectl -n veloshare rollout status deploy/pricing`. Real-image variant: `make images-demo-tag && kubectl -n veloshare set image deploy/pricing pricing=veloshare/pricing:0.2.0 && kubectl -n veloshare rollout status deploy/pricing && kubectl -n veloshare exec deploy/pricing -c ambassador -- curl -s 127.0.0.1:8080/version`. |
| P3 | Blue/green or canary demo | Blue/green via Service selector flip, standalone lab [`bluegreen-demo.yaml`](../k8s/labs/bluegreen-demo.yaml) (two Deployments `color: blue`/`color: green`, `Service` initially selects blue). Documented flip command in the file's trailing comment (`k8s/labs/bluegreen-demo.yaml:153-155`) and as `make bluegreen-demo` in `CLAUDE.md`. | `kubectl apply -f k8s/labs/bluegreen-demo.yaml` (or `make bluegreen-demo` if present), `curl localhost:PORTFWD` shows BLUE, then `kubectl -n veloshare patch svc bluegreen-demo -p '{"spec":{"selector":{"color":"green"}}}'` and re-curl shows GREEN — no Deployment touched either way. |
| P4 | HPA, CPU target | `helm/veloshare/charts/pricing/templates/hpa.yaml`, `autoscaling/v2`, target 70% CPU, min 1 / max 5 replicas; enabled by default (`pricing.autoscaling.enabled: true`, `helm/veloshare/charts/pricing/values.yaml:26-29`). `metrics-server` is **not part of `make up`** so utilization shows `<unknown>` until it's installed. | `kubectl -n veloshare get hpa pricing`. For real metrics: `make metrics-server` (applies the upstream `components.yaml` and patches in `--kubelet-insecure-tls`, which kind requires because its kubelet serving certs aren't CA-signed), then `kubectl -n veloshare get hpa pricing` shows a real percentage and `kubectl -n veloshare top pods` works. |
| P5 | Kustomize base + ≥1 overlay | [`kustomize-demo/base/`](../k8s/labs/kustomize-demo/base) (a standalone nginx Deployment, not a real veloshare service — see design notes below) plus **two** overlays: [`overlays/dev/`](../k8s/labs/kustomize-demo/overlays/dev) (1 replica, floating tag `1.27-alpine`, base resources) and [`overlays/prod/`](../k8s/labs/kustomize-demo/overlays/prod) (3 replicas, pinned tag `1.27.4-alpine`, plus a strategic-merge patch raising the container's resources). Uses Kustomize's built-in `images:`/`replicas:` transformers and a patch file. The **real** overlays over actual veloshare services, [`k8s/overlays/dev`](../k8s/overlays/dev) and [`k8s/overlays/prod`](../k8s/overlays/prod) (generated by `make gen-k8s`), now differ in three ways instead of two: image tag (`veloshare/pricing:0.1.0` vs `:0.2.0`, both genuinely built via `make images-demo-tag`), replicas (1 vs 2 per API), and the ResourceQuota (`resourcequota-patch.yaml`, prod only). | `kubectl kustomize k8s/labs/kustomize-demo/overlays/dev` → `replicas: 1`, `1.27-alpine`; `kubectl kustomize k8s/labs/kustomize-demo/overlays/prod` → `replicas: 3`, `1.27.4-alpine`, bumped limits. Apply with `kubectl apply -k k8s/labs/kustomize-demo/overlays/dev` (the overlay pulls in `../../base` itself). Real-overlay diff: `diff <(kubectl kustomize k8s/overlays/dev) <(kubectl kustomize k8s/overlays/prod)` → image tag + replicas + ResourceQuota all differ. Proof of which image a Pod actually runs: `kubectl -n veloshare exec deploy/pricing -c ambassador -- curl -s 127.0.0.1:8080/version` → `{"service":"pricing","version":"0.1.0"}` (dev) or `"0.2.0"` (prod). |
| P6 | Helm chart, values override, upgrade + rollback | Umbrella chart `helm/veloshare` (`Chart.yaml`, 9 subchart dependencies), values overridable via `--set`/`-f` (e.g. `global.logging.enabled`, `global.resourceQuota.*` — see `helm/veloshare/values.yaml:83-90`). `Makefile:39-53` wraps `helm upgrade --install`, `helm history`, `helm rollback`. | `make deploy` (installs/upgrades) → `make history` (or `helm -n veloshare history veloshare`) → `make rollback REV=<n>` (or `helm -n veloshare rollback veloshare <n>`). |

## 4.3 Application Environment, Configuration & Security

| ID | Requirement (short) | Where it's implemented | How to verify |
|---|---|---|---|
| C1 | ConfigMap(s) as env and/or volume | **Env**: `pricing` ConfigMap (`helm/veloshare/charts/pricing/templates/configmap.yaml`, `envFrom`) and `trip` ConfigMap (`helm/veloshare/charts/trip/templates/configmap.yaml`, `PRICING_URL`/`RIDER_URL`/`REDIS_HOST`/etc, also `envFrom`). **Volume**: `<svc>-migration` ConfigMaps (rider/station/trip, mounted at `/migrations`), `<svc>-ambassador` ConfigMaps (nginx conf via `subPath`), `postgres-init` ConfigMap (`/docker-entrypoint-initdb.d`), `fluent-bit-config` (`/fluent-bit/etc/`). | `kubectl -n veloshare get configmap` (expect `pricing`, `trip`, `rider-migration`, `station-migration`, `trip-migration`, `rider-ambassador`, `station-ambassador`, `trip-ambassador`, `pricing-ambassador`, `postgres-init`, `fluent-bit-config`). `kubectl -n veloshare exec deploy/trip -c trip -- env | grep PRICING_URL`. |
| C2 | Secret(s) for credentials | `postgres`, `rider-db`, `station-db`, `trip-db`, `veloshare-auth` — all created **out of band** by `scripts/apply-secrets.sh` (invoked via `make secrets`) from local, gitignored `env/*.env` files, never by Helm. Consumed via `envFrom.secretRef` (e.g. `helm/veloshare/charts/rider/templates/deployment.yaml:34-36,54-57`). See "Deliberate design decisions" for why `helm template` renders zero Secrets. | `kubectl -n veloshare get secret` (5 Secrets). `helm template veloshare ./helm/veloshare | grep -c '^kind: Secret'` → `0`. |
| C3 | SecurityContext (non-root, no priv-esc, drop ALL, read-only rootfs) | Two shared helpers applied to **every** Pod/container in the platform: `veloshare.podSecurityContext` (`runAsNonRoot: true`, `fsGroup`, `seccompProfile: RuntimeDefault` — `_helpers.tpl:72-77`) and `veloshare.containerSecurityContext` (`allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `runAsNonRoot: true`, `capabilities.drop: [ALL]` — `_helpers.tpl:92-103`). One deliberate exception: the `set-vm-max-map-count` init container on `elasticsearch` runs `privileged: true` (see design notes). | `kubectl -n veloshare get pod -l app.kubernetes.io/name=rider -o jsonpath='{.items[0].spec.containers[0].securityContext}'` → shows all four fields. `helm template veloshare ./helm/veloshare | grep -c 'privileged: true'` → `0` (only `1` with `--set global.logging.enabled=true`). |
| C4 | Custom ServiceAccount + Role + RoleBinding | `pod-lister` ServiceAccount/Role/RoleBinding (`helm/veloshare/templates/rbac-demo-serviceaccount.yaml`, `rbac-demo-role.yaml` — `get/list/watch` on `pods` only, namespace-scoped — `rbac-demo-rolebinding.yaml`), bound to the `pod-lister` CronJob (`rbac-demo-cronjob.yaml`, `serviceAccountName: pod-lister`, `automountServiceAccountToken: true`), whose `services/pod-lister/list-pods.sh` calls the API server with the mounted SA token. | `kubectl -n veloshare get sa,role,rolebinding pod-lister`; `kubectl -n veloshare create job --from=cronjob/pod-lister pods-now && kubectl -n veloshare wait --for=condition=complete job/pods-now --timeout=30s && kubectl -n veloshare logs job/pods-now`. |
| C5 | ResourceQuota + LimitRange | `helm/veloshare/templates/resourcequota.yaml` (`veloshare-quota`: 500m/1200Mi requests, 2/2560Mi limits, 15 pods) and `helm/veloshare/templates/limitrange.yaml` (`veloshare-limits`: per-container default/defaultRequest/min/max), values in `helm/veloshare/values.yaml:91-121`. Sized to fit the default (logging-off) render with headroom; enabling logging deliberately exceeds it — raise example is inline at `values.yaml:83-88`. | `kubectl -n veloshare get resourcequota veloshare-quota -o yaml`; `kubectl -n veloshare describe limitrange veloshare-limits`. Demo of rejection: `helm upgrade veloshare ./helm/veloshare -n veloshare --set global.logging.enabled=true` — the `elasticsearch`/`kibana` Pods are rejected outright by quota admission control (ResourceQuota enforces at Pod-creation time, not after); confirm with `kubectl -n veloshare get events --sort-by=.lastTimestamp | grep -i quota` and `kubectl -n veloshare get pod` showing no `elasticsearch-0`/`kibana` Pod created. Raise the quota per the `--set` example at `values.yaml:83-88` to let them through. |
| C6 | Every container has requests+limits | Every container in every Deployment/StatefulSet/CronJob template sets `resources:` from its subchart's `values.yaml` (`resources`, `migrate.resources`, `configCheck.resources`, `ambassador.resources`, `initCheck.resources`) or the shared `veloshare.loggingSidecar` helper (`_helpers.tpl:118-124`, hardcoded 10m/48Mi–50m/96Mi). Verified: rendering each app Deployment's container-name list against its `resources:` block count matches 1:1 (e.g. rider = 5 containers, 5 `resources:` blocks). | `kubectl -n veloshare get pod -l app.kubernetes.io/name=rider -o jsonpath='{range .items[0].spec.initContainers[*]}{.name}{"="}{.resources}{"\n"}{end}{range .items[0].spec.containers[*]}{.name}{"="}{.resources}{"\n"}{end}'` — every container prints a non-empty `requests`/`limits` map. |

## 4.4 Services and Networking

| ID | Requirement (short) | Where it's implemented | How to verify |
|---|---|---|---|
| N1 | ClusterIP for internal traffic | `rider`, `station`, `trip`, `pricing`, `postgres`, `redis` Services — all default (unset) type = `ClusterIP` (e.g. `helm/veloshare/charts/rider/templates/service.yaml:9`, explicit `type: ClusterIP`). | `kubectl -n veloshare get svc rider station trip pricing postgres redis -o custom-columns=NAME:.metadata.name,TYPE:.spec.type`. |
| N2 | External exposure (NodePort or Ingress) | Both: `frontend` Service is `type: NodePort` (`helm/veloshare/charts/frontend/templates/service.yaml:9`), and two Ingress objects front the platform — `veloshare` (`helm/veloshare/templates/ingress.yaml`) and `veloshare-api` (`helm/veloshare/templates/ingress-api.yaml`), class `nginx`, via `ingress-nginx.yaml` / `make ingress`. | `kubectl -n veloshare get svc frontend -o jsonpath='{.spec.type} {.spec.ports[0].nodePort}'`; `kubectl -n veloshare get ingress`; `curl -sS http://localhost/`. |
| N3 | Ingress ≥2 path/host rules to different backends | Two Ingress objects together route to two distinct backends by default: `veloshare` → `path: /` → Service `frontend:80` (`ingress.yaml:29-35`); `veloshare-api` → `path: /api/healthz` (`pathType: Exact`) → Service `rider:80` (`ingress-api.yaml:38-44`, with a `rewrite-target: /healthz` annotation, kept as a **separate** Ingress object so the rewrite doesn't leak onto `/`). With `global.logging.enabled=true`, the `veloshare` Ingress itself grows a second rule, `/kibana` → `kibana:5601` (`ingress.yaml:20-28`). | `kubectl -n veloshare get ingress -o yaml | grep -E 'path:|service:|name:'`; `curl -sS http://localhost/api/healthz` (→ rider `/healthz`) vs `curl -sS http://localhost/` (→ frontend). |
| N4 | NetworkPolicy allow/deny | `backend-isolation` (`helm/veloshare/templates/networkpolicy-backend.yaml`) selects rider/station/trip/pricing; ingress allowed only from the `ingress-nginx` namespace, `frontend`, and other backend Pods (ports 8080/8000); egress allowed only to DNS (`kube-system`), `postgres:5432`, `redis:6379`, other backends, and (logging on) `elasticsearch:9200` — everything else denied by default-deny-once-selected semantics. Verified live per the in-file comment (`networkpolicy-backend.yaml:5-9`): deleting it live turned a 504 on `/api/healthz` into a 200. | Denied path: `kubectl -n veloshare run probe --rm -it --image=curlimages/curl --restart=Never --labels=app.kubernetes.io/name=probe -- curl -sS --max-time 5 http://rider/healthz` (hangs/fails). Allowed path: `kubectl -n veloshare exec deploy/frontend -- wget -qO- http://rider/healthz` (or curl from a `frontend`-labelled Pod) succeeds. |
| N5 | Endpoints verified, no orphan Services | Every Service's `selector` matches its Deployment/StatefulSet's Pod labels via the shared `veloshare.selectorLabels` helper — no hand-written selectors to drift. `ambassador.enabled` (true everywhere) means the Service `targetPort` is 8080 (ambassador), not 8000 (app), matched consistently in `service.yaml` and the ambassador container's `containerPort` (e.g. `helm/veloshare/charts/rider/templates/service.yaml:13-19`). | `kubectl -n veloshare get endpoints` — every Service (rider/station/trip/pricing/frontend/postgres/redis) has ≥1 IP:port; none show `<none>`. |

## 4.5 Application Observability and Maintenance

| ID | Requirement (short) | Where it's implemented | How to verify |
|---|---|---|---|
| O1 | Liveness probe, every long-running Deployment | HTTP `GET <probePath>` (default `/healthz`) on rider/station/trip/pricing (e.g. `helm/veloshare/charts/rider/templates/deployment.yaml:66-73`); HTTP `/` on frontend; `exec redis-cli ping` on redis; `exec pg_isready` on postgres; `httpGet /_cluster/health`+`tcpSocket` on elasticsearch/kibana when logging is on. | `kubectl -n veloshare get pod -l app.kubernetes.io/name=rider -o jsonpath='{.items[0].spec.containers[0].livenessProbe}'`. |
| O2 | Readiness probe, every long-running Deployment | Same probes as O1, each service also has a `readinessProbe` block (e.g. `deployment.yaml:74-81` for rider) — liveness and readiness intentionally use the same check here since each app is a single-endpoint FastAPI service. | `kubectl -n veloshare get pod -l app.kubernetes.io/name=rider -o jsonpath='{.items[0].spec.containers[0].readinessProbe}'`; drop-readiness-live demo: use the standalone [`probes-demo.yaml`](../k8s/labs/probes-demo.yaml) lab instead (file-based readiness — see O3), since breaking a real service's `/healthz` in place risks a liveness-triggered restart loop rather than a clean readiness-only drop. |
| O3 | Startup probe on ≥1 slow-start service, or documented why not | `elasticsearch` (`helm/veloshare/charts/logging/templates/elasticsearch-statefulset.yaml:68-74`, 30×10s) and `kibana` (`kibana-deployment.yaml`, 40×15s) both have `startupProbe` — only rendered when `global.logging.enabled=true`, since they're the only slow (JVM/Node) starters in the platform. The four FastAPI services and postgres/redis start in well under a second, so they deliberately have no `startupProbe` (documented in `CLAUDE.md` "Helm structure"). A focused, standalone startup-probe lab (with liveness + file-based readiness alongside it) lives at [`probes-demo.yaml`](../k8s/labs/probes-demo.yaml). | `helm template veloshare ./helm/veloshare --set global.logging.enabled=true | grep -A4 startupProbe`. Standalone lab: `kubectl apply -f k8s/labs/probes-demo.yaml && kubectl -n veloshare get pod probes-demo -w` (stays `0/1` past the 30s sleep until you `kubectl -n veloshare exec probes-demo -- touch /tmp/ready`). |
| O4 | README debug section (logs/describe/events/top) | `README.md` "Khắc phục sự cố" (Vietnamese) and `docs/ADMIN_GUIDE.md` "Troubleshooting runbook" (English) both give `kubectl logs`/`describe`/`get events`/`top` recipes; `CLAUDE.md` "Diagnostics" is the canonical short list (`get pods -o wide`, `get svc,endpoints`, `describe pod`, `get events --sort-by`, `top pods`, `logs -c <container>`). | `kubectl -n veloshare get pods -o wide`, `kubectl -n veloshare describe pod <pod>`, `kubectl -n veloshare get events --sort-by=.lastTimestamp`, `kubectl -n veloshare top pods` (needs metrics-server, see P4). |
| O5 | Current stable APIs only | Confirmed by grepping every manifest under `helm/veloshare/templates`, every subchart's `templates/`, and the standalone lab files: only `apps/v1` (Deployment/StatefulSet), `batch/v1` (CronJob), `v1` (Service/ConfigMap/Secret*/PVC/ServiceAccount/Pod/Namespace/ResourceQuota/LimitRange), `networking.k8s.io/v1` (Ingress/NetworkPolicy), `rbac.authorization.k8s.io/v1` (Role/RoleBinding), `autoscaling/v2` (HPA). No `extensions/v1beta1` or other deprecated group anywhere. (*Secrets are never rendered by Helm — see C2.) | `grep -rhn '^apiVersion' helm/veloshare/templates helm/veloshare/charts/*/templates | awk '{print $2}' | sort -u`. |

---

## Deliberate design decisions

A grader skimming the cluster state might read these as gaps — they are intentional, and each is
documented in-repo at the cited location.

- **`helm template` renders zero Secrets.** Every credential (DB passwords, `JWT_SECRET`, admin
  login) lives only in local, gitignored `env/*.env` files (`env/*.env.template` is what's
  committed) and is pushed into the cluster directly by `scripts/apply-secrets.sh` (invoked via
  `make secrets`) as `kubectl create secret generic --from-env-file`. Helm templates only ever
  reference a Secret by name (`envFrom.secretRef`), so nothing sensitive can leak into a rendered
  manifest, `helm get manifest` output, or git history, even by accident. See `CLAUDE.md`
  "Secrets" and `env/*.env.template`.
- **EFK (Elasticsearch/Kibana) is off by default.** `global.logging.enabled: false`
  (`helm/veloshare/values.yaml:39-41`). The pair costs ~350m CPU / 400Mi more requested and
  ~1500m CPU / 640Mi more limited than the namespace `ResourceQuota` allows alongside the 6 core
  app Pods + postgres + redis, each with their ambassador/log-agent sidecars. The `log-agent`
  sidecar and shared `logs` emptyDir stay in place regardless — only Fluent Bit's *output* target
  changes between stdout and Elasticsearch (`helm/veloshare/charts/logging/templates/fluentbit-configmap.yaml:42-59`).
  Turn it on with `--set global.logging.enabled=true` plus the quota-raise example inline at
  `values.yaml:83-88`.
- **`k8s/labs/kustomize-demo/` is standalone, not an overlay on a real service.** It patches a
  placeholder nginx Deployment (`kustomize-demo-app`) rather than, say, `frontend` or `pricing`,
  so it never claims ownership of a live umbrella-chart resource. The real Kustomize overlays —
  `k8s/overlays/dev` and `k8s/overlays/prod`, generated from the Helm chart by
  `scripts/gen-k8s.sh` (`make gen-k8s`) — cover the actual services and are a genuine alternative
  deploy path to Helm, applied via `scripts/deploy.sh kubectl [dev|prod]`; that script refuses to
  run one path while the other owns the namespace, so Helm and the raw `k8s/` path can never fight
  over the same live resource. Same standalone reasoning as the kustomize lab applies to
  `k8s/labs/bluegreen-demo.yaml`, `k8s/labs/pvc-demo.yaml`, and `k8s/labs/probes-demo.yaml`: all are standalone,
  hand-applied labs with their own `app.kubernetes.io/component` label, not umbrella-chart or
  overlay members.
- **One privileged container, by necessity.** `elasticsearch`'s `set-vm-max-map-count` init
  container (`helm/veloshare/charts/logging/templates/elasticsearch-statefulset.yaml:26-38`) runs
  `privileged: true` to raise the host's `vm.max_map_count` kernel parameter — Elasticsearch
  refuses to start below that limit, and setting a host-wide sysctl is fundamentally incompatible
  with non-root/read-only hardening. It only exists when `global.logging.enabled=true`; the
  `elasticsearch` container itself still runs non-root with a read-only root filesystem via
  `veloshare.containerSecurityContext`.
- **The `pricing` `wait-for-deps` init container is a deliberate anti-pattern demo.** `pricing` is
  stateless and calls neither `rider` nor Postgres, but the init container waits for both anyway,
  purely to demonstrate the wait-for-dependency pattern (comment at
  `helm/veloshare/charts/pricing/templates/deployment.yaml:25-30`). Toggle with
  `pricing.initCheck.enabled: false`.

## Steps needed before an item is demonstrable

| Item | Extra step |
|---|---|
| P4 (HPA actually scaling under load) | Run `make metrics-server` first — it's not part of `make up`/`make deploy`. Until then `kubectl -n veloshare get hpa pricing` shows `TARGETS: <unknown>/70%`. |
| P3 (blue/green flip) | `make bluegreen-demo` first (not part of the Helm release) — creates `bluegreen-demo-blue`/`-green` Deployments and the `bluegreen-demo` Service pointed at blue, then prints the exact flip/verify commands. Tear down with `make bluegreen-clean`. |
| P5 (Kustomize overlay) | Apply an overlay directly — `kubectl apply -k k8s/labs/kustomize-demo/overlays/dev` or `.../prod` — each pulls in `../../base` via its own `resources:`, so the base needs no separate apply. Diff the two with `diff <(kubectl kustomize k8s/labs/kustomize-demo/overlays/dev) <(kubectl kustomize k8s/labs/kustomize-demo/overlays/prod)`. |
| O3 / probe behavior lab | `kubectl apply -f k8s/labs/probes-demo.yaml` — standalone Pod, not part of the chart. |
| D5 persistence demo | `kubectl apply -f k8s/labs/pvc-demo.yaml`, write a file, `kubectl delete pod pvc-demo-pod`, `kubectl apply -f k8s/labs/pvc-demo.yaml` again, re-read the file. |
| C5 quota-rejection demo | Either lower `global.resourceQuota` below the default footprint, or raise it and flip on `global.logging.enabled=true` to see the *opposite* direction (Pods fitting only after the raise) — both are one `helm upgrade --set` away, no code change. |
| N4 NetworkPolicy denial | Needs a throwaway Pod with a label outside `{rider,station,trip,pricing,frontend}` and outside the `ingress-nginx` namespace — the `curlimages/curl` one-off in the N4 row above. |
| C4 RBAC demo | `kubectl -n veloshare create job --from=cronjob/pod-lister pods-now` to trigger it on demand rather than waiting for its 5-minute schedule. |

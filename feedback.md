# Capstone Review — Pham Quang Diep

| Field | Value |
|-------|-------|
| Trainee | Pham Quang Diep |
| Repository | https://github.com/dieppq/Online_Learning.git |
| Domain | Online learning (LearnHub) — user, course, enrollment, payment, notification + web-ui |
| Reviewed path | `capstone/` (primary deliverable) + supporting `services/`, `k8s/` |
| Review date | 2026-08-06 |
| Review type | Repository / manifest review (no live cluster demo) |
| Rubric | **CKAD 50% · Microservices 50%**; pass ≥ **90** (instructor override of default §7) |
| Rescore | 2026-08-06 — 50/50 rubric + min 90 + pattern audit + Helm review |

---

## Score: **82 / 100** — **FAIL** (below minimum 90)

Instructor pass threshold: ≥ **90 / 100**, with all §4 Required CKAD items present.  
(Default `capstone-requirements.md` threshold was 70; this review uses **90**.)

| Pillar | Max | Score |
|--------|----:|------:|
| CKAD (§4 domains) | 50 | **43** |
| Microservices (§3 + patterns depth) | 50 | **39** |
| **Total** | **100** | **82** |

**Gap to pass:** **−8** points.

Score assumes instructor waives the plaintext-lab-Secret automatic-fail risk (see below). Even with that waiver, **82 < 90**.

**History:** 88 (default rubric) → 86 (pattern audit) → 82 (50/50) → status **FAIL** under minimum **90**.

---

## Rubric breakdown (50 / 50)

### A. CKAD — 50 points

| Area | Max | Score | Verdict |
|------|----:|------:|---------|
| Design & Build (§4.1) | 10 | **9.5** | Images, Job/CronJob, init+sidecar, emptyDir, PVC, labels |
| Deployment (§4.2) | 10 | **9** | Rolling, blue/green, HPA, Kustomize strong; Helm = P6 demo chart |
| Config & Security (§4.3) | 12 | **9** | Capstone CM/Secret/SC/RBAC/quota strong; plaintext lab Secrets deduct |
| Networking (§4.4) | 10 | **9** | ClusterIP, Ingress multi-path, NetworkPolicy default-deny |
| Observability + docs (§4.5) | 8 | **6.5** | Probes + runbook excellent; live demo not verified |
| **CKAD subtotal** | **50** | **43** | |

### B. Microservices — 50 points

| Area | Max | Score | Verdict |
|------|----:|------:|---------|
| Bounded contexts / service count | 10 | **9** | 5 backends + web-ui; clear capability split |
| Independent deployability | 8 | **8** | Own Dockerfile, image, Deployment per service |
| API contracts & health | 8 | **7** | Stable HTTP APIs + `/healthz`/`/readyz`; business logic mock |
| Data ownership & sync/async | 12 | **5** | Shared PG; NATS/Redis/MinIO declared; events mocked in responses |
| DNS / gateway / east-west | 6 | **6** | ClusterIP DNS + Ingress gateway routing |
| Pattern depth / no distributed monolith | 6 | **4** | Strong K8s patterns; shared `internal/platform`; weak real integration |
| **Microservices subtotal** | **50** | **39** | |

---

## Microservices design & principal patterns

### Core design (present)

| Pattern / principle | How it appears |
|---------------------|----------------|
| Bounded context / single responsibility | Separate services: user, course, enrollment, payment, notification (+ web-ui) |
| Independent deployability | Own Dockerfile, Deployment, image tag per service |
| API-first / HTTP resource APIs | REST-ish JSON paths (`/api/users`, `/api/courses`, …) |
| Health contracts | `/healthz` + `/readyz` on every service |
| Externalized config | ConfigMap + Secret via `envFrom`; no env baked into images |
| Service discovery via DNS | ClusterIP + short names (`http://course-service`) |
| API Gateway / edge routing | Ingress path/host routing (north–south) |
| Decomposition by business capability | Online-learning domain split by capability, not by tech layer |

### Communication & integration

| Pattern | Status |
|---------|--------|
| Sync request/response (HTTP) | **Real** — client → Ingress → services |
| Async messaging / event-driven | **Mostly mock** — payment returns `"event":"payment.completed"` and names NATS; no real publish/subscribe code |
| Shared database | **Declared** — one PostgreSQL for several services (anti-pattern unless justified) |
| Polyglot persistence (intended) | **Declared only** — PG + Redis + MinIO + NATS in config/diagram, not really used in Go code |

### Kubernetes / cloud-native patterns (stronger than app patterns)

| Pattern | Where |
|---------|--------|
| Sidecar | Nginx ambassador proxy + log-tailer on course |
| Init container | `init-runtime-config` writing into `emptyDir` |
| Ambassador / proxy sidecar | Service targets proxy port, not main directly |
| Blue/green deployment | `course-service-blue` / `green` + Service `track` flip |
| Horizontal scaling | HPA on course |
| Bulkhead / isolation (network) | NetworkPolicy default-deny + allow lists |
| Least privilege | Dedicated SA + Role/RoleBinding for reporter CronJob |
| Immutable / declarative deploy | Kustomize base/overlays + Helm chart |
| Stateless app + attached state | Deployments + PVC for PG/MinIO/proof |
| Batch / scheduled work | Job + CronJob |

### Shared-kernel / platform

- `internal/platform` shared Go helpers (health, JSON, env, graceful shutdown) — common in monorepos; can drift toward a **distributed monolith** if the shared kernel grows too far.

### Not really implemented

- Database-per-service  
- Real event bus consumers  
- Saga / outbox / CQRS  
- Service mesh, circuit breaker, retries/timeouts as libraries  
- BFF as a separate backend (web-ui is mostly static front talking through Ingress)

### Pattern audit summary

The design follows classic microservice **decomposition, independent deploy, HTTP APIs, config externalization, and edge gateway**. Deeper integration patterns (events, DB-per-service) are **architected on paper** more than implemented in code. The strongest patterns in this repo are the **K8s multi-container and deployment patterns** (sidecar, init, blue/green, HPA, NetworkPolicy).

Under the **50% Microservices** weight, that paper-vs-code gap matters more: strong service split (9+8+7+6) but weak data/async/pattern depth (5+4) → **39 / 50**.

### Helm chart quality (feeds CKAD Deployment / P6)

| Criterion | Assessment |
|-----------|------------|
| Meets §4.2 P6 | Yes — installable chart, values override, upgrade + rollback documented |
| Design quality | Solid starter / exam-style chart (`Chart.yaml`, helpers, Deployment/Service/SA/HPA, NOTES) |
| Production-grade | No — single-service demo only; no env values files, tests, Ingress/NP/PVC templates; ConfigMap/Secret refs are `optional: true` |

---

## Automatic-fail checklist

| Condition | Status |
|-----------|--------|
| Fewer than 3 independently deployable services | Clear — 5 backends + web-ui |
| App only via docker-compose, no K8s Deployments | Clear — full `capstone/k8s` |
| Secrets committed in plaintext to git | **Triggered** — see note |
| No Ingress and no NodePort/LoadBalancer | Clear — Ingress present |
| Cannot show Pods Ready in assigned namespace | Not evaluated (repo-only review) |

**Plaintext secrets note:** Capstone correctly uses `create-secret.ps1` + `secrets/*.example` and gitignores real env files. However the same repo still commits:

- `k8s/base/secret.yaml`
- `k8s/infra/secret.yaml`
- `k8s/labs/lab-3.1-configmap-secret-injection/jwt-secret.txt`

These contain lab passwords (`learnhub-postgres-lab-password`, JWT, MinIO, SMTP). Per §7 this is an automatic fail. Recommend deleting those manifests (or replacing with SealedSecret / external create scripts) before final grade lock. Score **82** is the technical quality score **if this condition is waived**.

---

## Required items (§4) — evidence summary

### 4.1 Design & Build — mostly complete

| ID | Result | Evidence |
|----|--------|----------|
| D1 | Pass | Dockerfile per service + `capstone/web/Dockerfile`; multi-stage Go → `scratch`; tagged `0.1.0` / `0.1.2` (not `:latest`) |
| D2 | Pass | Deployments + `secret-check-job` Job + `api-access-cronjob` CronJob |
| D3 | Pass | `course-service-blue/green`: init + ambassador nginx sidecar + log-tailer |
| D4 | Pass | `emptyDir` for runtime-config, proxy-logs, nginx-tmp |
| D5 | Pass | PVC on PostgreSQL, MinIO, `storage-proof` |
| D6 | Pass | `app.kubernetes.io/*`, `track`, `version` labels; blue/green selector flip |

### 4.2 Deployment — complete

| ID | Result | Evidence |
|----|--------|----------|
| P1 | Pass | Long-running Deployments with replicas ≥1 (often 2) |
| P2 | Pass | Documented `kubectl set image` + `rollout status` in demo script |
| P3 | Pass | Blue/green on course (`track` selector + switch scripts/patches) |
| P4 | Pass | `course-service-hpa` (CPU 50%, min 2 / max 5) |
| P5 | Pass | `base/` + overlays `dev` / `prod` (replicas, images, ingress) |
| P6 | Pass | `capstone/helm/learnhub-course` with upgrade/rollback commands (single-service demo chart) |

### 4.3 Config & Security — strong in capstone; lab Secrets issue

| ID | Result | Evidence |
|----|--------|----------|
| C1 | Pass | `learnhub-config` ConfigMap via `envFrom` |
| C2 | Pass* | Capstone Secret created at deploy time; *plaintext lab Secrets elsewhere in repo |
| C3 | Pass | `runAsNonRoot`, drop `ALL`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem` on app workloads |
| C4 | Pass | `learnhub-app` + `learnhub-reporter` SA; Role/RoleBinding; CronJob uses reporter SA |
| C5 | Pass | ResourceQuota + LimitRange |
| C6 | Pass | requests/limits on app, init, sidecars, and infra containers checked |

### 4.4 Networking — complete

| ID | Result | Evidence |
|----|--------|----------|
| N1 | Pass | ClusterIP for APIs and infra |
| N2 | Pass | Ingress (`ingressClassName: nginx`) |
| N3 | Pass | Many path rules (≥2) including regex enrollment vs user path |
| N4 | Pass | default-deny + DNS egress + ingress-nginx + internal allow + reporter API egress |
| N5 | Pass | Smoke-test script documents endpoint checks |

### 4.5 Observability & docs — complete (demo not live-verified)

| ID | Result | Evidence |
|----|--------|----------|
| O1/O2 | Pass | Liveness + readiness on long-running Deployments |
| O3 | Pass | Startup probe on course main containers |
| O4 | Pass | Debug section in README + demo script (`logs` / `describe` / `events` / `top`) |
| O5 | Pass | Stable APIs (`apps/v1`, `networking.k8s.io/v1`, `autoscaling/v2`, `batch/v1`) |

---

## Strengths

1. **Capstone packaging is instructor-ready** — dedicated `capstone/` tree with README, architecture, checklist, demo script, proposal, build/deploy/smoke/blue-green scripts.
2. **CKAD surface area is unusually complete** — init + multiple sidecars, emptyDir, Job + CronJob, PVC proof Job, blue/green, HPA, Kustomize overlays, Helm upgrade/rollback, NetworkPolicy default-deny, RBAC least privilege for reporter.
3. **Image hygiene** — explicit tags; Go multi-stage to `scratch` with non-root UID 10001.
4. **Ingress design quality** — careful path ordering / regex so `/api/users/{id}/courses` hits enrollment, not user-service.
5. **Demo UX** — web-ui routes + Platform API catalog make a live walkthrough easier.
6. **Clear capability boundaries** — five services map cleanly to online-learning bounded contexts.

---

## Gaps / improvements (why not higher)

1. **Plaintext Secrets in non-capstone paths** (auto-fail risk) — remove or externalize `k8s/base/secret.yaml` and `k8s/infra/secret.yaml`.
2. **Business logic is mock-only** — services return canned JSON; PostgreSQL/Redis/NATS/MinIO are wired in config but not really used as owned datastores. **Costs more under 50% Microservices weight.**
3. **Shared PostgreSQL + mock events** — architecture advertises async/NATS and polyglot stores; implementation does not follow through.
4. **Helm is exam-minimal** — one critical service only; fine for P6, not a full-app chart.
5. **Scripts are PowerShell-only** — fine for Windows/Docker Desktop; class Linux clusters usually expect `.sh` equivalents.
6. **`storage-reader-job.yaml` not in base `kustomization.yaml`** — orphaned relative to applied set.
7. **Infra Deployments** lighter on SecurityContext than app Deployments.
8. **Live demo not scored** — Pod readiness / NetworkPolicy enforcement / HPA behavior not verified on a cluster in this review.

---

## Suggested feedback to trainee (short)

> Score is **82/100** against a **90** minimum — not yet passing. CKAD half is strong (43/50). To close the ~8-point gap, prioritize the Microservices half: implement real NATS publish/consume (or remove the async claim), justify or split shared PostgreSQL, and remove plaintext Secret YAMLs from `k8s/base` and `k8s/infra`. A solid live demo may also recover Observability points currently held back for unverified cluster behavior.

---

## Path to ≥ 90 (approx. +8)

| Action | Likely gain | Pillar |
|--------|------------:|--------|
| Real async path (payment → NATS → notification/enrollment) **or** honest de-scope in docs | +3–5 | Microservices |
| Own-data justification or schema-per-service / separate stores | +2–3 | Microservices |
| Remove plaintext Secrets from git | +2–3 | CKAD Config & Security |
| Verified live demo (probes, NP, HPA, PVC, Helm rollback) | +1–1.5 | CKAD Observability |

---

## Recommendation

| Decision | Detail |
|----------|--------|
| Grade | **82 / 100** (CKAD 43 + Microservices 39) |
| Status | **FAIL** — below instructor minimum **90** |
| Rubric used | CKAD 50% · Microservices 50%; pass ≥ 90 |
| Action for trainee | Close Microservices gaps (events/data ownership) + delete plaintext Secret manifests; re-demo |
| Action for instructor | Confirm live demo §6.3; re-grade after remediation |

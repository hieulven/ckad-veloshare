# Capstone Project Requirements — QNET CKAD Intensive

**Course:** Certified Kubernetes Application Developer (CKAD) — 5-day intensive  
**Purpose:** Apply CKAD skills and microservices practices by deploying a real multi-service application on Kubernetes.

---

## 1. Overview

The Capstone is an **individual project** (unless the instructor assigns pairs). You design, containerize, and deploy a **business-domain microservices application** on a Kubernetes cluster, demonstrating the skills from the course and the five CNCF CKAD exam domains.

| Goal | Expectation |
|------|-------------|
| CKAD application | Every mandatory CKAD checklist item below is implemented and demonstrable |
| Microservices | 3–5 independently deployable services with clear boundaries and K8s networking |
| Production-minded | Config/Secrets, probes, security context, quotas, packaging — not “hello world” Pods |
| Exam mindset | Namespace discipline, declarative YAML, `kubectl` fluency, debug-ready manifests |

---

## 2. Project scope

### 2.1 Business domain

Choose a coherent business domain. Example ideas:

| Domain | Typical services |
|--------|------------------|
| Flight tracking bot | bot, flight, sync, subscription, notification |
| Real estate listings | user, listing, inquiry, frontend |
| E-commerce checkout | identity, catalog, order, payment, notification |
| Stock prediction | gateway, auth, prediction, API, frontend |
| Real-time chat | identity, chat, websocket gateway, presence, notification |
| Weather alerts | user, fetcher, evaluator, dispatcher |
| Network observability | ingest, analytics (+sidecar), alert-manager, timeseries |
| TCP load balancing | gateway, backend-worker, redis state |
| E-invoice gateway | identity/tenant, invoice core, tax gateway, notification/portal |
| City bike-share | rider, station, trip, pricing, fleet |
| Online shop | product, cart/order, payment, user, frontend |
| Cinema booking | movie, booking, payment, notification, gateway |
| Online learning | user, course, enrollment, payment, notification |
| AI data prep pipeline | ingest, processing jobs, storage stages (Jobs/CronJobs) |

Any domain is acceptable if it supports **3–5 services** and the CKAD checklist below. Confirm your topic with the instructor before you invest heavily in code.

### 2.2 Service count

| Rule | Requirement |
|------|-------------|
| Minimum | **3** microservices (separate Deployments/workloads) |
| Target | **4–5** microservices |
| Maximum counted for grading | **5** core services (extra optional services allowed but not required) |
| Frontend | Optional web UI or CLI/bot entrypoint counts as one service if it runs in-cluster |

Each service must have its **own** container image (or clearly distinct process), Deployment (or Job/CronJob/StatefulSet where justified), and Service where traffic is expected.

---

## 3. Microservices standards

### 3.1 Service boundaries

| Standard | Requirement |
|----------|-------------|
| Single responsibility | Each service owns one bounded context (e.g. orders ≠ payments ≠ notifications) |
| Independent deployability | Updating one service must not require rebuilding all others |
| Own data (preferred) | Prefer schema-per-service or clearly isolated data stores; shared DB only if justified in README |
| Sync vs async | Document how services talk: HTTP/gRPC and/or message bus (RabbitMQ, NATS, Redis Pub/Sub, Kafka, etc.) |
| No “distributed monolith” | Avoid one Deployment with unrelated processes stuffed into one Pod unless using a documented sidecar/init pattern |

### 3.2 API & contracts

| Standard | Requirement |
|----------|-------------|
| Health endpoints | At least one HTTP (or TCP/exec) health path per long-running service for probes |
| Stable ports | Document container ports; Services use correct `port` / `targetPort` |
| Versioning awareness | Image tags must be explicit (`:1.0.0` or digests) — avoid `:latest` in Capstone manifests |
| Config externalized | No secrets or environment-specific values hard-coded in images; use ConfigMaps/Secrets |

### 3.3 Container standards

| Standard | Requirement |
|----------|-------------|
| Dockerfile per service | Buildable images; multi-stage build recommended where language allows |
| Non-root runtime | Align with SecurityContext requirements (see §4.3) |
| Resource awareness | Every container declares `requests` and `limits` (CPU + memory) |
| Stateless by default | Long-running APIs as Deployments; persistence via PVC / external DB, not container local disk alone |

### 3.4 Inter-service communication on Kubernetes

| Standard | Requirement |
|----------|-------------|
| ClusterIP for east-west | Backend services exposed via ClusterIP (or headless where justified) |
| DNS discovery | Clients use Kubernetes DNS (`svc-name.namespace.svc.cluster.local` or short name in-namespace) |
| Ingress for north-south | External HTTP entry via Ingress (path and/or host routing) |
| Network isolation | NetworkPolicy restricts which Pods may talk to which backends |
| Labels & selectors | Consistent app labels (`app`, `tier`, `version` or equivalent); Services match Pod labels |

### 3.5 Observability expectations

| Standard | Requirement |
|----------|-------------|
| Structured logs to stdout/stderr | Sidecar may ship/tail logs |
| Probes | Liveness + readiness on every long-running Deployment; startup probe optional for slow starts |
| Debuggability | Someone else can diagnose your app with `kubectl logs`, `describe`, `get events`, and `top` alone |

---

## 4. Mandatory CKAD requirements

Items marked **Required** must appear in your submitted cluster state and repository.

### 4.1 Application Design and Build (20%)

| # | Requirement | Level |
|---|-------------|-------|
| D1 | Custom container images for each core service (Dockerfile + build/tag documented) | **Required** |
| D2 | Workloads chosen correctly: Deployment for APIs; Job and/or CronJob for batch/sync; DaemonSet only if justified | **Required** (Deployment + ≥1 Job **or** CronJob) |
| D3 | Multi-container pattern: init container **and/or** sidecar in at least one Pod | **Required** (≥1 of init or sidecar; **both** preferred) |
| D4 | Ephemeral volume (`emptyDir`) used meaningfully (shared logs/config between containers) | **Required** if multi-container |
| D5 | Persistent storage: ≥1 PVC mounted; data survives Pod delete/recreate | **Required** |
| D6 | Labels used for selection, rollout identity, and blue/green or canary readiness | **Required** |

### 4.2 Application Deployment (20%)

| # | Requirement | Level |
|---|-------------|-------|
| P1 | All long-running services as Deployments with ≥1 replica (HPA may raise this) | **Required** |
| P2 | Documented rolling update procedure (`kubectl set image` / apply + `rollout status`) | **Required** |
| P3 | One advanced strategy demo: **blue/green** (Service selector flip) **or** canary (weighted replicas / second Deployment) | **Required** (choose one) |
| P4 | HPA on at least one Deployment (CPU target; metrics-server available) | **Required** |
| P5 | Kustomize: `base/` + ≥1 overlay (e.g. `dev` / `prod`) patching image and/or replicas | **Required** |
| P6 | Helm: chart (own or wrapped) installable with values override; show upgrade + rollback | **Required** (may package the whole app or one critical service) |

### 4.3 Application Environment, Configuration & Security (25%)

| # | Requirement | Level |
|---|-------------|-------|
| C1 | ConfigMap(s) injected as env and/or volume | **Required** |
| C2 | Secret(s) for credentials/tokens/DB passwords (env and/or volume) | **Required** |
| C3 | SecurityContext on ≥1 workload: `runAsNonRoot`, `allowPrivilegeEscalation: false`, drop `ALL` capabilities; `readOnlyRootFilesystem` where feasible | **Required** |
| C4 | Custom ServiceAccount + Role + RoleBinding; at least one Pod uses that SA for least-privilege API access (or documented in-cluster need) | **Required** |
| C5 | ResourceQuota **and** LimitRange on the project namespace | **Required** |
| C6 | Every container has CPU/memory `requests` and `limits` | **Required** |

### 4.4 Services and Networking (20%)

| # | Requirement | Level |
|---|-------------|-------|
| N1 | ClusterIP Services for internal microservice traffic | **Required** |
| N2 | At least one external exposure pattern: NodePort **or** Ingress (Ingress strongly preferred) | **Required** |
| N3 | Ingress with ≥2 path **or** host rules routing to different backends | **Required** |
| N4 | NetworkPolicy: default-deny or explicit allow for frontend→backend; restrict egress where sensible | **Required** |
| N5 | Endpoints verified; no orphan Services (selector/port mismatches fixed) | **Required** |

### 4.5 Application Observability and Maintenance (15%)

| # | Requirement | Level |
|---|-------------|-------|
| O1 | Liveness probe on every long-running Deployment | **Required** |
| O2 | Readiness probe on every long-running Deployment | **Required** |
| O3 | Startup probe on ≥1 slow-start service **or** documented why not needed | Recommended |
| O4 | README section: how to debug with `kubectl logs` / `describe` / `events` / `top` | **Required** |
| O5 | Manifests use current stable APIs (no deprecated `extensions/v1beta1` Ingress, etc.) | **Required** |

---

## 5. Cluster & tooling constraints

| Item | Requirement |
|------|-------------|
| Kubernetes | v1.35.x compatible (or the class cluster version announced by the instructor) |
| Namespace | Dedicated namespace assigned by the instructor — all resources scoped here |
| CNI | Policy-capable CNI required for NetworkPolicy demos |
| Ingress controller | Must be available in the cluster (e.g. ingress-nginx) |
| metrics-server | Required for HPA |
| StorageClass | Default StorageClass for dynamic PVC |
| CLI | `kubectl`, `helm` v3, Kustomize via `kubectl apply -k` |
| Out of scope | Cluster install, etcd, node ops (CKA); service mesh; full GitOps platforms; custom operators |

---

## 6. Deliverables

### 6.1 Source repository

A Git repository accessible to the instructor, containing:

```text
/
├── README.md                 # Domain, architecture, runbook, CKAD checklist
├── docs/
│   ├── architecture.md       # Service diagram, data flow, sync/async
│   └── ckad-checklist.md     # Map of §4 items → paths / resource names
├── services/
│   └── <svc>/
│       ├── Dockerfile
│       └── ...               # Application source
├── k8s/
│   ├── base/                 # Or raw manifests
│   ├── overlays/dev/
│   ├── overlays/prod/
│   ├── network/              # NetworkPolicies, Ingress
│   ├── security/             # SA, Role, RoleBinding, SecurityContext samples
│   ├── quota/                # ResourceQuota, LimitRange
│   └── storage/              # PVC(s)
├── helm/
│   └── <chart>/              # Application or service chart
└── scripts/
    ├── build.sh              # Build & tag images
    ├── deploy.sh             # Apply Kustomize/Helm into namespace
    └── smoke-test.sh         # Curl / basic E2E checks
```

Exact layout may differ; README must point to equivalent paths.

### 6.2 Documentation (README minimum)

1. Business domain and user story (short)
2. List of microservices and responsibilities
3. Architecture diagram (Mermaid or image)
4. Prerequisites (cluster tools, secrets to create)
5. Build & deploy steps (copy-pasteable)
6. How to verify each CKAD mandatory item (§4)
7. Demo script (5–10 minutes)
8. Known limitations

### 6.3 Live demo

You must demonstrate on a live cluster:

1. All Pods Running / Ready; Services have Endpoints
2. Ingress (or NodePort) hits frontend/API paths
3. ConfigMap/Secret injection
4. Probe behavior (optional: break readiness and show Service endpoints drop)
5. Rolling update or blue/green switch
6. HPA object present (`kubectl get hpa`)
7. NetworkPolicy effect (allowed vs denied path)
8. PVC persistence after Pod recreate
9. Helm history / rollback **or** Kustomize overlay apply

### 6.4 Project proposal

Submit (or update) a short proposal to the instructor with:

- Business domain
- 3–5 microservices
- Technical stack
- Git repository URL (when available)

---

## 7. Acceptance criteria & rubric

**Pass threshold:** ≥ **70 / 100** and **all Required** items in §4 present.

| Area | Points | Notes |
|------|--------|-------|
| Microservices design (§3) | 15 | Clear boundaries, DNS, contracts, no distributed monolith |
| Design & Build (§4.1) | 20 | Images, workloads, multi-container, PVC |
| Deployment (§4.2) | 20 | Rollout, blue-green/canary, HPA, Kustomize, Helm |
| Config & Security (§4.3) | 20 | CM/Secret, SecurityContext, RBAC, quotas, requests/limits |
| Networking (§4.4) | 15 | Services, Ingress, NetworkPolicy |
| Observability (§4.5) + docs/demo | 10 | Probes, debug runbook, live demo quality |

### Automatic fail conditions

- Fewer than 3 independently deployable services
- Application only runs via `docker compose` with no Kubernetes Deployment
- Secrets committed in plaintext to git
- No Ingress **and** no NodePort / LoadBalancer exposure
- Cannot show Pods Ready in the assigned namespace during demo

---

## 8. What “good” looks like

A strong Capstone is a **small but real** microservice system that can be deployed from your documented scripts and then walked through the CKAD surface area: multi-container Pods, Jobs/CronJobs, Deployments with rollout strategies, ConfigMaps/Secrets, SecurityContexts, RBAC, quotas, Services/Ingress/NetworkPolicy, PVC, probes, Helm, and Kustomize — all in one namespace, without needing a service mesh or cluster-admin privileges.

---

*Aligned to CNCF CKAD exam domains (Kubernetes v1.35).*

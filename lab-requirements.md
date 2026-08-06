# CKAD Lab Requirements — Days 3–5

Instructor-assigned lab schedule, restructured into a runnable, step-by-step demo.
Every lab in this document is implemented under [`lab/`](./lab/) and executed by
[`lab/run-lab.sh`](./lab/run-lab.sh).

Two ground rules shape the whole suite:

**Everything runs in the `veloshare-lab` namespace, never `veloshare`.**
Half of these labs exist to break something on purpose — a rejected Pod, an empty
Endpoints list, denied egress, a container failing its probe. Doing that in the
live namespace would fight the Helm release for ownership and take the platform
down mid-demo.

**Every lab acts on a real VeloShare service, not a stock image.**
No `nginx:alpine` placeholders. The object under test is always something this
project built and ships: `veloshare/pricing:0.1.0`, `veloshare/frontend:0.1.0`,
`veloshare/pod-lister:0.1.0`.

> **Scope note.** This document covers **Days 3, 4 and 5** — the twelve labs in the
> instructor's schedule as supplied. Days 1 and 2 were not included in the source
> material and are not implemented here.

---

## Running the labs

```sh
lab/run-lab.sh                 # all 12 labs in order, pausing between each
lab/run-lab.sh 4.3             # a single lab
lab/run-lab.sh day4            # a single day
lab/run-lab.sh --auto          # unattended; exits non-zero if any check fails
lab/run-lab.sh --no-pause      # all labs back to back, still verbose
lab/run-lab.sh --list          # list the labs
lab/run-lab.sh --clean         # delete the veloshare-lab namespace
```

Each step prints, in order: what it is about to prove, the exact command with a
`$` prefix, that command's unedited output, and a `✓ PASS` / `✗ FAIL` line. The
exit code is 0 only if every check passed, which makes `--auto` usable as a
cluster regression test and not just a presentation.

### Prerequisites

| Requirement | How to get it | Needed by |
|---|---|---|
| kind cluster `veloshare` up | `make up` | all |
| Images built and side-loaded | `make images && make load` (or `scripts/build.sh`) | all |
| ingress-nginx installed | `make ingress` (part of `make up`) | 4.2 |
| `helm` v3 on PATH | — | 5.4 |
| metrics-server | `make metrics-server` | 5.2 (`kubectl top` only) |

No `env/*.env` credentials are required. `veloshare/pricing` is the one service
with no mandatory secret — `PRICING_UNLOCK_FEE_CENTS` and `PRICING_TIER_RATES`
both have code defaults — which is precisely why it is the subject of most of
these labs. The lab namespace needs no database and no JWT key.

---

## The twelve labs

| # | Lab | Duration | CKAD domain | VeloShare object under test |
|---|---|---|---|---|
| 3.1 | [ConfigMap & Secret Injection](./lab/day3/3.1-configmap-secret/) | ~45 min | Config & Security (25%) | `pricing` — fare tiers as config |
| 3.2 | [Security Context Lockdown](./lab/day3/3.2-security-context/) | ~45 min | Config & Security (25%) | `pricing` — non-root uid 10001 |
| 3.3 | [ServiceAccount & RBAC](./lab/day3/3.3-rbac/) | ~60 min | Config & Security (25%) | `pod-lister` — calls the API with its SA token |
| 3.4 | [Namespace Quotas](./lab/day3/3.4-quota/) | ~45 min | Config & Security (25%) | `pricing` — scaled past the ceiling |
| 4.1 | [ClusterIP & NodePort](./lab/day4/4.1-clusterip-nodeport/) | ~45 min | Services & Networking (20%) | `pricing` (backend) + `frontend` |
| 4.2 | [Ingress Routing](./lab/day4/4.2-ingress/) | ~60 min | Services & Networking (20%) | `frontend` on `/`, `pricing` on `/api` |
| 4.3 | [NetworkPolicy Isolation](./lab/day4/4.3-networkpolicy/) | ~45 min | Services & Networking (20%) | `frontend` → `pricing` |
| 4.4 | [Persistent Volume Claims](./lab/day4/4.4-pvc/) | ~45 min | Networking / Design & Build | `pricing` — its real JSON log file |
| 5.1 | [Self-Healing App](./lab/day5/5.1-probes/) | ~45 min | Observability (15%) | `pricing` — `/healthz` |
| 5.2 | [CLI Observability](./lab/day5/5.2-cli-observability/) | ~45 min | Observability (15%) | `pricing` + `ambassador` sidecar |
| 5.3 | [Broken YAML Triage](./lab/day5/5.3-broken-yaml/) | ~45 min | Observability (15%) | `pricing` — three seeded bugs |
| 5.4 | [Helm Deploy & Rollback](./lab/day5/5.4-helm/) | ~45 min | Deployment (20%) | `lab-pricing` chart wrapping the image |

---

## Day 3 — Configuration & security

### Lab 3.1 — ConfigMap & Secret Injection

**Duration:** ~45 min · **CKAD domain:** Application Environment, Configuration & Security (25%)

**Objectives**

1. Create Secret from file and ConfigMap from literal
2. Inject Secret as env var and ConfigMap as mounted volume in one Pod

**How it is demonstrated.** The Secret is built with `--from-file` from
`lab/day3/3.1-configmap-secret/credentials/` (two dummy files, keys taken from
the filenames); the ConfigMap with `--from-literal`, carrying fare values that
differ from the platform defaults. One Pod consumes both — the Secret as env
vars, the ConfigMap as a volume at `/etc/veloshare/config`.

The ConfigMap is *also* wired in via `envFrom`, so `GET /tiers` returns
`unlock_fee_cents: 250` instead of the `100` compiled into
`services/pricing/main.py`. That turns "the config is mounted" into "the app is
demonstrably using it".

---

### Lab 3.2 — Security Context Lockdown

**Duration:** ~45 min · **CKAD domain:** Application Environment, Configuration & Security (25%)

**Objectives**

1. Run Pod as non-root with read-only root filesystem
2. Drop all capabilities; disable privilege escalation

**How it is demonstrated.** The same four settings the whole platform runs under
(`veloshare.podSecurityContext` / `veloshare.containerSecurityContext` in
`helm/veloshare/templates/_helpers.tpl`), written out literally so they can be
read without Helm. Each one is then proved from *inside* the container — `id`,
`grep CapEff /proc/self/status`, `grep NoNewPrivs`, and a `touch /nope` that
fails with `Read-only file system`.

The counter-example sets `runAsUser: 0` against `runAsNonRoot: true` and lands in
`CreateContainerConfigError` — while `kubectl apply` still reports success, which
is the point.

---

### Lab 3.3 — ServiceAccount & RBAC

**Duration:** ~60 min · **CKAD domain:** Application Environment, Configuration & Security (25%)

**Objectives**

1. Create ServiceAccount, Role, RoleBinding
2. Pod uses SA token to list Pods in namespace via API

**How it is demonstrated.** `veloshare/pod-lister` talks to the API server with
**curl**, not `kubectl` (`services/pod-lister/list-pods.sh`), so the
token → `Authorization: Bearer` → API call chain is visible in nine lines of
bash. Using `kubectl` inside the Pod would hide exactly the part the objective is
about.

Four `kubectl auth can-i --as=system:serviceaccount:...` calls establish the
boundary in one command each: may list pods, may **not** delete pods, may **not**
list secrets, and may not do any of it in another namespace. A second Job with no
`serviceAccountName` shows the 403 — delivered as a response body from a Job that
otherwise "succeeded".

---

### Lab 3.4 — Namespace Quotas

**Duration:** ~45 min · **CKAD domain:** Application Environment, Configuration & Security (25%)

**Objectives**

1. Apply ResourceQuota and LimitRange
2. Observe Pod rejection when quota exceeded

**How it is demonstrated.** A quota of 1 CPU / 2Gi requested plus a LimitRange
with defaults and min/max, then **two** rejections that surface completely
differently:

| Applied object | Where the error appears |
|---|---|
| Deployment (4 × 2 CPU) | `apply` says `created`; `get deploy` shows `0/4`; the error is a `FailedCreate` event on the **ReplicaSet** |
| Bare Pod (over LimitRange max) | `apply` itself fails with `Error from server (Forbidden)` |

A Deployment stuck at `0/N` with **no Pods at all** — not Pending, *absent* — is
the signature of a quota rejection. This is the same mechanism that keeps
Elasticsearch and Kibana out of the live namespace by default; see CLAUDE.md
"Logging".

---

## Day 4 — Networking & storage

### Lab 4.1 — ClusterIP & NodePort

**Duration:** ~45 min · **CKAD domain:** Services and Networking (20%)

**Objectives**

1. Create ClusterIP backend and NodePort frontend
2. Diagnose and fix selector mismatch
3. Verify Endpoints

**How it is demonstrated.** The backend Service is named `pricing` deliberately:
`veloshare/frontend`'s baked-in nginx config proxies `/api/pricing/` to
`http://pricing/`, so the real image works unmodified against the lab's Service.
The selector is then broken on purpose (`app.kubernetes.io/name: pricing-api`,
which nothing has), diagnosed by comparing `svc -o jsonpath='{.spec.selector}'`
against `get pods --show-labels`, and repaired with a single apply.

Empty Endpoints is always one of exactly two things: the selector matches no Pod
labels, or no matching Pod is Ready.

---

### Lab 4.2 — Ingress Routing

**Duration:** ~60 min · **CKAD domain:** Services and Networking (20%)

**Objectives**

1. Route `/` to frontend and `/api` to backend via Ingress
2. Verify via ingress controller endpoint

**How it is demonstrated.** Two Ingress **objects**, not two rules on one object:
`nginx.ingress.kubernetes.io/rewrite-target` applies to every path in the object
it is set on, so combining them would rewrite `/` as well. The platform learned
this from a real incident — the long comment in
`helm/veloshare/templates/ingress-api.yaml` documents it.

Both set `host: lab.veloshare.local`, because the live `veloshare` Ingress is
host-less and therefore matches any `Host` header on `/`. Verification goes
through the controller with `curl -H 'Host: lab.veloshare.local'`, not a
port-forward.

---

### Lab 4.3 — NetworkPolicy Isolation

**Duration:** ~45 min · **CKAD domain:** Services and Networking (20%)

**Objectives**

1. Allow frontend → backend traffic only
2. Deny backend egress to internet (`0.0.0.0/0`)

**How it is demonstrated.** Default-deny first, then the minimum set of allows:
DNS to `kube-system`, frontend → pricing on 8000, and the ingress-nginx namespace
so lab 4.2 keeps working. An unauthorised client Pod (labelled
`netpol-client`, not `frontend`) proves the denial — and it **hangs** rather than
refusing, because a dropped packet looks like a timeout. That is how you tell a
NetworkPolicy apart from a wrong port.

Egress to the internet is denied the only way the API allows: by allow-listing
the cluster CIDRs and thereby excluding everything else. There is no deny rule in
the NetworkPolicy API.

> The runner removes this lab's policies afterwards. `podSelector: {}` selects
> every Pod in the namespace, so leaving default-deny in place would silently
> isolate the Day 5 workloads. Re-apply any time with
> `kubectl apply -f lab/day4/4.3-networkpolicy/`.

---

### Lab 4.4 — Persistent Volume Claims

**Duration:** ~45 min · **CKAD domain:** Services and Networking / Design and Build

**Objectives**

1. Provision 1Gi PVC with dynamic provisioning
2. Mount in Pod, write data, delete Pod, recreate, verify persistence

**How it is demonstrated.** The PVC is mounted at `/var/log/veloshare` — where
`pricing` genuinely writes its JSON log — so the thing being persisted is the
service's real data, not a synthetic test file. Five real HTTP requests generate
log lines, a marker file is appended, the Pod is deleted outright, recreated from
the same manifest, and the marker is read back.

The PVC sitting `Pending` before the first Pod mounts it is correct, not broken:
StorageClass `standard` uses `volumeBindingMode: WaitForFirstConsumer`.

---

## Day 5 — Observability & exam prep

### Lab 5.1 — Self-Healing App

**Duration:** ~45 min · **CKAD domain:** Application Observability and Maintenance (15%)

**Objectives**

1. Configure HTTP liveness probe
2. Configure file-based readiness probe
3. Optional: startup probe for slow-start container

**How it is demonstrated.** All three probes on one container, plus a Service so
the effect is visible in Endpoints rather than only in Pod status. The readiness
probe is `cat /tmp/ready`, so the Pod runs but stays `0/1` until you
`kubectl exec ... touch /tmp/ready`, at which point the endpoint appears.
Removing the file again drops the endpoint **while `RESTARTS` stays 0** — which
is the entire difference between readiness and liveness, demonstrated rather than
asserted.

While the startup probe is running, liveness and readiness are suspended. That is
the only reason startup probes exist.

---

### Lab 5.2 — CLI Observability

**Duration:** ~45 min · **CKAD domain:** Application Observability and Maintenance (15%)

**Objectives**

1. Use `kubectl logs` with `-c` and `--previous`
2. Read Events from `describe` and `get events`
3. Use `kubectl top` for resource usage

**How it is demonstrated.** A two-container Pod — `pricing` plus the `ambassador`
nginx sidecar the real platform uses — makes `-c` necessary rather than
decorative: `kubectl logs deploy/lab-observe` without it fails and lists both
container names. A separate Pod crashes on purpose every few seconds, because
`--previous` is meaningless without a container that *has* a previous instance,
and it is the only way to see why a `CrashLoopBackOff` container died.

`kubectl top` needs metrics-server; the lab says so and points at
`make metrics-server` rather than pretending otherwise.

---

### Lab 5.3 — Broken YAML Triage

**Duration:** ~45 min · **CKAD domain:** Application Observability and Maintenance (15%)

**Objectives**

1. Fix selector mismatch in Deployment
2. Fix Service `targetPort` mismatch
3. Fix invalid image name

**How it is demonstrated.** Three independent break/fix pairs, each on its own
resource so they can be diagnosed separately — with matching `broken/` and
`fixed/` manifests plus a [`SYMPTOMS.md`](./lab/day5/5.3-broken-yaml/) lookup
table. They fail in three genuinely different ways:

| Bug | Fails at | What you see |
|---|---|---|
| Selector mismatch | API **validation** | `kubectl apply` is rejected; nothing is created |
| `targetPort` mismatch | **Runtime** | Endpoints are populated and the Pod is Ready — and nothing works |
| Bad image tag | **Image pull** | `ErrImagePull` → `ImagePullBackOff` |

The middle one is the nastiest and the most instructive: everything looks healthy.

---

### Lab 5.4 — Helm Deploy & Rollback

**Duration:** ~45 min · **CKAD domain:** Application Deployment (20%)

**Objectives**

1. Install Helm chart with value overrides
2. Upgrade release and rollback to previous revision

**How it is demonstrated.** A small self-contained chart,
`lab/day5/5.4-helm/lab-pricing/`, wrapping `veloshare/pricing:0.1.0`. It is
deliberately standalone rather than the umbrella chart's `pricing` subchart,
which cannot be installed on its own because its `_helpers.tpl` lives in the
parent.

The proof of which revision is live is the app's own `GET /tiers`:
`unlock_fee_cents` comes from the chart's ConfigMap, so install → `100`, upgrade
with `--set fare.unlockFeeCents=375` → `375`, roll back → `100` again. The chart
carries the `checksum/config` annotation, without which a ConfigMap-only change
would update the ConfigMap and never restart the Pods.

Rollback appends a new revision rather than deleting one — which is what makes
rolling back itself reversible.

---

## Mapping to the capstone requirements

These labs and the capstone are graded separately, but they overlap heavily.
Where a lab also satisfies a `§4` Required item from
[`capstone-requirements.md`](./capstone-requirements.md), the platform-level
evidence is in [`docs/ckad-checklist.md`](./docs/ckad-checklist.md).

| Lab | Also demonstrates |
|---|---|
| 3.1 | C1 (ConfigMap as env + volume), C2 (Secret) |
| 3.2 | C3 (SecurityContext) |
| 3.3 | C4 (ServiceAccount + Role + RoleBinding) |
| 3.4 | C5 (ResourceQuota + LimitRange), C6 (requests/limits) |
| 4.1 | N1 (ClusterIP), N2 (NodePort), N5 (Endpoints verified) |
| 4.2 | N2, N3 (≥2 path rules to different backends) |
| 4.3 | N4 (NetworkPolicy allow/deny) |
| 4.4 | D5 (persistent storage surviving Pod delete) |
| 5.1 | O1 (liveness), O2 (readiness), O3 (startup probe) |
| 5.2 | O4 (debug runbook: logs / describe / events / top) |
| 5.3 | O5, N5 — triage of selector, port and image faults |
| 5.4 | P6 (Helm install with overrides, upgrade, rollback) |

Not covered by these twelve labs, because the instructor's Day 3–5 schedule does
not include them: D1–D4, D6, P1–P5 (rolling updates, blue/green, HPA, Kustomize).
Those are demonstrated at platform level — see `scripts/demo.sh` and
`k8s/labs/`.

# `lab/` — CKAD Day 3–5 labs

Implementation of the instructor's lab schedule. The narrative version, with
objectives and per-lab explanation, is [`../lab-requirements.md`](../lab-requirements.md);
this file is the map.

Everything here runs in the **`veloshare-lab`** namespace and acts on **this
project's own images** (`veloshare/pricing`, `veloshare/frontend`,
`veloshare/pod-lister`) rather than a stock nginx. Nothing here touches the live
`veloshare` release.

```sh
make lab                  # or: lab/run-lab.sh — all 12 labs, paused between each
make lab LAB=4.3          # one lab
make lab LAB=day4         # one day
make lab-auto             # unattended; non-zero exit if any check fails
make lab-list             # list the labs
make lab-clean            # delete the veloshare-lab namespace
```

## Layout

```text
lab/
├── run-lab.sh                       the runner — one bash function per lab
├── 00-namespace.yaml                the veloshare-lab namespace
├── day3/                            Configuration & security
│   ├── 3.1-configmap-secret/        Secret --from-file, ConfigMap --from-literal
│   ├── 3.2-security-context/        non-root, read-only rootfs, drop ALL
│   ├── 3.3-rbac/                    SA + Role + RoleBinding, SA-token API call
│   └── 3.4-quota/                   ResourceQuota + LimitRange, two rejections
├── day4/                            Networking & storage
│   ├── 4.1-clusterip-nodeport/      ClusterIP + NodePort, selector-mismatch triage
│   ├── 4.2-ingress/                 / -> frontend, /api -> pricing
│   ├── 4.3-networkpolicy/           default-deny, frontend->backend, no internet
│   └── 4.4-pvc/                     1Gi PVC surviving Pod delete/recreate
└── day5/                            Observability & exam prep
    ├── 5.1-probes/                  liveness + file-based readiness + startup
    ├── 5.2-cli-observability/       logs -c / --previous, events, top
    ├── 5.3-broken-yaml/             three seeded bugs, broken/ + fixed/ pairs
    └── 5.4-helm/                    lab-pricing chart: install, upgrade, rollback
```

Each lab directory has its own `README.md` with the objectives, a file table,
copy-pasteable verification commands with expected output, and exam notes.

## Conventions

Every manifest in here declares `resources.requests` **and** `resources.limits`,
because lab 3.4 applies a ResourceQuota to the namespace and a container without
them would be rejected from that point on.

Every Pod carries the platform's hardening baseline — `runAsNonRoot`, numeric
`runAsUser`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`,
`capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault` — with writable
`emptyDir` mounts wherever a read-only root filesystem forces one. The numeric
`runAsUser` is not decoration: `veloshare/pricing`'s Dockerfile sets `USER
appuser` by **name**, which `runAsNonRoot` cannot verify, so omitting it produces
`CreateContainerConfigError` on every Pod. Lab 3.2 covers this.

Manifests under a `broken/` or `rejected/` directory are meant to fail. Each one
documents its expected symptom in a header comment, and `fixed/` holds the
repaired version where there is one.

## Relationship to `k8s/labs/`

Separate things, deliberately kept apart:

- **`lab/`** (here) — the instructor's Day 3–5 schedule, on VeloShare's own
  images, in `veloshare-lab`, driven by one script.
- **`k8s/labs/`** — older standalone teaching labs (blue/green, PVC, probes,
  kustomize-demo) against public images, applied by hand into `veloshare`, and
  referenced from `docs/ckad-checklist.md` as capstone evidence.

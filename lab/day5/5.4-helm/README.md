# Lab 5.4 — Helm Deploy & Rollback

**Duration:** ~45 min · **CKAD domain:** Application Deployment (20%)

## Objectives (instructor)

1. Install Helm chart with value overrides
2. Upgrade release and rollback to previous revision

## VeloShare object under test

`veloshare/pricing:0.1.0`, wrapped in a small, self-contained Helm chart
(`lab-pricing/`) that does **not** depend on the umbrella chart's
`_helpers.tpl` — it carries its own copies of the name/label helpers so it
can be `helm install`-ed on its own, the way this lab does it. `GET /tiers`
(`unlock_fee_cents` in particular) is the proof-of-life used throughout:
it is the one number this chart's ConfigMap controls that you can read back
from inside the Pod without any extra tooling.

## Files

| File | Purpose |
|---|---|
| `lab-pricing/Chart.yaml` | Chart metadata — apiVersion v2, name `lab-pricing`, version 0.1.0. |
| `lab-pricing/values.yaml` | Defaults: replica count, image, service port, fare config, resources. Every key commented. |
| `lab-pricing/templates/_helpers.tpl` | Standalone `lab-pricing.name`/`.fullname`/`.labels`/`.selectorLabels` — does not call the umbrella chart's `veloshare.*` helpers. |
| `lab-pricing/templates/configmap.yaml` | `PRICING_UNLOCK_FEE_CENTS` / `PRICING_TIER_RATES`, from `.Values.fare`. |
| `lab-pricing/templates/deployment.yaml` | The Deployment — envFrom the ConfigMap, `/healthz` probes, hardened securityContext, writable emptyDirs, `checksum/config` annotation. |
| `lab-pricing/templates/service.yaml` | ClusterIP Service. |
| `lab-pricing/templates/NOTES.txt` | Printed after install/upgrade — status/list commands, the `/tiers` proof-of-life exec, upgrade and rollback commands. |

## Verify

The full lifecycle. `GET /tiers` is checked after every step so you can see
exactly which revision's config is actually live — that is the point of the
exercise, not just that the commands succeed.

```sh
helm -n veloshare-lab install lab-pricing lab/day5/5.4-helm/lab-pricing
helm -n veloshare-lab list
kubectl -n veloshare-lab rollout status deploy/lab-pricing

kubectl -n veloshare-lab exec deploy/lab-pricing -- \
  python -c "import urllib.request,json;print(json.load(urllib.request.urlopen('http://127.0.0.1:8000/tiers'))['unlock_fee_cents'])"
# 100

helm -n veloshare-lab upgrade lab-pricing lab/day5/5.4-helm/lab-pricing \
  --set fare.unlockFeeCents=375 --set replicaCount=2
kubectl -n veloshare-lab rollout status deploy/lab-pricing

kubectl -n veloshare-lab exec deploy/lab-pricing -- \
  python -c "import urllib.request,json;print(json.load(urllib.request.urlopen('http://127.0.0.1:8000/tiers'))['unlock_fee_cents'])"
# 375
kubectl -n veloshare-lab get pods -l app.kubernetes.io/instance=lab-pricing
# 2 Pods, both 1/1 Running

helm -n veloshare-lab history lab-pricing
# REVISION  ...  DESCRIPTION
# 1         ...  Install complete
# 2         ...  Upgrade complete

helm -n veloshare-lab rollback lab-pricing 1
kubectl -n veloshare-lab rollout status deploy/lab-pricing

kubectl -n veloshare-lab exec deploy/lab-pricing -- \
  python -c "import urllib.request,json;print(json.load(urllib.request.urlopen('http://127.0.0.1:8000/tiers'))['unlock_fee_cents'])"
# 100
kubectl -n veloshare-lab get pods -l app.kubernetes.io/instance=lab-pricing
# back to 1 Pod

helm -n veloshare-lab history lab-pricing
# REVISION  ...  DESCRIPTION
# 1         ...  Install complete
# 2         ...  Upgrade complete
# 3         ...  Rollback to 1        <-- a NEW revision, not a deleted one
```

Clean up:

```sh
helm -n veloshare-lab uninstall lab-pricing
```

## Exam notes

- `helm install <release> <chart>` fails if the release already exists;
  `helm upgrade --install <release> <chart>` is the idempotent form used in
  CI/automation — install on first run, upgrade on every run after. This
  lab uses plain `install` then `upgrade` separately so both verbs get
  exercised on purpose.
- `--set key=value` and `-f values-override.yaml` can both be given at once;
  later `--set` flags win over earlier ones, and **all** `--set` flags win
  over `-f` files, regardless of order on the command line. Prefer `-f` for
  anything more than a couple of scalar overrides — `--set` gets unreadable
  fast and mishandles lists/nested structures unless you use the `--set-json`
  / index syntax carefully.
- `helm template <release> <chart>` (or `helm install --dry-run`) renders
  manifests locally with no cluster contact at all — the fastest way to
  check a chart change before touching anything live.
- `helm history <release>` revision numbers only ever go up. A rollback
  does **not** delete or renumber history — it creates a brand new revision
  whose content matches an old one (see revision 3 above == revision 1's
  values, but it is still revision 3, not "revision 1 again").
- `helm get values <release>` shows the values actually in effect for the
  current revision (add `--revision N` for an old one); `helm get values
  <release> -a` includes chart defaults, not just your overrides.
- The `checksum/config` annotation exists because a ConfigMap change by
  itself does **not** restart Pods — `envFrom` env vars are resolved once at
  container start, and there is no controller watching ConfigMaps to
  trigger a rollout. Hashing the rendered ConfigMap into a Pod-template
  annotation is what turns "the ConfigMap changed" into "the Pod template
  changed," which is what actually causes `kubectl rollout` /
  `helm upgrade` to replace the Pods.

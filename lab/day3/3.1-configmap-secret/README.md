# Lab 3.1 — ConfigMap & Secret Injection

**Duration:** ~45 min · **CKAD domain:** Application Environment, Configuration & Security (25%)

## Objectives (instructor)

1. Create Secret from file and ConfigMap from literal
2. Inject Secret as env var and ConfigMap as mounted volume in one Pod

## VeloShare object under test

`veloshare/pricing:0.1.0`. It is the only service in the platform that reads all of
its configuration from env vars with **no** required credential
(`PRICING_UNLOCK_FEE_CENTS` and `PRICING_TIER_RATES` both have code defaults —
see `services/pricing/main.py:47-55`), which makes it the one service that can run
in an empty namespace with nothing but a ConfigMap.

That also makes the injection observable: change the ConfigMap values and
`GET /tiers` returns different numbers. The Pod is not just holding config, it is
*using* it.

## Files

| File | Purpose |
|---|---|
| `credentials/DB_PASSWORD`, `credentials/JWT_SECRET` | Source **files** for `kubectl create secret generic --from-file`. The key comes from the filename, so the filenames must be valid env var names — see the exam notes. Dummy values; the lab namespace has no database and no real signing key. |
| `pod-config-consumer.yaml` | One Pod consuming **both**: Secret as env vars, ConfigMap as a mounted volume. |

The ConfigMap is created imperatively **from literals** by the runner, exactly as
the objective asks:

```sh
kubectl -n veloshare-lab create configmap lab-pricing-config \
  --from-literal=PRICING_UNLOCK_FEE_CENTS=250 \
  --from-literal=PRICING_TIER_RATES='{"standard": 30, "member": 12, "day_pass": 7}'
```

Note the values differ from the platform defaults (100 / 15 / 8 / 5) so you can
prove at a glance that the Pod picked up *this* ConfigMap.

## The two injection styles, side by side

| | Secret `lab-pricing-creds` | ConfigMap `lab-pricing-config` |
|---|---|---|
| Created from | `--from-file` (a directory of files) | `--from-literal` (key=value pairs) |
| Injected as | **env vars** (`envFrom.secretRef`) | **volume** (mounted at `/etc/veloshare/config`) |
| Read back with | `kubectl exec -- env \| grep DB_PASSWORD` | `kubectl exec -- ls /etc/veloshare/config` |

The ConfigMap is *additionally* wired in as `envFrom.configMapRef` — that is what
makes `/tiers` change. The volume mount is the part the objective asks for; the
`envFrom` is what makes the effect visible in the HTTP response.

## Verify

```sh
# Secret -> env vars
kubectl -n veloshare-lab exec lab-config-consumer -c pricing -- \
  sh -c 'env | grep -E "^(DB_PASSWORD|JWT_SECRET)="'

# ConfigMap -> mounted files (one file per key, contents = the value)
kubectl -n veloshare-lab exec lab-config-consumer -c pricing -- ls -l /etc/veloshare/config
kubectl -n veloshare-lab exec lab-config-consumer -c pricing -- cat /etc/veloshare/config/PRICING_TIER_RATES

# ...and the app actually behaving differently because of it
kubectl -n veloshare-lab exec lab-config-consumer -c pricing -- \
  python -c "import urllib.request,json;print(json.load(urllib.request.urlopen('http://127.0.0.1:8000/tiers')))"
```

Expected last line — the lab values, not the platform defaults:

```text
{'unlock_fee_cents': 250, 'tiers': [{'tier': 'day_pass', 'per_minute_cents': 7}, {'tier': 'member', 'per_minute_cents': 12}, {'tier': 'standard', 'per_minute_cents': 30}]}
```

## Exam notes

- `--from-file=<dir>` creates **one key per file**, key = filename, value = file
  contents. `--from-file=<file>` does the same for a single file.
  `--from-file=KEY=<file>` renames the key.
- A Secret mounted as a volume is `tmpfs` (in memory), never written to the node's
  disk. A ConfigMap volume is not.
- Env vars from `envFrom` are resolved **once at container start**. Editing the
  ConfigMap afterwards does *not* update them — you need a Pod restart. A mounted
  ConfigMap *volume*, by contrast, is updated in place by the kubelet within a
  minute or so. This asymmetry is a classic exam trap; the lab shows both so you
  can see it.
- **`envFrom` silently skips keys that are not valid env var names.** This is
  the sharpest trap in the lab. A Secret key may contain hyphens and dots;
  an environment variable name may not. If the source file were called
  `db-password`, the Secret would be created without complaint, the Pod would
  start Running and Ready, and `$DB_PASSWORD` would simply not exist — no error
  anywhere in `kubectl get`, only an `InvalidVariableNames` event you have to go
  looking for. That is why `credentials/` holds `DB_PASSWORD` and `JWT_SECRET`.
  Use `env:` with `valueFrom.secretKeyRef.key` when you need to map an
  awkwardly-named key onto a legal variable name.

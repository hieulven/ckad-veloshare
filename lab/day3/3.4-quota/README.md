# Lab 3.4 — Namespace Quotas

**Duration:** ~45 min · **CKAD domain:** Application Environment, Configuration & Security (25%)

## Objectives (instructor)

1. Apply ResourceQuota and LimitRange
2. Observe Pod rejection when quota exceeded

## VeloShare object under test

`veloshare/pricing:0.1.0`, scaled to an absurd 4 × 2 CPU. The platform's real
quota (`k8s/quota/resourcequota-veloshare-quota.yaml`, 500m/1200Mi requested) is
the same mechanism at production sizing — and it is *already* doing this job in
`veloshare`: it is precisely why Elasticsearch and Kibana are off by default
(`global.logging.enabled: false`). Turning logging on without raising the quota
produces exactly the rejection this lab reproduces on purpose.

## Files

| File | Purpose |
|---|---|
| `resourcequota.yaml` | Namespace ceiling: 1 CPU / 2Gi requested, 4 CPU / 4Gi limited, plus object counts. |
| `limitrange.yaml` | Per-container defaults (mutating) and min/max (validating). |
| `rejected/deployment-oversized.yaml` | Quota rejection — surfaces on the **ReplicaSet**, not your terminal. |
| `rejected/pod-over-limitrange.yaml` | LimitRange rejection — surfaces **immediately** on your terminal. |

## The distinction this lab exists to teach

| You apply | Admission runs | Where the error appears |
|---|---|---|
| A **Pod** | Immediately | `kubectl apply` prints `Error from server (Forbidden)`. Nothing is created. |
| A **Deployment** | When the ReplicaSet controller creates Pods | `apply` says `created`. `get deploy` shows `0/4`. The error is a `FailedCreate` **event on the ReplicaSet**. |

A Deployment stuck at `0/N` with **no Pods at all** (not Pending — *absent*) is
the signature of a quota or LimitRange rejection. Pending would mean the Pod
exists and the scheduler cannot place it, which is a different problem entirely.

## Verify

```sh
# Current consumption vs ceiling — the "used / hard" view
kubectl -n veloshare-lab describe resourcequota veloshare-lab-quota
kubectl -n veloshare-lab describe limitrange veloshare-lab-limits

# Quota rejection: apply succeeds, nothing comes up
kubectl apply -f lab/day3/3.4-quota/rejected/deployment-oversized.yaml
kubectl -n veloshare-lab get deploy lab-oversized
kubectl -n veloshare-lab get pods -l lab=3.4-oversized          # "No resources found"
kubectl -n veloshare-lab describe rs -l lab=3.4-oversized | tail -6

# LimitRange rejection: apply itself fails
kubectl apply -f lab/day3/3.4-quota/rejected/pod-over-limitrange.yaml   # non-zero exit

# The events trail, which is where you'd actually start debugging
kubectl -n veloshare-lab get events --sort-by=.lastTimestamp | grep -i -E 'quota|forbidden'
```

Clean up the rejected Deployment when done:

```sh
kubectl -n veloshare-lab delete deploy lab-oversized --ignore-not-found
```

## Exam notes

- `requests.cpu` and `limits.cpu` are **separate** quota keys. Capping one does
  nothing to the other. `cpu` / `memory` (no prefix) are aliases for the
  `requests.*` form.
- Once a ResourceQuota constrains `requests.cpu` or `limits.memory`, **every**
  container in the namespace must declare that resource — or a LimitRange must
  supply a default. This is why every manifest in `lab/` carries
  `resources:` even where it is not the point of the lab.
- LimitRange `default`/`defaultRequest` are applied at admission, so
  `kubectl get pod -o yaml` shows values you never wrote. That is not a bug.
- Quota is enforced against *requests*, not actual usage. A container requesting
  2 CPU and using 10m still consumes 2 CPU of quota.
- `kubectl describe resourcequota` is the fast read: it prints `Used` next to
  `Hard` for every key.

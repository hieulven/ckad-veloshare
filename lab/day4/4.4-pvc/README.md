# Lab 4.4 — Persistent Volume Claims

**Duration:** ~45 min · **CKAD domain:** Services and Networking / Design and Build

## Objectives (instructor)

1. Provision 1Gi PVC with dynamic provisioning
2. Mount in Pod, write data, delete Pod, recreate, verify persistence

## VeloShare object under test

`veloshare/pricing:0.1.0`, mounted so its real `LOG_FILE`
(`/var/log/veloshare/app.log`, `services/pricing/main.py:20`) lands on the
PVC instead of the ephemeral `emptyDir` every other lab in this suite gives
it. The platform's own Postgres StatefulSet
(`helm/veloshare/charts/postgres`) is the "real" PVC user in `veloshare`;
this lab picks pricing instead because it lets a single stateless HTTP call
(`/healthz`) stand in for "the app wrote data," with no database bootstrap
required to prove the point.

## Files

| File | Purpose |
|---|---|
| `pvc.yaml` | `lab-pricing-logs`, 1Gi, `ReadWriteOnce`, `storageClassName: standard`. Stays `Pending` until a Pod mounts it — see the comment in the file. |
| `pod-writer.yaml` | Bare Pod `lab-pvc-writer`, mounts the PVC at `/var/log/veloshare`, `/tmp` as an `emptyDir`, `/healthz` probes. |

## Verify

```sh
kubectl apply -f lab/day4/4.4-pvc/pvc.yaml
kubectl -n veloshare-lab get pvc lab-pricing-logs        # STATUS: Pending — expected, see pvc.yaml

kubectl apply -f lab/day4/4.4-pvc/pod-writer.yaml
kubectl -n veloshare-lab wait --for=condition=ready pod/lab-pvc-writer --timeout=60s

kubectl -n veloshare-lab get pvc lab-pricing-logs         # now Bound
kubectl -n veloshare-lab get pv                            # the local-path PV it's bound to
```

Generate real log lines by hitting the app's own `/healthz` a few times from
inside the Pod:

```sh
kubectl -n veloshare-lab exec lab-pvc-writer -- \
  python -c "
import urllib.request
for _ in range(5):
    urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=5).read()
print('done')
"

kubectl -n veloshare-lab exec lab-pvc-writer -- wc -l /var/log/veloshare/app.log
# 5 /var/log/veloshare/app.log   (or more, if probes have also fired)
```

Write an explicit marker file too, so the "did the data survive" check does
not depend on remembering an exact line count:

```sh
kubectl -n veloshare-lab exec lab-pvc-writer -- \
  sh -c 'echo lab-4.4-marker >> /var/log/veloshare/marker.txt'
```

Delete the Pod — note the PVC and its data are untouched by this, only the
Pod goes away:

```sh
kubectl delete pod lab-pvc-writer -n veloshare-lab
kubectl -n veloshare-lab get pvc lab-pricing-logs         # still Bound, unaffected
```

Recreate the Pod from the same manifest and read the marker back:

```sh
kubectl apply -f lab/day4/4.4-pvc/pod-writer.yaml
kubectl -n veloshare-lab wait --for=condition=ready pod/lab-pvc-writer --timeout=60s

kubectl -n veloshare-lab exec lab-pvc-writer -- cat /var/log/veloshare/marker.txt
# lab-4.4-marker

kubectl -n veloshare-lab exec lab-pvc-writer -- wc -l /var/log/veloshare/app.log
# the same line count as before the delete — nothing was lost
```

## Exam notes

- A PVC is a **namespaced** object. The Pod that mounts it must be created
  in the *same* namespace — there is no cross-namespace PVC mount, unlike
  some ConfigMap/Secret sharing patterns via projected volumes.
- `ReadWriteOnce` means one **node** can mount the volume read-write, not
  one Pod. Multiple Pods scheduled to the same node can mount an RWO PVC
  simultaneously; a second Pod on a *different* node cannot, until the
  first is gone. This is a frequent exam trap when a Deployment with
  `replicas > 1` mounts an RWO PVC and Pods land `Pending` on other nodes.
- `volumeBindingMode: WaitForFirstConsumer` (the `standard` StorageClass's
  mode here) delays both provisioning and node-selection until a Pod
  actually claims the volume — a `Pending` PVC with no Pod yet is normal.
  `Immediate` binding, the other mode, provisions right away and can pick a
  node before anything is scheduled, which is a worse fit for node-local
  storage like `rancher.io/local-path`.
- Deleting a PVC does not always delete the underlying data: it depends on
  the bound PersistentVolume's `reclaimPolicy`. `Delete` (the default for
  most dynamic provisioners, including `standard` here) destroys the data
  with the PV; `Retain` leaves it for manual cleanup. Check with
  `kubectl get pv <name> -o jsonpath='{.spec.persistentVolumeReclaimPolicy}'`
  before deleting a PVC you might want back.
- `kubectl get pv,pvc` in one command is the fast way to see the binding —
  match the PVC's `VOLUME` column against the PV's `NAME` column, and check
  both `STATUS` columns say `Bound`.

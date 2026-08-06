# Lab 5.3 — Symptom Reference

Quick-lookup table for the three break/fix pairs. Use this to check your own
diagnosis before looking at `fixed/`.

| # | Symptom you see | Command that reveals it | Root cause | Fix |
|---|---|---|---|---|
| 1 | `kubectl apply` itself fails — nothing is created | `kubectl apply -f broken/1-deployment-selector.yaml` prints `The Deployment "lab-triage-selector" is invalid: spec.template.metadata.labels: ... selector does not match template labels` | `spec.selector.matchLabels` requires `app.kubernetes.io/instance: lab-triage-selector`, but `spec.template.metadata.labels` has `lab-triage-selector-WRONG` | `fixed/1-deployment-selector.yaml` — template label corrected to match the selector |
| 2 | Object creates fine, Pod is `1/1 Running`, Service has an Endpoint — but every request to the Service hangs or is refused | `kubectl get endpoints lab-triage-port` shows a populated IP:port; `kubectl exec ... -- curl`-equivalent (see README) to the Service times out / connection refused | `Service.spec.ports[0].targetPort` is `8080`; the pricing container listens on `8000` | `fixed/2-service-targetport.yaml` — `targetPort: 8000` |
| 3 | Pod is stuck, never reaches `Running` | `kubectl get pod -l app.kubernetes.io/instance=lab-triage-image` shows `ErrImagePull` then `ImagePullBackOff`; `kubectl describe pod ...` shows `Failed to pull image "veloshare/pricing:9.9.9" ... not found` | `image: veloshare/pricing:9.9.9` — a tag that was never `docker build`-t nor `kind load docker-image`-ed | `fixed/3-deployment-image.yaml` — `image: veloshare/pricing:0.1.0` |

## Triage order

When something is broken and you don't yet know which of these three
categories it falls into, work this sequence — cheapest and most informative
checks first:

1. `kubectl get pods` — is the Pod there at all? What STATUS/READY?
   (Absent entirely -> think ReplicaSet/quota rejection, not this lab.
   `0/1` with a specific STATUS string -> read on.)
2. `kubectl describe pod <pod>` — the Events block at the bottom explains
   almost every failure in plain English: image pull errors, probe
   failures, scheduling failures, OOMKills.
3. `kubectl get events --sort-by=.lastTimestamp` — the same Events, but
   across the whole namespace and in chronological order; useful once the
   failing Pod itself has already been deleted/replaced.
4. `kubectl get endpoints <service>` — is the Service selector actually
   matching a Ready Pod? `<none>` here means selector/readiness, not
   networking. A populated IP:port here does NOT mean the app is reachable
   — only that the selector and readiness are fine (see pair 2).
5. `kubectl logs <pod> [-c <container>] [--previous]` — the last resort for
   "the Pod is Running/Ready but behaving wrong", since 1-4 above are all
   about Pods that never got there in the first place.

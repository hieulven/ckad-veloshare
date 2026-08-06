# Lab 5.3 — Broken YAML Triage

**Duration:** ~45 min · **CKAD domain:** Application Observability and Maintenance (15%)

## Objectives (instructor)

1. Fix selector mismatch in Deployment
2. Fix Service targetPort mismatch
3. Fix invalid image name

## VeloShare object under test

`veloshare/pricing:0.1.0` (and, for pair 3 on purpose, a tag of it that does
not exist: `veloshare/pricing:9.9.9`). Three independent break/fix pairs,
each isolated behind its own resource name (`lab-triage-selector`,
`lab-triage-port`, `lab-triage-image`) so they can be applied, diagnosed,
and fixed in any order without interfering with each other.

## Files

| File | Purpose |
|---|---|
| `broken/1-deployment-selector.yaml` | Deployment `lab-triage-selector` — selector doesn't match template labels. Rejected at `apply` time. |
| `fixed/1-deployment-selector.yaml` | Same Deployment, template label corrected. |
| `broken/2-service-targetport.yaml` | Deployment `lab-triage-port` (correct) + Service `lab-triage-port` with `targetPort: 8080` against a container listening on 8000. |
| `fixed/2-service-targetport.yaml` | Same pair, `targetPort: 8000`. |
| `broken/3-deployment-image.yaml` | Deployment `lab-triage-image` — `image: veloshare/pricing:9.9.9`, a tag never built/loaded. |
| `fixed/3-deployment-image.yaml` | Same Deployment, `image: veloshare/pricing:0.1.0`. |
| `SYMPTOMS.md` | Symptom -> command -> root cause -> fix lookup table, plus a general triage order. |

## Verify

Work each pair as diagnose-then-fix: apply the `broken/` file, confirm the
symptom yourself before reading `SYMPTOMS.md`, then apply the matching
`fixed/` file over it and confirm it actually resolves.

### Pair 1 — selector mismatch

```sh
kubectl apply -f lab/day5/5.3-broken-yaml/broken/1-deployment-selector.yaml
# The Deployment "lab-triage-selector" is invalid: spec.template.metadata.labels:
# Invalid value: ...: `selector` does not match template `labels`
# (non-zero exit; nothing was created)

kubectl -n veloshare-lab get deploy lab-triage-selector
# Error from server (NotFound): deployments.apps "lab-triage-selector" not found

kubectl apply -f lab/day5/5.3-broken-yaml/fixed/1-deployment-selector.yaml
kubectl -n veloshare-lab rollout status deploy/lab-triage-selector
# deployment "lab-triage-selector" successfully rolled out
```

### Pair 2 — Service targetPort mismatch

```sh
kubectl apply -f lab/day5/5.3-broken-yaml/broken/2-service-targetport.yaml
kubectl -n veloshare-lab rollout status deploy/lab-triage-port

# Endpoints look completely fine -- this is the trap.
kubectl -n veloshare-lab get endpoints lab-triage-port
#   NAME               ENDPOINTS          AGE
#   lab-triage-port    10.244.x.x:8080    20s

# But nothing actually answers on the Service.
kubectl -n veloshare-lab run lab-triage-client --rm -it --restart=Never \
  --image=veloshare/pricing:0.1.0 -- python -c \
  "import urllib.request; urllib.request.urlopen('http://lab-triage-port/healthz', timeout=3)"
#   ... urllib.error.URLError: <urlopen error [Errno 111] Connection refused>

kubectl apply -f lab/day5/5.3-broken-yaml/fixed/2-service-targetport.yaml
kubectl -n veloshare-lab run lab-triage-client --rm -it --restart=Never \
  --image=veloshare/pricing:0.1.0 -- python -c \
  "import urllib.request,json; print(json.load(urllib.request.urlopen('http://lab-triage-port/healthz', timeout=3)))"
#   {'status': 'ok'}
```

### Pair 3 — invalid image tag

```sh
kubectl apply -f lab/day5/5.3-broken-yaml/broken/3-deployment-image.yaml
kubectl -n veloshare-lab get pod -l app.kubernetes.io/instance=lab-triage-image
#   NAME                                 READY   STATUS             RESTARTS   AGE
#   lab-triage-image-xxxxxxxxxx-xxxxx    0/1     ErrImagePull       0          8s
#   (a bit later)
#   lab-triage-image-xxxxxxxxxx-xxxxx    0/1     ImagePullBackOff   0          38s

kubectl -n veloshare-lab describe pod -l app.kubernetes.io/instance=lab-triage-image | tail -8
#   Failed to pull image "veloshare/pricing:9.9.9": ... not found

kubectl apply -f lab/day5/5.3-broken-yaml/fixed/3-deployment-image.yaml
kubectl -n veloshare-lab rollout status deploy/lab-triage-image
#   deployment "lab-triage-image" successfully rolled out
```

Clean up:

```sh
kubectl -n veloshare-lab delete -f lab/day5/5.3-broken-yaml/fixed/1-deployment-selector.yaml \
  -f lab/day5/5.3-broken-yaml/fixed/2-service-targetport.yaml \
  -f lab/day5/5.3-broken-yaml/fixed/3-deployment-image.yaml --ignore-not-found
kubectl -n veloshare-lab delete pod lab-triage-client --ignore-not-found
```

## Exam notes

- `spec.selector` on a Deployment is **immutable** once created — you
  cannot `kubectl patch`/`apply` your way out of a bad selector on a live
  object; delete and recreate. In this lab you never even get that far,
  because the mismatch here is caught by admission before creation — but a
  selector that IS a valid (if wrong) label subset can slip through
  creation and then bite you with the immutability rule later.
- `Service.spec.ports[].targetPort` accepts a **named port**
  (`targetPort: http` referencing `ports[].name: http` on the container)
  instead of a bare number. A named port is safer against exactly this bug
  class, because renumbering the container port doesn't silently desync it
  from the Service.
- `kubectl explain <kind>.<path>` and `kubectl apply --dry-run=server -f`
  catch schema-level mistakes (pair 1's kind) before you ever touch a live
  cluster — `--dry-run=server` runs full admission/validation without
  persisting anything. Neither one catches pair 2 or 3, though: those are
  semantically valid YAML that is simply wrong, which only shows up at
  runtime.
- `ErrImagePull`, `ImagePullBackOff`, and `CrashLoopBackOff` are three
  different failures easily confused at a glance:
  - `ErrImagePull` — the kubelet is actively trying (and failing) to pull
    the image right now.
  - `ImagePullBackOff` — it already failed at least once and is now
    waiting out an exponential backoff before retrying.
  - `CrashLoopBackOff` — the image pulled and the container **started**,
    but exits, over and over (see lab 5.2). Different root cause entirely
    from the two above.

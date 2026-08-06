# Lab 5.1 — Self-Healing App

**Duration:** ~45 min · **CKAD domain:** Application Observability and Maintenance (15%)

## Objectives (instructor)

1. Configure HTTP liveness probe
2. Configure file-based readiness probe
3. Optional: startup probe for slow-start container

## VeloShare object under test

`veloshare/pricing:0.1.0`, `GET /healthz` -> `{"status": "ok"}` (see
`services/pricing/main.py`). One Pod, one container, all three probe types at
once, wired so their interaction is the thing you watch: the startupProbe
gates everything else, and the readinessProbe is deliberately file-based so
you control it by hand instead of waiting for the app to do something.

## Files

| File | Purpose |
|---|---|
| `pod-probes.yaml` | Pod `lab-probes` — startupProbe (httpGet), livenessProbe (httpGet), readinessProbe (exec `cat /tmp/ready`), all on the one `pricing` container. |
| `service-probes.yaml` | ClusterIP Service `lab-probes` selecting that Pod, so `get endpoints` shows readiness flips in real time. |

## Verify

```sh
kubectl apply -f lab/day5/5.1-probes/pod-probes.yaml
kubectl apply -f lab/day5/5.1-probes/service-probes.yaml

# Once startupProbe succeeds (within ~60s) the Pod is Running but stuck 0/1:
# readinessProbe fails every 5s because /tmp/ready does not exist yet.
kubectl -n veloshare-lab get pod lab-probes
#   NAME          READY   STATUS    RESTARTS   AGE
#   lab-probes    0/1     Running   0          45s

# No file-based readiness -> no Endpoint. The Service exists but routes nowhere.
kubectl -n veloshare-lab get endpoints lab-probes
#   NAME          ENDPOINTS   AGE
#   lab-probes    <none>      45s

# Flip readiness on by hand.
kubectl -n veloshare-lab exec lab-probes -- touch /tmp/ready

# Within one readiness period (~5s) the Pod goes 1/1 and the Endpoint appears.
kubectl -n veloshare-lab get pod lab-probes
#   lab-probes    1/1     Running   0          52s
kubectl -n veloshare-lab get endpoints lab-probes
#   lab-probes    10.244.x.x:8000   52s

# Flip it back off.
kubectl -n veloshare-lab exec lab-probes -- rm /tmp/ready

# Within ~5s the Endpoint disappears again -- but the container is NOT
# restarted. RESTARTS stays 0. This is the proof that readiness and
# liveness are different mechanisms: readiness only removes the Pod from
# Service load-balancing, it never touches the container's lifecycle.
kubectl -n veloshare-lab get pod lab-probes
#   lab-probes    0/1     Running   0          58s
kubectl -n veloshare-lab get endpoints lab-probes
#   lab-probes    <none>            58s
```

Clean up:

```sh
kubectl -n veloshare-lab delete -f lab/day5/5.1-probes/service-probes.yaml -f lab/day5/5.1-probes/pod-probes.yaml
```

## Exam notes

- Three probe types, three different jobs:
  - `startupProbe` — "has the app finished starting?" While present and not
    yet succeeded, liveness and readiness are **suspended entirely**. Exists
    so a slow-starting container can get a generous one-time budget
    (`failureThreshold * periodSeconds`) without weakening the steady-state
    livenessProbe.
  - `livenessProbe` — "is the app still healthy?" Failing it **restarts the
    container** (same Pod, `RESTARTS` increments).
  - `readinessProbe` — "should this Pod receive traffic right now?" Failing
    it **removes the Pod from Service Endpoints**. The container keeps
    running untouched; `RESTARTS` does not change.
- `initialDelaySeconds` on livenessProbe was the old way to handle a slow
  start; prefer a `startupProbe` instead — it does not also weaken the
  steady-state failure tolerance the way a large `initialDelaySeconds` does.
- Exec probes (`command: [...]`) spawn a real process inside the container
  on every period — cheap for `cat`, but on a busy node with many exec
  probes this adds up. `httpGet`/`tcpSocket` probes do not fork anything.
- Probe tuning fields: `periodSeconds` (how often), `timeoutSeconds` (how
  long to wait for a response), `failureThreshold` (consecutive failures
  before acting), `successThreshold` (consecutive successes to recover —
  readiness only; liveness and startup must use `1`).
- A Service with a selector that matches a Pod but zero ready replicas is
  `get endpoints` showing `<none>` — not a selector bug, just nothing ready
  yet. Always check readiness before assuming the selector is wrong.

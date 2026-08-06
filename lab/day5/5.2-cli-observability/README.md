# Lab 5.2 — CLI Observability

**Duration:** ~45 min · **CKAD domain:** Application Observability and Maintenance (15%)

## Objectives (instructor)

1. Use kubectl logs with -c and --previous
2. Read Events from describe and get events
3. Use kubectl top for resource usage

## VeloShare object under test

`veloshare/pricing:0.1.0` in two shapes: a real two-container Pod (pricing +
the platform's own `ambassador` nginx sidecar pattern, see
`veloshare.ambassadorContainer` in `helm/veloshare/templates/_helpers.tpl`)
to exercise `-c`, and a standalone Pod whose command deliberately crashes
5s after every start to exercise `--previous`.

## Files

| File | Purpose |
|---|---|
| `deployment-multicontainer.yaml` | Deployment `lab-observe`, 1 replica, containers `pricing` + `ambassador` (nginx-unprivileged, 8080 -> 127.0.0.1:8000). |
| `configmap-ambassador.yaml` | ConfigMap `lab-observe-ambassador`, key `default.conf` — the ambassador's nginx server block. |
| `pod-crashloop.yaml` | Pod `lab-crashloop` — prints a line, sleeps 5s, writes to stderr, `exit 1`, forever. Produces a real CrashLoopBackOff with a previous terminated instance to inspect. |

## Verify

```sh
kubectl apply -f lab/day5/5.2-cli-observability/configmap-ambassador.yaml
kubectl apply -f lab/day5/5.2-cli-observability/deployment-multicontainer.yaml
kubectl apply -f lab/day5/5.2-cli-observability/pod-crashloop.yaml
kubectl -n veloshare-lab rollout status deploy/lab-observe

# No -c on a multi-container Pod: kubectl refuses to guess.
kubectl -n veloshare-lab logs deploy/lab-observe
#   error: a container name must be specified for pod lab-observe-<hash>,
#   choose one of: [pricing ambassador]

# Pick one explicitly.
kubectl -n veloshare-lab logs deploy/lab-observe -c pricing
kubectl -n veloshare-lab logs deploy/lab-observe -c ambassador

# Or all of them, interleaved and prefixed by container name.
kubectl -n veloshare-lab logs deploy/lab-observe --all-containers

# Watch lab-crashloop cycle -- wait until RESTARTS is at least 1.
kubectl -n veloshare-lab get pod lab-crashloop -w
#   NAME            READY   STATUS             RESTARTS      AGE
#   lab-crashloop   0/1     CrashLoopBackOff   1 (10s ago)   25s
# Ctrl-C once RESTARTS >= 1.

# The CURRENT container hasn't printed anything relevant yet (it just
# started again) -- --previous reads the LAST TERMINATED instance, which is
# where the actual failure is.
kubectl -n veloshare-lab logs lab-crashloop --previous
#   starting up
#   fatal: simulated crash

# The Events trail explains the backoff mechanics that `get pod` only
# summarizes as a status string.
kubectl -n veloshare-lab describe pod lab-crashloop | tail -15
kubectl -n veloshare-lab get events --sort-by=.lastTimestamp | tail -20

# Resource usage -- needs metrics-server (`make metrics-server` from the
# repo root). If it is not installed this prints:
#   error: Metrics API not available
kubectl -n veloshare-lab top pods
```

Clean up:

```sh
kubectl -n veloshare-lab delete -f lab/day5/5.2-cli-observability/pod-crashloop.yaml \
  -f lab/day5/5.2-cli-observability/deployment-multicontainer.yaml \
  -f lab/day5/5.2-cli-observability/configmap-ambassador.yaml
```

## Exam notes

- `-c <container>` is **mandatory** for `kubectl logs` on any Pod with more
  than one container — kubectl will not pick one for you, it errors and
  lists the choices. `--all-containers` sidesteps this if you want
  everything at once.
- `--previous` (`-p`) reads the log of the **last terminated instance** of a
  container, not the running one. It is the only way to see why a
  CrashLoopBackOff container actually died — the current instance's log
  only shows what happened since the most recent restart.
- `kubectl logs deploy/<name>` (no Pod name) resolves to **one arbitrary Pod**
  behind that Deployment. Fine with `replicas: 1`; misleading with more —
  use a label selector (`kubectl logs -l app.kubernetes.io/name=...`) or
  target the Pod by name when it matters which replica.
- Useful log flags beyond `-c`/`-p`: `--tail=N`, `-f` (stream), `--since=5m`.
- Events are namespaced objects with roughly a 1-hour TTL by default — an
  old failure's events may simply be gone by the time you look. Don't treat
  "no events" as "nothing happened."
- `kubectl get events` does **not** sort chronologically by default;
  `--sort-by=.lastTimestamp` is the flag that makes it useful for finding
  the most recent failure.
- `kubectl top pods` / `top nodes` depend entirely on metrics-server being
  installed and scraping — it is a separate component, not part of the
  control plane. On kind it also needs `--kubelet-insecure-tls`, which
  `make metrics-server` already applies.

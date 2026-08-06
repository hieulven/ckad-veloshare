# Lab 3.2 — Security Context Lockdown

**Duration:** ~45 min · **CKAD domain:** Application Environment, Configuration & Security (25%)

## Objectives (instructor)

1. Run Pod as non-root with read-only root filesystem
2. Drop all capabilities; disable privilege escalation

## VeloShare object under test

`veloshare/pricing:0.1.0`, whose Dockerfile already creates a non-root user
(`useradd --create-home --uid 10001`, `services/pricing/Dockerfile:3`). That
matters: `runAsNonRoot: true` only *rejects* root, it does not *choose* a user.
An image with no `USER` instruction fails this check rather than being silently
demoted — which is the counter-example in `broken/`.

## Files

| File | Purpose |
|---|---|
| `pod-hardened.yaml` | All four settings applied correctly, plus the writable volumes a read-only rootfs forces you to declare. |
| `broken/pod-runs-as-root.yaml` | `runAsUser: 0` against `runAsNonRoot: true` → `CreateContainerConfigError`. |

## Verify the lockdown from inside the container

```sh
P="kubectl -n veloshare-lab exec lab-hardened -c pricing --"

$P id                                  # uid=10001 gid=10001 — not root
$P grep CapEff /proc/self/status       # CapEff: 0000000000000000 — no capabilities
$P touch /nope                         # touch: cannot touch '/nope': Read-only file system
$P touch /var/log/veloshare/ok         # succeeds — the emptyDir is writable
```

`allowPrivilegeEscalation: false` has no direct in-container probe; it shows up
as `NoNewPrivs: 1` in `/proc/self/status`:

```sh
$P grep NoNewPrivs /proc/self/status   # NoNewPrivs: 1
```

## Verify the rejection

```sh
kubectl -n veloshare-lab get pod lab-runs-as-root
kubectl -n veloshare-lab describe pod lab-runs-as-root | tail -6
```

Expect `CreateContainerConfigError` and the message
`container has runAsNonRoot and image will run as root`.

## Exam notes

- **`runAsNonRoot: true` is not enough on its own if the image's `USER` is a
  name.** `services/pricing/Dockerfile` ends with `USER appuser`, and the kubelet
  cannot resolve a username to a UID before the container exists — so it refuses
  to start it:
  ```text
  container has runAsNonRoot and image has non-numeric user (appuser),
  cannot verify user is non-root
  ```
  The fix is a numeric `runAsUser: 10001`. Every Pod in this lab suite carries it
  for that reason, and so does the platform chart (the `runAsUser` argument to
  `veloshare.containerSecurityContext`). An image built with `USER 10001` instead
  of `USER appuser` would not need it. This is a favourite exam trap because the
  manifest looks correct and the failure is a `CreateContainerConfigError` that
  never appears until you `describe` the Pod.
- Container-level `securityContext` **overrides** Pod-level for the same field.
  `runAsUser` at container level wins over `runAsUser` at Pod level; but
  `runAsNonRoot: true` at Pod level still applies as a check to every container.
- `fsGroup` is Pod-level **only** — there is no container-level equivalent. It
  changes group ownership of mounted volumes so a non-root process can write.
- `readOnlyRootFilesystem: true` is the setting most likely to break a working
  app. The fix is always the same: find every path the process writes and mount
  an `emptyDir` there. For this image that is `/var/log/veloshare` and `/tmp`,
  plus `PYTHONDONTWRITEBYTECODE=1` so Python does not try to write `.pyc` files
  under `/app`.
- `capabilities.drop: [ALL]` then `add: [NET_BIND_SERVICE]` is the standard
  pattern for a container that must bind a port below 1024. VeloShare avoids it
  entirely by listening on 8000/8080.

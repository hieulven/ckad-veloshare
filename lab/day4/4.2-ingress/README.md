# Lab 4.2 — Ingress Routing

**Duration:** ~60 min · **CKAD domain:** Services and Networking (20%)

## Objectives (instructor)

1. Route `/` to frontend and `/api` to backend via Ingress
2. Verify via ingress controller endpoint

## VeloShare object under test

The `frontend` and `pricing` Services and Deployments created in lab 4.1 —
this lab does not create any new workload, only the Ingress objects that
route real cluster traffic to them, mirroring how `helm/veloshare/templates/
ingress.yaml` and `ingress-api.yaml` route production traffic to the same
two kinds of backend (a static frontend and a JSON API) in the `veloshare`
namespace.

**Prerequisite:** apply lab 4.1 first — `deployment-frontend.yaml`,
`service-frontend-nodeport.yaml` (only the ClusterIP-equivalent port matters
here; NodePort still works fine as a backend), `deployment-pricing.yaml`,
`service-pricing-clusterip.yaml` must already exist in `veloshare-lab`.

## Files

| File | Purpose |
|---|---|
| `ingress-frontend.yaml` | `lab-frontend` — host `lab.veloshare.local`, `/` -> `frontend:80`. |
| `ingress-api.yaml` | `lab-api` — same host, `/api(/\|$)(.*)` -> `pricing:80`, with `rewrite-target: /$2`. Kept as its own object; see the comment in the file for why. |

## Verify

```sh
kubectl apply -f lab/day4/4.2-ingress/ingress-frontend.yaml
kubectl apply -f lab/day4/4.2-ingress/ingress-api.yaml

kubectl -n veloshare-lab get ingress
```

Frontend, through the Ingress, from outside the cluster (kind maps host
ports 80/443 straight to ingress-nginx — no port-forward needed):

```sh
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: lab.veloshare.local' http://localhost/
# 200
```

Backend, rewritten from `/api/...` to pricing's real routes:

```sh
curl -s -H 'Host: lab.veloshare.local' http://localhost/api/healthz
# {"status":"ok"}

curl -s -H 'Host: lab.veloshare.local' http://localhost/api/tiers
# {"unlock_fee_cents":100,"tiers":[{"tier":"day_pass","per_minute_cents":5},...]}
```

The rewrite in the controller's own generated config, plus the two paths and
their backend, is visible in `describe`:

```sh
kubectl -n veloshare-lab describe ingress lab-api
```

Expect an `Annotations` line for `nginx.ingress.kubernetes.io/rewrite-target:
/$2` and a `Rules` table showing `/api(/|$)(.*)` -> `pricing:80`.

## Exam notes

- `pathType` has three values and the exam expects you to know when each
  applies: **`Exact`** matches the path byte-for-byte (used by
  `helm/veloshare/templates/ingress-api.yaml` for its single literal
  `/api/healthz` route); **`Prefix`** matches on `/`-separated path element
  prefixes, no regex; **`ImplementationSpecific`** hands the string straight
  to the controller, which for ingress-nginx means "this may be a regex" —
  required whenever the path itself contains regex syntax like the capture
  groups here.
- A capture-group rewrite needs a **regex path** to capture from. `/api` as
  a plain `Prefix` path strips nothing — `rewrite-target` would have no `$1`/
  `$2` to substitute and the request would reach pricing still carrying the
  `/api` prefix, which pricing has no route for (`404`).
- `ingressClassName` (a spec field) is the current way to bind an Ingress to
  a controller. The older `kubernetes.io/ingress.class` annotation still
  works on many controllers for compatibility but is deprecated — write
  `ingressClassName`, don't reach for the annotation from memory.
- Imperative form, useful for the simple "/" case under time pressure (it
  cannot express the regex rewrite, so `ingress-api.yaml` still needs to be
  written by hand):
  ```sh
  kubectl -n veloshare-lab create ingress lab-frontend \
    --class=nginx --rule="lab.veloshare.local/*=frontend:80"
  ```
- `rewrite-target` is scoped to the whole Ingress **object**, not the rule —
  the reason this lab (and the real chart) keeps `/` and `/api` in separate
  Ingress objects. See the comment at the top of `ingress-api.yaml`.

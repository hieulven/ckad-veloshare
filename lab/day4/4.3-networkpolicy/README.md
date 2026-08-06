# Lab 4.3 — NetworkPolicy Isolation

**Duration:** ~45 min · **CKAD domain:** Services and Networking (20%)

## Objectives (instructor)

1. Allow frontend → backend traffic only
2. Deny backend egress to internet (0.0.0.0/0)

## VeloShare object under test

`pricing` and `frontend` from lab 4.1, isolated with the same shape of
policy the platform runs in `veloshare` — `k8s/network/networkpolicy-
backend-isolation.yaml` locks the four backend services down to traffic from
ingress-nginx, frontend, and each other. This lab rebuilds that idea from
scratch, one file per concept, against just one backend service so each
rule's effect is individually observable.

**Prerequisite:** lab 4.1's Deployments must exist (`pricing`, `frontend`).

## Files

| File | Purpose |
|---|---|
| `networkpolicy-default-deny.yaml` | `podSelector: {}`, both directions — denies everything in the namespace, including DNS. |
| `networkpolicy-allow-dns.yaml` | Restores egress to CoreDNS (UDP+TCP 53) in `kube-system`, for every Pod. |
| `networkpolicy-allow-frontend-to-pricing.yaml` | Two policies: ingress into pricing from frontend Pods and from the `ingress-nginx` namespace (port 8000); egress out of frontend to pricing (port 8000). |
| `networkpolicy-allow-ingress-to-frontend.yaml` | Ingress into frontend from the `ingress-nginx` namespace (port 8080), so lab 4.2's `/` route survives the default-deny. Easy to forget — `/api` keeps working without it, which makes the Ingress look healthy while `/` returns 504. |
| `networkpolicy-deny-external-egress.yaml` | Egress out of pricing allowed only to `10.0.0.0/8` and `172.16.0.0/12` — everywhere else, including the public internet, has no matching rule. |
| `test-client.yaml` | `lab-netpol-client`, pricing image, labelled `netpol-client` (not `frontend`) — proves an unauthorised Pod is actually dropped, not just untested. |

## Verify

Apply all five policy files plus the test client, in order (order doesn't
change the result — NetworkPolicy rules are evaluated as a union — but
applying default-deny first makes the narrowing effect visible step by
step if you `get endpoints`/test between each one):

```sh
kubectl apply -f lab/day4/4.3-networkpolicy/networkpolicy-default-deny.yaml
kubectl apply -f lab/day4/4.3-networkpolicy/networkpolicy-allow-dns.yaml
kubectl apply -f lab/day4/4.3-networkpolicy/networkpolicy-allow-frontend-to-pricing.yaml
kubectl apply -f lab/day4/4.3-networkpolicy/networkpolicy-deny-external-egress.yaml
kubectl apply -f lab/day4/4.3-networkpolicy/test-client.yaml

kubectl -n veloshare-lab get networkpolicy
kubectl -n veloshare-lab wait --for=condition=ready pod/lab-netpol-client --timeout=60s
```

Neither the pricing nor the frontend image has `curl`; use `wget` (frontend
has it) and Python's `urllib` (pricing has it, `curl`/`wget` does not).

**Allowed — frontend can reach pricing:**

```sh
kubectl -n veloshare-lab exec deploy/frontend -- wget -qO- --timeout=5 http://pricing/healthz
# {"status":"ok"}
```

**Denied — an unauthorised Pod cannot reach pricing:**

```sh
kubectl -n veloshare-lab exec lab-netpol-client -- \
  python -c "import urllib.request;print(urllib.request.urlopen('http://pricing/healthz',timeout=5).read())"
```

Expect it to hang for the full 5s timeout, then:

```text
urllib.error.URLError: <urlopen error timed out>
```

(a *timeout*, not "connection refused" — NetworkPolicy drops packets
silently rather than rejecting them, which looks identical to "the server is
just slow" until you know to check policies first).

**Denied — pricing cannot reach the public internet:**

```sh
kubectl -n veloshare-lab exec deploy/pricing -- \
  python -c "import socket;socket.create_connection(('1.1.1.1',443),timeout=5)"
```

Expect the same shape of failure:

```text
TimeoutError: timed out
```

## Exam notes

- NetworkPolicy is **purely additive and allow-list only**. There is no deny
  rule in the API — `networkpolicy-deny-external-egress.yaml`'s "deny the
  internet" is really "allow the cluster's own CIDRs," and everything
  outside that allow-list is dropped as a side effect of nothing matching.
- A Pod is unrestricted in a direction (ingress or egress) **only while zero
  policies select it for that direction**. The instant any NetworkPolicy's
  `podSelector` matches it and lists that `policyType`, that direction
  flips to default-deny for that Pod, and every applicable policy's rules
  are unioned together — see `networkpolicy-default-deny.yaml`'s comment.
- Forgetting DNS egress is the single most common NetworkPolicy mistake on
  the exam and in production: everything looks like a connection failure to
  the target service, when the actual failure is upstream — the Pod never
  resolved the target's DNS name in the first place.
- `podSelector` (top-level, in `spec`) selects which Pods the policy
  **applies to**. `from`/`to` selectors, inside `ingress`/`egress` rules,
  select the **peers** allowed to talk to those Pods. Same shape of field,
  opposite role — easy to swap by accident under time pressure.
- Inside one `from`/`to` list **item**, `namespaceSelector` +
  `podSelector` together are **AND** (peer must be that Pod, in that
  namespace). As **separate list items** (each starting with its own `-`),
  they are **OR** — this lab's `networkpolicy-allow-frontend-to-pricing.yaml`
  uses the OR form deliberately: "frontend Pods in this namespace, OR
  anything at all from the ingress-nginx namespace," not "frontend Pods that
  are somehow also in ingress-nginx."

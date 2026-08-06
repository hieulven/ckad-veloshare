# Lab 4.1 — ClusterIP & NodePort

**Duration:** ~45 min · **CKAD domain:** Services and Networking (20%)

## Objectives (instructor)

1. Create ClusterIP backend and NodePort frontend
2. Diagnose and fix selector mismatch
3. Verify Endpoints

## VeloShare object under test

`veloshare/pricing:0.1.0` behind a ClusterIP Service named `pricing`, and
`veloshare/frontend:0.1.0` behind a NodePort Service named `frontend`. Naming
the backend Service `pricing` is not cosmetic: the frontend image's baked-in
`nginx.conf` (`services/frontend/nginx.conf`) already contains
`proxy_pass http://pricing/;` for `/api/pricing/`, fixed at image build time.
Reusing that exact DNS name is what lets this lab run the frontend image
completely unmodified, and it's what makes the selector-mismatch exercise
below produce a visible 502 through the frontend rather than just an
abstract `<none>` in `kubectl get endpoints`.

## Files

| File | Purpose |
|---|---|
| `deployment-pricing.yaml` | Backend Deployment, 2 replicas, port 8000, `/healthz` probes. |
| `service-pricing-clusterip.yaml` | ClusterIP Service `pricing`, port 80 -> targetPort 8000. |
| `deployment-frontend.yaml` | Frontend Deployment, 1 replica, port 8080, `/` probes. |
| `service-frontend-nodeport.yaml` | NodePort Service `frontend`, port 80 -> targetPort 8080, fixed `nodePort: 30081`. |
| `broken/service-pricing-selector-mismatch.yaml` | Same Service, selector `app.kubernetes.io/name: pricing-api` — matches no Pod. |
| `fixed/service-pricing-selector-fixed.yaml` | The corrected Service — a single `apply` undoes the break. |

## Verify

```sh
kubectl apply -f lab/day4/4.1-clusterip-nodeport/deployment-pricing.yaml
kubectl apply -f lab/day4/4.1-clusterip-nodeport/service-pricing-clusterip.yaml
kubectl apply -f lab/day4/4.1-clusterip-nodeport/deployment-frontend.yaml
kubectl apply -f lab/day4/4.1-clusterip-nodeport/service-frontend-nodeport.yaml

kubectl -n veloshare-lab rollout status deploy/pricing
kubectl -n veloshare-lab rollout status deploy/frontend
```

Working state — a Service with real Endpoints:

```sh
kubectl -n veloshare-lab get svc,endpoints
```

```text
NAME               TYPE        CLUSTER-IP     PORT(S)        AGE
service/pricing    ClusterIP   10.96.x.x      80/TCP         1m
service/frontend   NodePort    10.96.x.x      80:30081/TCP   1m

NAME                ENDPOINTS                       AGE
endpoints/pricing   10.244.x.x:8000,10.244.x.x:8000  1m
endpoints/frontend  10.244.x.x:8080                  1m
```

The EndpointSlice controller populates the same information from a different
angle — worth knowing both commands exist:

```sh
kubectl -n veloshare-lab get endpointslices -l kubernetes.io/service-name=pricing
```

Reach the backend from inside the cluster, through the Service, from the
frontend Pod (neither image has `curl`; the frontend image has `wget`):

```sh
kubectl -n veloshare-lab exec deploy/frontend -- wget -qO- http://pricing/healthz
# {"status":"ok"}
```

Reach the frontend from outside the cluster via the NodePort (kind's
`control-plane` node maps host ports 80/443 to ingress-nginx only, so use the
node's own IP for a NodePort, or reuse the ClusterIP path from another Pod if
the host cannot route to kind's docker network directly):

```sh
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[1].status.addresses[?(@.type=="InternalIP")].address}')
curl -s -o /dev/null -w '%{http_code}\n' "http://${NODE_IP}:30081/"
# 200
```

### Break it, diagnose it, fix it

```sh
kubectl apply -f lab/day4/4.1-clusterip-nodeport/broken/service-pricing-selector-mismatch.yaml
kubectl -n veloshare-lab get endpoints pricing            # ENDPOINTS: <none>
kubectl -n veloshare-lab exec deploy/frontend -- wget -qO- http://pricing/healthz
# wget: server returned error: HTTP/1.1 502 Bad Gateway

kubectl -n veloshare-lab get pods -l app.kubernetes.io/name=pricing   # still 2/2 Running — Pods are fine

kubectl apply -f lab/day4/4.1-clusterip-nodeport/fixed/service-pricing-selector-fixed.yaml
kubectl -n veloshare-lab get endpoints pricing            # populated again
kubectl -n veloshare-lab exec deploy/frontend -- wget -qO- http://pricing/healthz
# {"status":"ok"}
```

## Exam notes

- A Service `selector` matches **Pod** labels, never Deployment labels or the
  Deployment's own name. The Deployment's `spec.selector.matchLabels` and the
  Service's `spec.selector` are two independent fields that only happen to
  agree when you write them consistently — Kubernetes never cross-checks
  them for you.
- Three port fields, three different meanings: `port` is what clients dial
  (the Service's own address); `targetPort` is the container port traffic
  gets forwarded to; `nodePort` is the host port opened on every node, only
  relevant for `type: NodePort` (or `LoadBalancer`).
- Empty Endpoints (`<none>`) is **always** one of exactly two causes: the
  selector matches no Pod, or it matches Pods that are not Ready (a failing
  readiness probe removes a Pod from Endpoints without killing it — check
  `kubectl get pods` phase/READY column first).
- `kubectl get endpoints <svc>` is the single fastest diagnostic for "Service
  not working" — faster than `describe svc`, and it tells you immediately
  whether the problem is the Service (empty) or something downstream (has
  IPs, but requests still fail).
- Imperative equivalents for the exam:
  ```sh
  kubectl -n veloshare-lab expose deployment pricing --port=80 --target-port=8000 --name=pricing
  kubectl -n veloshare-lab expose deployment frontend --port=80 --target-port=8080 \
    --type=NodePort --name=frontend
  ```
  `expose` copies the Deployment's Pod template labels as the selector
  automatically — which is exactly the step this lab's `broken/` file gets
  wrong by hand.

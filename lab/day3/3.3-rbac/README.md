# Lab 3.3 — ServiceAccount & RBAC

**Duration:** ~60 min · **CKAD domain:** Application Environment, Configuration & Security (25%)

## Objectives (instructor)

1. Create ServiceAccount, Role, RoleBinding
2. Pod uses SA token to list Pods in namespace via API

## VeloShare object under test

`veloshare/pod-lister:0.1.0`. `services/pod-lister/list-pods.sh` deliberately
calls the API server with **curl**, not `kubectl`, so every link in the chain is
visible in nine lines of bash:

```sh
SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
curl --cacert "$SA_DIR/ca.crt" \
     -H "Authorization: Bearer $(cat "$SA_DIR/token")" \
     "https://kubernetes.default.svc/api/v1/namespaces/$(cat "$SA_DIR/namespace")/pods"
```

Using `kubectl` inside the Pod would hide exactly the part the objective is
about.

## Files

| File | Purpose |
|---|---|
| `rbac.yaml` | ServiceAccount + Role (`get,list,watch` on `pods` only) + RoleBinding. |
| `job-pod-lister.yaml` | Job with `serviceAccountName: lab-pod-lister` → succeeds. |
| `broken/job-default-sa.yaml` | Same image, no `serviceAccountName` → 403 in the response body. |

## Verify — the granted path

```sh
kubectl -n veloshare-lab wait --for=condition=complete job/lab-pod-lister --timeout=60s
kubectl -n veloshare-lab logs job/lab-pod-lister
```

Expect a list of every Pod in `veloshare-lab` with its phase.

## Verify — the denied path

```sh
kubectl -n veloshare-lab logs job/lab-pod-lister-denied
```

Expect `pods is forbidden: User "system:serviceaccount:veloshare-lab:default"
cannot list resource "pods"`.

## Verify without running anything — `kubectl auth can-i`

The fastest way to reason about RBAC, and worth knowing cold for the exam:

```sh
kubectl -n veloshare-lab auth can-i list pods \
  --as=system:serviceaccount:veloshare-lab:lab-pod-lister    # yes

kubectl -n veloshare-lab auth can-i list pods \
  --as=system:serviceaccount:veloshare-lab:default           # no

kubectl -n veloshare-lab auth can-i delete pods \
  --as=system:serviceaccount:veloshare-lab:lab-pod-lister    # no — verbs are read-only

kubectl -n veloshare-lab auth can-i list secrets \
  --as=system:serviceaccount:veloshare-lab:lab-pod-lister    # no — resource not in the Role

kubectl -n default auth can-i list pods \
  --as=system:serviceaccount:veloshare-lab:lab-pod-lister    # no — a Role is namespace-scoped
```

Those last three are the whole of least privilege in one command each.

## Exam notes

- Three objects, and all three are required. A Role with no RoleBinding grants
  nothing; a RoleBinding pointing at a nonexistent Role is accepted at write
  time and fails only at request time.
- The SA identity string is always
  `system:serviceaccount:<namespace>:<name>` — you need it for `--as`.
- Imperative equivalents, much faster under exam time pressure:
  ```sh
  kubectl -n veloshare-lab create sa lab-pod-lister
  kubectl -n veloshare-lab create role lab-pod-lister --verb=get,list,watch --resource=pods
  kubectl -n veloshare-lab create rolebinding lab-pod-lister \
      --role=lab-pod-lister --serviceaccount=veloshare-lab:lab-pod-lister
  ```
- `Role`+`RoleBinding` = namespaced. `ClusterRole`+`ClusterRoleBinding` =
  cluster-wide. The fourth combination is the one people forget:
  **`ClusterRole` + `RoleBinding`** grants the ClusterRole's permissions but
  only within the RoleBinding's namespace — the normal way to reuse a built-in
  ClusterRole like `view` in a single namespace.
- Set `automountServiceAccountToken: false` on Pods that never call the API. It
  can be set on the Pod or on the ServiceAccount; the Pod-level setting wins.

# Chapter 21: StatefulSets Deep Dive

Deployments treat pods as interchangeable. If pod `web-abc123` dies, the replacement `web-def456` is identical in every way that matters --- same image, same configuration, same role. This works beautifully for stateless applications where any instance can handle any request. But some workloads are not interchangeable. - A database replica cannot simply replace the primary without coordination.
- A distributed system that uses consistent hashing needs members with stable identities.
- A clustered cache needs each node to own a predictable shard of data. These workloads need something Deployments cannot provide: **stable identity**.

StatefulSets exist because some pods are not fungible. (For a visual map of how stateful workload concepts relate, see [Appendix B: Mental Models](A2-mental-models.md).) Like every Kubernetes workload controller, a StatefulSet follows the [controller pattern](03-architecture.md) we covered in Chapter 3 --- observe, diff, act --- but with additional ordering and identity guarantees that the Deployment controller does not provide.

## The Identity Problem

Consider what happens when a Deployment manages three pods:

```
DEPLOYMENT IDENTITY MODEL
──────────────────────────

Deployment: web (replicas=3)
    │
    ├── web-7b9f5d4c8-abc12   ← random suffix
    ├── web-7b9f5d4c8-def34   ← random suffix
    └── web-7b9f5d4c8-ghi56   ← random suffix

Pod dies → Replacement: web-7b9f5d4c8-xyz99   ← new random name
                                                  new IP address
                                                  new node (maybe)
                                                  no memory of its past life
```

Now compare with a StatefulSet:

```
STATEFULSET IDENTITY MODEL
───────────────────────────

StatefulSet: db (replicas=3)
    │
    ├── db-0   ← ordinal index 0 (always the first)
    ├── db-1   ← ordinal index 1 (always the second)
    └── db-2   ← ordinal index 2 (always the third)

Pod db-1 dies → Replacement: db-1   ← same name
                                       same PVC (data-db-1)
                                       same DNS record
                                       same identity, different incarnation
```

The difference is fundamental. A Deployment pod is a disposable worker. A StatefulSet pod is a named member of a group. When `db-1` is replaced, the new pod inherits the identity of the old one --- its name, its storage, its network address. This is what makes stateful workloads possible on Kubernetes.

## StatefulSets vs Deployments

| Property | Deployment | StatefulSet |
|----------|-----------|-------------|
| **Pod names** | Random hash suffix (`web-7b9f5-abc12`) | Ordinal index (`web-0`, `web-1`, `web-2`) |
| **Pod creation order** | All at once (parallel) | Sequential by default (`web-0` → `web-1` → `web-2`) |
| **Pod deletion order** | Any order | Reverse ordinal by default (`web-2` → `web-1` → `web-0`) |
| **Storage** | Shared or none | Per-pod PVC via `volumeClaimTemplates` |
| **Network identity** | ClusterIP Service (virtual IP) | Headless Service (individual DNS per pod) |
| **Scaling** | Instant (add/remove any pod) | Sequential (add highest, remove highest ordinal) |
| **Use case** | Stateless apps, web servers, APIs | Databases, message queues, distributed systems |

The cost of these guarantees is operational complexity. StatefulSets are harder to scale, harder to update, and require more careful planning. Use them only when your workload genuinely needs stable identity or per-pod storage.

## Headless Services and Stable DNS

A normal ClusterIP Service creates a virtual IP that load-balances requests across all matching pods. A **headless Service** (one with `clusterIP: None`) does not create a virtual IP. Instead, it creates individual DNS records for each pod in the StatefulSet.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: db
  namespace: default
spec:
  clusterIP: None          # This makes it headless
  selector:
    app: db
  ports:
    - port: 5432
      targetPort: 5432
```

This headless Service produces the following DNS records:

```
HEADLESS SERVICE DNS RESOLUTION
────────────────────────────────

StatefulSet: db    Headless Service: db
replicas: 3        clusterIP: None

  ┌──────────────────────────────────────────────────────┐
  │                  DNS Records                         │
  │                                                      │
  │  db-0.db.default.svc.cluster.local → 10.244.1.5     │
  │  db-1.db.default.svc.cluster.local → 10.244.2.8     │
  │  db-2.db.default.svc.cluster.local → 10.244.1.9     │
  │                                                      │
  │  db.default.svc.cluster.local → [all three IPs]     │
  │  (A record returns all pod IPs, no load balancing)   │
  └──────────────────────────────────────────────────────┘

  Application connects to:
    db-0.db.default.svc.cluster.local    ← always reaches db-0
    db-1.db.default.svc.cluster.local    ← always reaches db-1
    db.default.svc.cluster.local         ← reaches any (round-robin DNS)
```

The DNS naming convention is: `<pod-name>.<service-name>.<namespace>.svc.cluster.local`

The combination of a stable pod name (`db-0`) and a stable DNS entry (`db-0.db.default.svc.cluster.local`) gives each pod a persistent network identity that survives restarts, rescheduling, and node failures.

A PostgreSQL replica can be configured to always connect to `db-0.db.default.svc.cluster.local` as its primary, regardless of which node `db-0` happens to be running on or what IP address it currently has.

## The StatefulSet Spec

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: db
spec:
  serviceName: db               # Must match the headless Service name
  replicas: 3
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      containers:
        - name: postgres
          image: postgres:16.2
          ports:
            - containerPort: 5432
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:          # Per-pod persistent storage
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: gp3
        resources:
          requests:
            storage: 50Gi
```

The `volumeClaimTemplates` field is unique to StatefulSets. For each pod, Kubernetes creates a PersistentVolumeClaim named `<template-name>-<statefulset-name>-<ordinal>`. In this example: `data-db-0`, `data-db-1`, `data-db-2`. Each PVC is bound to its own PersistentVolume, giving each pod dedicated storage.

## Ordered Operations

By default, StatefulSets use the `OrderedReady` pod management policy. This means:

1. **Creation**: Pods are created in order: `db-0` first, then `db-1` only after `db-0` is Running and Ready, then `db-2` only after `db-1` is Running and Ready.
2. **Scaling up**: Same as creation --- new pods are added one at a time in ordinal order.
3. **Scaling down**: Pods are removed in reverse order: `db-2` first, then `db-1`, then `db-0`.
4. **Deletion**: If you delete a StatefulSet, pods are terminated in reverse ordinal order.

This ordering exists because stateful systems often need it. A database primary (`db-0`) must be running before replicas (`db-1`, `db-2`) can initialize and connect. Replicas should be drained before the primary is stopped.

For workloads that do not need ordered operations (for example, a distributed cache where all nodes are peers), you can set `podManagementPolicy: Parallel`:

```yaml
spec:
  podManagementPolicy: Parallel    # All pods start/stop simultaneously
```

This removes the ordering constraint but retains stable names and per-pod storage.

## Update Strategies

### RollingUpdate (Default)

Pods are updated in reverse ordinal order: `db-2` first, then `db-1`, then `db-0`. Each pod must become Ready before the next one is updated.

The `partition` parameter enables canary deployments:

```yaml
spec:
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 2             # Only pods with ordinal >= 2 are updated
```

With `partition: 2` and 3 replicas, only `db-2` receives the new pod template. `db-0` and `db-1` remain on the old version. After verifying `db-2` is healthy, you lower the partition to `1`, then `0`, to roll out the update progressively. This is the safest way to update a stateful workload.

### OnDelete

Pods are updated only when you manually delete them. This gives you complete control over the update order:

```yaml
spec:
  updateStrategy:
    type: OnDelete
```

This is useful when the update order matters and the default reverse-ordinal approach is not appropriate --- for example, when you need to update replicas before the primary.

## PVC Retention Policies

By default, PVCs created by `volumeClaimTemplates` are **never deleted** by Kubernetes. This is the safest behavior --- you never accidentally lose data --- but it means orphaned PVCs accumulate when you scale down or delete a StatefulSet.

Starting in v1.27, you can configure PVC retention:

```yaml
spec:
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain        # When the StatefulSet is deleted
    whenScaledDown: Retain     # When replicas are scaled down
```

| Policy | `whenDeleted` | `whenScaledDown` | Behavior |
|--------|---------------|-------------------|----------|
| **Safest** | Retain | Retain | PVCs always preserved (default) |
| **Balanced** | Delete | Retain | Cleanup on StatefulSet deletion, preserve on scale-down |
| **Aggressive** | Delete | Delete | PVCs deleted on both operations |

For production databases, always use `Retain` for both. Data recovery from a lost PVC is far more expensive than cleaning up unused PVCs.

## Scale-Down and PVC Persistence

This behavior surprises many operators and deserves special emphasis:

```
PVC PERSISTENCE ON SCALE-DOWN
───────────────────────────────

BEFORE: replicas=5
  db-0  db-1  db-2  db-3  db-4        PVCs: data-db-0 through data-db-4
   │     │     │     │     │
   ▼     ▼     ▼     ▼     ▼
  PV0   PV1   PV2   PV3   PV4

AFTER: replicas=3 (scaled down)
  db-0  db-1  db-2                     Pods db-3, db-4 terminated
   │     │     │
   ▼     ▼     ▼
  PV0   PV1   PV2   PV3   PV4         PVCs data-db-3, data-db-4 STILL EXIST
                      ▲     ▲
                      │     │
                   Orphaned PVCs       ← data preserved but no pod using it

LATER: replicas=5 (scaled back up)
  db-0  db-1  db-2  db-3  db-4        db-3, db-4 reattach to existing PVCs
   │     │     │     │     │
   ▼     ▼     ▼     ▼     ▼
  PV0   PV1   PV2   PV3   PV4         Data from previous incarnation intact!
```

This is deliberate. When you scale back up, `db-3` and `db-4` get their old data back. But it also means you are paying for unused storage until you manually delete the orphaned PVCs (or configure `whenScaledDown: Delete`).

## When to Use StatefulSets vs Deployments

**Use a StatefulSet when:**
- Each pod needs a stable, unique network identity (databases, consensus systems)
- Each pod needs its own persistent storage volume (data nodes)
- Pod initialization or termination must happen in a defined order
- Peers need to address each other by name (cluster membership protocols)

**Use a Deployment when:**
- All pods are identical and interchangeable
- Shared storage (or no storage) is sufficient
- Order of creation and deletion does not matter
- You need fast scaling (no sequential constraints)

A common anti-pattern is using StatefulSets for applications that just need persistent storage but do not need stable identity. If your application uses a single shared PVC (ReadWriteMany), a Deployment with a PVC is simpler and more appropriate.

## Common Mistakes and Misconceptions

- **"StatefulSets are just Deployments with persistent storage."** StatefulSets provide ordered startup/shutdown, stable network identities (pod-0, pod-1), and per-replica PVCs. These guarantees come with trade-offs: slower scaling and more complex operations.
- **"Deleting a StatefulSet deletes its PVCs."** PVCs are deliberately retained to prevent data loss. You must delete PVCs manually. This is a safety feature, not a bug.
- **"I need a StatefulSet for any app that uses a database."** If your app is stateless but connects to an external database, use a Deployment. StatefulSets are for when the pod itself holds state (e.g., the pod IS the database).

## Further Reading

- [StatefulSet documentation](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/) --- Official reference
- [StatefulSet Basics tutorial](https://kubernetes.io/docs/tutorials/stateful-application/basic-stateful-set/) --- Hands-on walkthrough
- [Headless Services](https://kubernetes.io/docs/concepts/services-networking/service/#headless-services) --- DNS behavior for headless Services
- [PVC Retention Policy KEP](https://github.com/kubernetes/enhancements/tree/master/keps/sig-apps/1847-autoremove-statefulset-pvcs) --- Design rationale for PVC retention

---

*Next: [Databases on Kubernetes](22-databases.md) --- When to run databases on K8s, operators, and the trade-offs.*

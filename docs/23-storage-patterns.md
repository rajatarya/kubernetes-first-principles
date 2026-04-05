# Chapter 23: Persistent Storage Patterns

Storage on Kubernetes is where the abstraction meets physical reality. A pod can be rescheduled to any node in seconds, but a 500GB disk cannot teleport. Persistent storage forces you to think about topology, data lifecycle, and failure modes that stateless workloads let you ignore. For a quick storage decision flowchart, see [Appendix C: Decision Trees](A3-decision-trees.md).
## volumeClaimTemplates: The Naming Convention

As covered in Chapter 21, StatefulSets use `volumeClaimTemplates` to create per-pod PVCs. The naming convention is deterministic:

```
<template-name>-<statefulset-name>-<ordinal>
```

For a StatefulSet named `db` with a template named `data`:

```
data-db-0
data-db-1
data-db-2
```

This naming convention is not arbitrary. It is the mechanism by which Kubernetes reconnects pods to their storage after rescheduling. When `db-1` is deleted and recreated (during an update, a node failure, or a manual restart), the new `db-1` pod finds the PVC `data-db-1` by name and reattaches to the same underlying volume. No operator intervention required.

If your StatefulSet has multiple volume templates (for example, separate volumes for data and write-ahead logs), each template produces its own set of PVCs:

```yaml
volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 100Gi
  - metadata:
      name: wal
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 20Gi
```

This creates: `data-db-0`, `data-db-1`, `data-db-2`, `wal-db-0`, `wal-db-1`, `wal-db-2`. Six PVCs for three pods, each with its own underlying PersistentVolume.

## Reclaim Policies: Retain vs Delete

When a PersistentVolumeClaim is deleted, the underlying PersistentVolume's `reclaimPolicy` determines what happens to the actual storage:

| Policy | What Happens | When to Use |
|--------|-------------|-------------|
| **Retain** | PV is preserved. Data remains. PV enters `Released` state and must be manually reclaimed. | Production databases. Any workload where accidental data loss is unacceptable. |
| **Delete** | PV and underlying storage (EBS volume, GCE PD, etc.) are deleted. | Development environments. Workloads where data can be recreated. |
| **Recycle** | Deprecated. Was `rm -rf /thevolume/*` followed by making PV available again. | Never. Use Delete instead. |

The default reclaim policy for dynamically provisioned PVs is **Delete** in most StorageClasses. This is dangerous for production workloads. If someone accidentally deletes a PVC, the underlying data is gone.

**For production, always set the reclaim policy to Retain.** You can do this in the StorageClass:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-retain
provisioner: ebs.csi.aws.com
reclaimPolicy: Retain              # PVs are preserved when PVCs are deleted
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
```

The consequence of `Retain` is that you must manually clean up PVs when you are done with them. This is a feature, not a bug. Explicit deletion of persistent data should require a human decision.

## WaitForFirstConsumer: Topology Awareness

In a multi-zone cluster, where a PV is provisioned matters. An EBS volume in `us-east-1a` cannot be attached to a node in `us-east-1b`. If the volume is provisioned before the pod is scheduled, and the pod lands on a node in a different zone, the pod will be stuck in `Pending` forever.

`WaitForFirstConsumer` solves this by deferring volume provisioning until a pod actually needs it:

```
VOLUME BINDING MODES
─────────────────────

Immediate (default for some StorageClasses):
  1. PVC created              → PV provisioned in zone-a
  2. Pod scheduled to zone-b  → STUCK: PV is in zone-a, pod is in zone-b

WaitForFirstConsumer:
  1. PVC created              → PV provisioning deferred
  2. Pod scheduled to zone-b  → PV provisioned in zone-b (same zone as pod)
  3. Pod binds to PV          → SUCCESS: everything in the same zone
```

**Always use `WaitForFirstConsumer`** for cloud storage in multi-zone clusters. It is the only safe choice.

There is a subtle interaction with StatefulSets: once a PVC is bound to a PV in a specific zone, any future incarnation of that pod is constrained to that zone. If `data-db-0` is provisioned in `us-east-1a`, then `db-0` will always be scheduled to `us-east-1a` (assuming the PVC still exists). This is usually desirable for databases but means that zone failures affect specific StatefulSet members predictably.

## Storage Resize

Most CSI drivers support volume expansion. The StorageClass must allow it:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-expandable
provisioner: ebs.csi.aws.com
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true           # Enables resize
```

To resize, edit the PVC's `spec.resources.requests.storage`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-db-0
spec:
  resources:
    requests:
      storage: 200Gi    # Was 100Gi, now requesting 200Gi
```

The resize process has two phases:

1. **Controller expansion**: The CSI driver expands the underlying volume (e.g., modifies the EBS volume size). This happens automatically.
2. **Node expansion**: The filesystem on the volume is expanded to use the new space. This happens when the pod using the volume restarts (for offline expansion) or live (for online expansion, supported by most modern CSI drivers).

Important constraints:
- **Volumes can only grow, never shrink.** There is no way to reduce a PVC's size.
- **EBS volumes have a cooldown period.** After modifying an EBS volume, you must wait 6 hours before modifying it again.
- **Some filesystems require a pod restart** for the resize to take effect.

## The PVC Lifecycle on Scale-Down

When you scale down a StatefulSet, the pods are deleted but the PVCs are not:

```
PVC LIFECYCLE ON SCALE-DOWN
─────────────────────────────

Step 1: Running at replicas=5
┌──────────────────────────────────────────────────────┐
│  Pod    │  PVC          │  PV     │  Status          │
├─────────┼───────────────┼─────────┼──────────────────┤
│  db-0   │  data-db-0    │  pv-a   │  Bound           │
│  db-1   │  data-db-1    │  pv-b   │  Bound           │
│  db-2   │  data-db-2    │  pv-c   │  Bound           │
│  db-3   │  data-db-3    │  pv-d   │  Bound           │
│  db-4   │  data-db-4    │  pv-e   │  Bound           │
└──────────────────────────────────────────────────────┘

Step 2: Scale to replicas=3 (kubectl scale sts db --replicas=3)
┌──────────────────────────────────────────────────────┐
│  Pod    │  PVC          │  PV     │  Status          │
├─────────┼───────────────┼─────────┼──────────────────┤
│  db-0   │  data-db-0    │  pv-a   │  Bound           │
│  db-1   │  data-db-1    │  pv-b   │  Bound           │
│  db-2   │  data-db-2    │  pv-c   │  Bound           │
│  ---    │  data-db-3    │  pv-d   │  Bound (no pod!) │
│  ---    │  data-db-4    │  pv-e   │  Bound (no pod!) │
└──────────────────────────────────────────────────────┘

  data-db-3 and data-db-4 still exist.
  You are still paying for pv-d and pv-e.
  The data in pv-d and pv-e is preserved.

Step 3: Scale back to replicas=5
┌──────────────────────────────────────────────────────┐
│  Pod    │  PVC          │  PV     │  Status          │
├─────────┼───────────────┼─────────┼──────────────────┤
│  db-0   │  data-db-0    │  pv-a   │  Bound           │
│  db-1   │  data-db-1    │  pv-b   │  Bound           │
│  db-2   │  data-db-2    │  pv-c   │  Bound           │
│  db-3   │  data-db-3    │  pv-d   │  Bound (data!)   │
│  db-4   │  data-db-4    │  pv-e   │  Bound (data!)   │
└──────────────────────────────────────────────────────┘

  db-3 and db-4 reattach to their old PVCs.
  All previous data is intact.
```

Operational implications:

1. **Cost**: Orphaned PVCs consume storage and incur charges. Monitor with `kubectl get pvc` and cloud billing tools.
2. **Stale data**: If you scale down, modify the application, and scale back up, the reattached pods may have stale data that does not match the current application state.
3. **Cleanup**: If you genuinely want to discard the data, you must manually delete the orphaned PVCs: `kubectl delete pvc data-db-3 data-db-4`.

## Backup Strategies: A Layered Approach

No single backup mechanism is sufficient for production data. Each approach has blind spots, and a robust strategy layers multiple approaches to cover each other's weaknesses:

```
BACKUP STRATEGY LAYERS
────────────────────────

Layer 3: Application-Native Backup              ← Highest fidelity
  │  pg_basebackup + WAL archival
  │  mongodump / mysqldump
  │  Application-consistent snapshots
  │  Understands transactions, replication state
  │
Layer 2: Velero (Kubernetes-aware backup)        ← Kubernetes context
  │  Backs up K8s resources (StatefulSets, Services, ConfigMaps)
  │  Can trigger pre/post-backup hooks (e.g., pg_start_backup)
  │  Backs up PV data via snapshots or Restic/Kopia
  │  Restores entire namespaces with all resources
  │
Layer 1: Volume Snapshots (CSI)                  ← Fastest recovery
  │  Point-in-time snapshot of the block device
  │  Fast: typically copy-on-write, completes in seconds
  │  Can clone volumes from snapshots
  │  WARNING: crash-consistent, NOT application-consistent
  │
  ▼
Storage Layer (EBS, GCE PD, Ceph, etc.)
```

### Why Each Layer Matters

**Volume snapshots** are fast but dangerous in isolation. A snapshot captures the block device at a point in time, like pulling the power cord on a running database. The filesystem will be consistent (journaling handles that), but the database may have in-flight transactions that are partially written. The snapshot is **crash-consistent** but not **application-consistent**. Restoring from a snapshot alone may require crash recovery, and some data may be lost.

**Velero** adds Kubernetes context. It backs up not just the data but the Kubernetes resources that define how the data is used --- the StatefulSet, the Service, the ConfigMaps, the Secrets. Velero can also run pre-backup hooks (like `pg_start_backup` or `FLUSH TABLES WITH READ LOCK`) that put the database into a consistent state before snapshotting.

**Application-native backup** is the gold standard. PostgreSQL's continuous archival (base backup + WAL shipping) provides point-in-time recovery to any second in the past. This is the only backup method that guarantees zero data loss for committed transactions.

### Volume Snapshots in Practice

```yaml
# Create a VolumeSnapshot
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: db-snapshot-20260403
spec:
  volumeSnapshotClassName: csi-aws-ebs
  source:
    persistentVolumeClaimName: data-db-0

---
# Create a new PVC from a snapshot (cloning)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-db-0-restored
spec:
  storageClassName: gp3-retain
  dataSource:
    name: db-snapshot-20260403
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
```

Volume cloning from snapshots is invaluable for creating test environments from production data. Snapshot a production PVC, create a new PVC from the snapshot, and attach it to a test StatefulSet. The clone is independent of the original --- modifications to one do not affect the other.

### Velero Configuration

```bash
# Install Velero with AWS provider
velero install \
  --provider aws \
  --bucket my-velero-bucket \
  --secret-file ./credentials-velero \
  --backup-location-config region=us-east-1 \
  --snapshot-location-config region=us-east-1 \
  --plugins velero/velero-plugin-for-aws:v1.9.0

# Schedule daily backups with 30-day retention
velero schedule create daily-db-backup \
  --schedule="0 2 * * *" \
  --include-namespaces database \
  --ttl 720h

# Restore a namespace from backup
velero restore create --from-backup daily-db-backup-20260403020000
```

Velero's pre-backup hooks let you ensure application consistency:

```yaml
metadata:
  annotations:
    pre.hook.backup.velero.io/command: '["/bin/bash", "-c", "psql -c \"SELECT pg_backup_start(''velero'')\""]'
    pre.hook.backup.velero.io/container: postgres
    post.hook.backup.velero.io/command: '["/bin/bash", "-c", "psql -c \"SELECT pg_backup_stop()\""]'
    post.hook.backup.velero.io/container: postgres
```

### The Backup Rule

**Test your restores.** A backup that has never been restored is a hypothesis, not a guarantee. Schedule regular restore tests to a separate namespace and verify data integrity. The time to discover that your backup process is broken is not during an incident.

## Putting It All Together

A production storage configuration for a StatefulSet database combines everything in this chapter:

1. **StorageClass**: `reclaimPolicy: Retain`, `volumeBindingMode: WaitForFirstConsumer`, `allowVolumeExpansion: true`
2. **volumeClaimTemplates**: Separate templates for data and WAL if the database benefits from it
3. **PVC retention policy**: `Retain` for both `whenDeleted` and `whenScaledDown`
4. **Backup**: Application-native continuous backup (WAL archival) + Velero scheduled backups + periodic volume snapshots
5. **Monitoring**: Alert on PVC usage approaching capacity, orphaned PVCs after scale-down, backup job failures

Storage is the foundation that stateful workloads rest on. Get it right and your databases can survive node failures, zone outages, and operational mistakes. Get it wrong and you will learn why the operations community repeats: "backups are worthless; restores are priceless."

## Common Mistakes and Misconceptions

- **"All PersistentVolumes are the same."** RWO (ReadWriteOnce) can only be mounted by one node. RWX (ReadWriteMany) works across nodes but requires NFS or cloud file systems (EFS, Filestore). Choosing wrong access mode causes mount failures. Note: RWO allows multiple pods on the *same* node to mount the volume simultaneously. For databases that require exclusive single-pod access, use `ReadWriteOncePod` (RWOP), which restricts the volume to exactly one pod. RWOP is GA since Kubernetes 1.29.
- **"Storage classes are just about disk type."** Storage classes also control reclaim policy (Delete vs Retain), volume binding mode (Immediate vs WaitForFirstConsumer), and provisioner. WaitForFirstConsumer is critical for zone-aware scheduling.
- **"I can resize PVCs freely."** Volume expansion must be enabled on the storage class (`allowVolumeExpansion: true`). Not all provisioners support it. Shrinking is never supported — plan initial sizes carefully.

## Further Reading

- [Kubernetes Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/) --- Official PV/PVC reference
- [Volume Snapshots](https://kubernetes.io/docs/concepts/storage/volume-snapshots/) --- CSI snapshot documentation
- [Velero documentation](https://velero.io/docs/) --- Kubernetes backup and restore
- [CSI specification](https://github.com/container-storage-interface/spec) --- The standard that all storage drivers implement
- [Kubernetes Storage Best Practices (GKE)](https://cloud.google.com/kubernetes-engine/docs/concepts/persistent-volumes) --- Cloud-specific guidance

---

*Next: [Jobs and CronJobs](24-jobs.md) --- Batch processing, indexed completions, and scheduling patterns.*

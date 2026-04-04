# Chapter 43: Disaster Recovery

A Kubernetes cluster is not a single thing that fails in a single way. The control plane can fail while workloads keep running. A namespace can be accidentally deleted while the rest of the cluster is fine. An entire region can go dark. Disaster recovery for Kubernetes requires thinking in layers: the cluster state layer and the workload layer, each with its own backup strategy, its own restore procedure, and its own failure modes.

## Two-Layer Backup Strategy

Kubernetes disaster recovery operates on two distinct layers, and you need both.

```
TWO-LAYER BACKUP STRATEGY
───────────────────────────

  LAYER 1: CLUSTER STATE (etcd)
  ┌──────────────────────────────────────────────────────────┐
  │  etcd snapshots capture ALL cluster state:               │
  │  - Every resource object (Pods, Deployments, Services)   │
  │  - RBAC rules, NetworkPolicies, CRDs                     │
  │  - Secrets, ConfigMaps                                   │
  │  - Custom resources (operators, databases, etc.)         │
  │                                                          │
  │  What it DOESN'T capture:                                │
  │  - Persistent Volume data                                │
  │  - Container images                                      │
  │  - External state (DNS records, load balancers, IAM)     │
  └──────────────────────────────────────────────────────────┘
                         +
  LAYER 2: WORKLOAD BACKUP (Velero)
  ┌──────────────────────────────────────────────────────────┐
  │  Velero backs up selected Kubernetes resources AND       │
  │  their associated persistent volumes:                    │
  │  - Namespace-scoped resource manifests                   │
  │  - PersistentVolume snapshots (via CSI or cloud APIs)    │
  │  - Label/annotation-based selection                      │
  │  - Scheduled backups on a cron cadence                   │
  │                                                          │
  │  Stored externally in object storage (S3, GCS, MinIO)    │
  └──────────────────────────────────────────────────────────┘

  WHY BOTH?
  ──────────
  etcd snapshots:  Full cluster restore after total loss.
                   Blunt instrument --- all or nothing.

  Velero backups:  Surgical restore of specific namespaces
                   or workloads. Includes PV data.
                   Cross-cluster migration.
```

**etcd snapshots** are your insurance against total cluster loss. They capture the complete cluster state at a point in time. But they are all-or-nothing --- you cannot restore a single namespace from an etcd snapshot without restoring everything. They also do not include persistent volume data.

**Velero** (formerly Heptio Ark) fills the gaps. It backs up Kubernetes resource manifests and can snapshot persistent volumes via CSI snapshot support or cloud provider APIs. It supports selective backup by namespace, label, or resource type. And it can restore into a different cluster, which makes it invaluable for migration.

## Velero in Practice

### Backup Configuration

```bash
# Install Velero with AWS plugin
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket my-cluster-backups \
  --backup-location-config region=us-east-1 \
  --snapshot-location-config region=us-east-1

# Create a scheduled backup
velero schedule create daily-production \
  --schedule="0 2 * * *" \
  --include-namespaces=production,staging \
  --ttl=720h \
  --snapshot-volumes=true
```

### Selective Backup and Restore

Velero's label selectors allow targeted backups:

```bash
# Back up only resources with a specific label
velero backup create critical-apps \
  --selector app.kubernetes.io/tier=critical

# Back up everything except ephemeral namespaces
velero backup create full-backup \
  --exclude-namespaces=kube-system,monitoring,temp-*
```

### Restore with Dependency Ordering

A common failure mode during restore is attempting to create resources before their dependencies exist --- a Deployment that references a ConfigMap that has not been restored yet. Velero handles this through a priority-based restore order:

```
VELERO RESTORE FLOW
─────────────────────

  1. Cluster-scoped resources
     (Namespaces, ClusterRoles, CRDs, StorageClasses)
           │
           ▼
  2. Namespace-scoped foundation
     (ServiceAccounts, ConfigMaps, Secrets, PVCs)
           │
           ▼
  3. Workload resources
     (Deployments, StatefulSets, DaemonSets, Services)
           │
           ▼
  4. Dependent resources
     (Ingress, NetworkPolicies, HPA, PodDisruptionBudgets)
           │
           ▼
  5. Custom Resources
     (CRD instances --- restored after CRDs exist)
           │
           ▼
  6. Volume data
     (PV snapshots restored and bound to new PVCs)
```

You can customize this order via restore hooks and init containers to wait for dependencies.

## RPO and RTO

Two metrics define your disaster recovery targets:

**Recovery Point Objective (RPO):** How much data can you afford to lose? If your etcd snapshots run hourly and Velero backups run daily, your RPO is the time since the last relevant backup. An RPO of 1 hour means you accept losing up to 1 hour of changes.

**Recovery Time Objective (RTO):** How quickly must you be back in service? This includes time to detect the failure, execute the recovery procedure, verify the cluster is healthy, and confirm application availability.

| Scenario | Typical RPO | Typical RTO |
|---|---|---|
| Single namespace deletion | Minutes (Velero) | 15--30 minutes |
| Control plane failure (etcd intact) | 0 (no data loss) | 5--15 minutes |
| Total cluster loss (etcd gone) | Last etcd snapshot interval | 1--4 hours |
| Full region failure | Last cross-region replication | 15 min -- 4 hours |

The gap between your target RPO/RTO and your actual tested RPO/RTO is your risk. Measure both.

## Multi-Region Strategies

For organizations that cannot tolerate the RTO of rebuilding from backup, multi-region architecture provides resilience at the infrastructure level.

### Active-Active

Two or more clusters in different regions serve traffic simultaneously. A global load balancer distributes requests. Stateful workloads either use a multi-region database (CockroachDB, Spanner) or accept eventual consistency.

**Pros:** Near-zero RTO for region failure. No cold-start latency.
**Cons:** Operationally complex. Data consistency is hard. Cost doubles (or more).

### Active-Passive

A primary cluster serves all traffic. A standby cluster in another region has the same applications deployed but receives no traffic. On failure, DNS or the load balancer shifts traffic to the standby.

**Pros:** Simpler than active-active. Lower cost (standby can be smaller).
**Cons:** RTO is limited by DNS propagation and application warm-up. Standby cluster may have stale data.

### Partitioned (Regional Affinity)

Each region operates independently, serving only users or workloads in that region. There is no failover between regions --- each is self-contained.

**Pros:** Simplest multi-region model. Data sovereignty compliance.
**Cons:** No cross-region resilience. If a region goes down, its users are affected.

```
MULTI-REGION STRATEGY COMPARISON
──────────────────────────────────

  ACTIVE-ACTIVE                  ACTIVE-PASSIVE
  ┌──────────┐ ┌──────────┐    ┌──────────┐ ┌──────────┐
  │ Region A │ │ Region B │    │ Region A │ │ Region B │
  │ ████████ │ │ ████████ │    │ ████████ │ │ (standby)│
  │ traffic  │ │ traffic  │    │ traffic  │ │          │
  └─────┬────┘ └─────┬────┘    └─────┬────┘ └─────┬────┘
        │             │               │             │
        └──────┬──────┘               │      (failover)
               │                      │             │
          Global LB              Primary ──────▶ Promote
                                                on failure

  PARTITIONED
  ┌──────────┐ ┌──────────┐ ┌──────────┐
  │ Region A │ │ Region B │ │ Region C │
  │ Users: A │ │ Users: B │ │ Users: C │
  │ Data: A  │ │ Data: B  │ │ Data: C  │
  └──────────┘ └──────────┘ └──────────┘
  (independent, no cross-region failover)
```

## Testing Recovery

Testing restores is not optional --- an untested backup procedure is an untested promise. Teams routinely discover during an actual incident that:

- The backup credentials have rotated and the backup job has been silently failing for weeks.
- The etcd snapshot is from the wrong cluster (staging, not production).
- The Velero restore fails because the target cluster has a different Kubernetes version and the CRD schemas are incompatible.
- The persistent volume snapshots are in a different region from the recovery cluster.
- The restore completes but the application does not start because it depends on an external service that was not part of the backup.

### Testing Practices

1. **Schedule monthly restore drills.** Restore to a separate cluster and verify application health. Automate as much as possible.

2. **Test at every layer.** Restore a single namespace from Velero. Restore an entire cluster from an etcd snapshot. Fail over to a standby region.

3. **Measure actual RTO.** Start a timer when the drill begins. Stop when the application is serving traffic. Compare against your target. If you miss the target, the plan needs work.

4. **Break things intentionally.** Delete a namespace. Corrupt an etcd member. Simulate a region failure by blocking network traffic. Chaos engineering is the only honest test of resilience.

5. **Verify data integrity.** After restore, do not just check that pods are running. Verify that the application data is consistent and correct. A running pod with a corrupted database is not a successful recovery.

## Documented Runbooks

Disaster recovery procedures must be written down, version-controlled, and accessible during an outage. A runbook stored in the cluster that just failed is useless.

A good runbook includes:

- **Prerequisites:** What tools, credentials, and access are needed?
- **Decision tree:** Which procedure applies to which failure scenario?
- **Step-by-step commands:** Copy-pasteable, with placeholders clearly marked.
- **Verification steps:** How to confirm each step succeeded before proceeding.
- **Rollback:** What to do if the recovery makes things worse.
- **Communication plan:** Who to notify, what channels to use, what to tell customers.

Store runbooks in a location that survives the failure of the thing they describe. A Git repository in a different cloud account. A wiki on a different provider. Printed copies in a binder (yes, really, for the truly catastrophic scenarios).

## Putting It Together

A complete disaster recovery strategy for Kubernetes looks like this:

1. **etcd snapshots** every hour, uploaded to cross-region object storage with versioning and lifecycle rules.
2. **Velero scheduled backups** daily, with volume snapshots, stored in a separate object storage bucket.
3. **Multi-region standby** cluster for production workloads that cannot tolerate multi-hour RTO.
4. **Monthly restore drills** that exercise both etcd restore and Velero restore paths.
5. **Runbooks** that have been used successfully in a drill within the last quarter.
6. **Monitoring and alerting** on backup job success/failure, backup age, and storage health.

## Common Mistakes and Misconceptions

- **"Backing up etcd is enough for DR."** etcd contains cluster state, but not PersistentVolume data, external DNS records, cloud load balancers, or IAM configurations. A complete DR plan includes application data, infrastructure-as-code, and secrets.
- **"Velero backs up everything."** Velero backs up Kubernetes resources and can snapshot cloud volumes, but it doesn't back up external databases, object storage contents, or resources managed outside K8s. Know what's covered and what isn't.
- **"I'll figure out DR when I need it."** By definition, you need DR during an emergency when you have the least capacity for planning. Test restores quarterly. An untested backup is not a backup.

## Further Reading

- [Velero Documentation](https://velero.io/docs/) --- the open-source tool for backing up and restoring Kubernetes cluster resources and persistent volumes, including scheduled backups, storage provider plugins, and restore workflows.
- [Kubernetes Documentation: Operating etcd Clusters](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/) --- the official guide covering etcd backup and restore procedures, snapshot management, and cluster upgrade strategies.
- [Kubernetes Documentation: Backing Up an etcd Cluster](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#backing-up-an-etcd-cluster) --- step-by-step instructions for taking etcd snapshots with etcdctl and restoring from them.
- [Velero: Disaster Recovery](https://velero.io/docs/main/disaster-case/) --- Velero's official disaster recovery guide covering scheduled backups, storage location management, and step-by-step restore procedures.
- [AWS EKS Best Practices: Disaster Recovery](https://aws.github.io/aws-eks-best-practices/reliability/docs/application/) --- AWS-specific patterns for multi-region EKS deployments, cross-region replication, and failover automation.
- [Google Cloud: Disaster Recovery Planning Guide](https://cloud.google.com/architecture/dr-scenarios-planning-guide) --- Google's framework for DR planning including cold, warm, and hot standby patterns applicable to GKE and hybrid deployments.
- [Kubernetes SIG Cluster Lifecycle](https://github.com/kubernetes/community/tree/master/sig-cluster-lifecycle) --- the upstream SIG responsible for cluster provisioning, upgrades, and lifecycle tooling that underpins recovery automation.

---

**Next:** [Cost Optimization](44-cost-optimization.md) --- making sure all this infrastructure is not more expensive than it needs to be.

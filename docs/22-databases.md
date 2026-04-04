# Chapter 22: Databases on Kubernetes

"Should we run our database on Kubernetes?" is one of the most debated questions in the Kubernetes community, and the debate persists because the answer is genuinely nuanced. It depends on what database, what workload, what team, and what alternatives exist. This chapter gives you the framework to make that decision honestly, without the hype that surrounds Kubernetes operators or the fear that keeps teams from exploring the option.

## The Great Debate

The argument against databases on Kubernetes is simple: databases are the most important component in most architectures, and Kubernetes was designed for stateless, ephemeral workloads. Pods get rescheduled. Nodes fail. Network partitions happen. Storage has latency. Every one of these events is routine for a web server and potentially catastrophic for a database.

The argument for databases on Kubernetes is equally simple: managed database services are expensive, lock you into a cloud provider, and do not exist on-premises. Kubernetes operators can automate the same operational tasks that managed services handle --- failover, backup, replication --- and they work everywhere Kubernetes runs.

Both arguments are correct. The question is which trade-offs matter more for your specific situation.

## The Honest Assessment

**For revenue-critical systems, managed database services remain superior.** AWS RDS, Google Cloud SQL, and Azure Database for PostgreSQL have teams of database engineers whose full-time job is handling failover, patching, backup, and recovery. They have years of operational experience encoded into their automation. The cost premium you pay for a managed service is insurance against the operational complexity you would otherwise absorb.

**For development, testing, and non-critical workloads, Kubernetes databases are excellent.** They provide consistent environments across dev/staging/production, they are easy to spin up and tear down, and they integrate naturally with the rest of your Kubernetes tooling.

**For on-premises deployments, Kubernetes operators are often the best option available.** When managed services do not exist, the choice is between hand-managing databases on VMs and using an operator that automates the hardest parts. The operator wins in most cases.

## Decision Framework

| Tier | Description | Recommendation |
|------|-------------|----------------|
| **Development / Test** | Non-production, disposable data | Kubernetes --- fast to create, fast to destroy |
| **Tier 2-3 Services** | Internal tools, analytics, non-revenue workloads | Kubernetes --- acceptable with good operators and monitoring |
| **Revenue-Critical** | Customer-facing, SLA-bound, data-loss-intolerant | Managed service --- unless you have strong database operations expertise |
| **On-Premises** | No managed services available | Kubernetes operators --- best available option |
| **Regulatory / Compliance** | Data residency, air-gapped environments | Kubernetes operators --- often the only option that satisfies constraints |

This is not a permanent ranking. The Kubernetes database ecosystem matures every year. Five years from now, running production databases on Kubernetes may be as routine as running web servers. But today, the operational gap between managed services and operators is real.

## The Pets vs Cattle Nuance

The "pets vs cattle" metaphor says that modern infrastructure should treat servers like cattle (interchangeable, disposable) rather than pets (unique, irreplaceable). Kubernetes embodies this philosophy for stateless workloads. But databases are pets. A PostgreSQL primary node has unique state that cannot be recreated from a container image. Its data represents months or years of accumulated state.

StatefulSets are Kubernetes's acknowledgment that some workloads are pets. The stable identity, ordered operations, and persistent storage guarantees exist specifically because not everything can be cattle. The question is not whether to treat databases as pets --- they are pets --- but whether Kubernetes provides the right tools for pet care.

Operators are the answer. An operator is a custom controller that encodes domain-specific operational knowledge into software. A PostgreSQL operator knows how to initialize a replica from a base backup, how to promote a replica to primary during failover, how to manage connection pooling, and how to schedule backups. It turns the pet care into automated, repeatable processes.

## The Operator Landscape

### PostgreSQL

PostgreSQL has the most mature operator ecosystem on Kubernetes.

**CloudNativePG** --- The strongest momentum in 2025. A CNCF Sandbox project with a clean architecture that runs the operator and the database in the same container (no sidecar model). Supports automated failover, continuous backup to object storage (S3, GCS, Azure Blob), point-in-time recovery, connection pooling via PgBouncer, and declarative configuration. The project's velocity and community engagement make it the default choice for new deployments.

**Crunchy Data PGO (postgres-operator)** --- The most battle-tested option. Crunchy Data has been running PostgreSQL on Kubernetes since before it was fashionable. PGO supports pgBackRest for backup (the gold standard for PostgreSQL backup), high availability via Patroni, connection pooling, monitoring integration, and multi-cluster replication. Choose this if you want the operator with the longest production track record.

**Zalando postgres-operator** --- A simpler operator that grew out of Zalando's internal Kubernetes usage. Good for straightforward PostgreSQL deployments but development velocity has slowed compared to CloudNativePG and PGO. Still a reasonable choice for teams that value simplicity.

### MySQL

**Percona Operator for MySQL** --- Supports both Percona XtraDB Cluster (Galera-based synchronous replication) and MySQL group replication. Backup to S3, automated failover, proxy via HAProxy or ProxySQL.

**Vitess** --- Not strictly a MySQL operator but a database clustering system that runs on Kubernetes. Used by Slack, GitHub, and originally developed at YouTube. Vitess is the right choice when you need horizontal sharding of MySQL at massive scale. It is not the right choice for a single PostgreSQL-equivalent deployment.

### Other Databases

**MongoDB Community Operator** --- Manages MongoDB replica sets on Kubernetes. The enterprise version from MongoDB Inc. adds Ops Manager integration.

**Redis (via Spotahome operator or Redis Enterprise)** --- Redis Sentinel and Redis Cluster topologies. Redis is simpler to operate than relational databases because it is primarily in-memory, but persistence and replication still require operational care.

**Apache Kafka (Strimzi)** --- The dominant Kafka operator. Strimzi manages Kafka brokers, ZooKeeper (or KRaft), topics, users, and MirrorMaker. Kafka on Kubernetes is now mainstream, partly because Kafka's distributed architecture maps well to StatefulSet semantics.

## What Makes Database Operators Hard

Running a database is not just "deploy the binary and connect." A production database requires a constellation of supporting capabilities that an operator must handle:

```
OPERATOR RECONCILIATION LOOP
──────────────────────────────

  ┌─────────────────────────────────────────────────────┐
  │                  Desired State (CR)                  │
  │   PostgresCluster: replicas=3, backup=daily,        │
  │   version=16, storage=100Gi, pooler=pgbouncer       │
  └──────────────────────┬──────────────────────────────┘
                         │
                         ▼
  ┌─────────────────────────────────────────────────────┐
  │              Operator Controller                     │
  │                                                      │
  │   for each reconciliation loop:                      │
  │                                                      │
  │   1. Check cluster health                            │
  │      ├── Is primary alive?                           │
  │      ├── Are replicas streaming?                     │
  │      └── Is replication lag acceptable?              │
  │                                                      │
  │   2. Handle topology changes                         │
  │      ├── Scale up: init new replica from backup      │
  │      ├── Scale down: drain connections, remove       │
  │      └── Node failure: promote replica to primary    │
  │                                                      │
  │   3. Manage supporting services                      │
  │      ├── Connection pooler (PgBouncer/ProxySQL)      │
  │      ├── Backup schedule (base backup + WAL)         │
  │      ├── Monitoring endpoints (Prometheus)            │
  │      └── TLS certificates                            │
  │                                                      │
  │   4. Handle version upgrades                         │
  │      ├── Minor: rolling restart                      │
  │      └── Major: pg_upgrade or logical replication    │
  │                                                      │
  └──────────────────────┬──────────────────────────────┘
                         │
                         ▼
  ┌─────────────────────────────────────────────────────┐
  │              Managed Resources                       │
  │                                                      │
  │   StatefulSet(primary)  StatefulSet(replicas)        │
  │   Service(read-write)   Service(read-only)           │
  │   PVCs(data)            ConfigMaps(postgresql.conf)  │
  │   Secrets(passwords)    CronJob(backup)              │
  │   Deployment(pooler)    ServiceMonitor(metrics)      │
  └─────────────────────────────────────────────────────┘
```

Each of these responsibilities is a failure mode:

**Leader Election and Failover** --- When the primary fails, the operator must detect the failure, select the most up-to-date replica, promote it, reconfigure all other replicas to follow the new primary, and update the read-write Service endpoint. This must happen in seconds, without data loss, and without split-brain (two nodes both believing they are primary). Getting this wrong is the single most dangerous failure mode for a database.

**Replication** --- The operator must configure streaming replication (for PostgreSQL) or group replication (for MySQL), monitor replication lag, and handle replicas that fall behind. A replica that loses its replication slot must be rebuilt from a base backup, which can take hours for large databases.

**Backup and Recovery** --- Continuous backup involves both periodic base backups (full snapshots of the data directory) and continuous WAL (write-ahead log) archival. The operator must verify backup integrity, manage backup retention, and support point-in-time recovery to any moment in the past.

**Version Upgrades** --- Minor version upgrades (16.1 to 16.2) are typically rolling restarts. Major version upgrades (15 to 16) require data migration via `pg_upgrade` or logical replication. Both must be done without extended downtime.

**Connection Pooling** --- Database connections are expensive (each consumes memory and a process/thread). A connection pooler like PgBouncer sits between the application and the database, multiplexing many application connections onto a smaller number of database connections. The operator manages the pooler's lifecycle and configuration.

**Dual Monitoring** --- You need both Kubernetes-level monitoring (pod health, resource usage, PVC capacity) and database-level monitoring (query latency, lock contention, replication lag, cache hit ratio). These are complementary and both are essential.

## The Real Cost of Self-Managing

When evaluating "run it on K8s" vs "use a managed service," teams often compare only the compute cost. The real comparison is:

| Cost Factor | Managed Service | Kubernetes Operator |
|-------------|----------------|-------------------|
| **Compute** | Higher (managed premium) | Lower (your nodes) |
| **Engineering time** | Low (vendor handles operations) | Significant (you handle operations the operator cannot) |
| **Failure recovery** | Vendor SLA | Your team's expertise |
| **Backup verification** | Vendor responsibility | Your responsibility to test restores |
| **Major version upgrades** | Often push-button | Often manual coordination |
| **Compliance auditing** | Vendor provides documentation | You provide documentation |

If your team has strong database operations expertise and the time to invest in it, Kubernetes operators are a powerful tool. If your team's expertise is in application development and they view the database as infrastructure that should just work, a managed service is the better choice.

## A Pragmatic Path

Many organizations adopt a layered approach:

1. **Start with managed services** for production databases. Do not optimize costs before you have a working system.
2. **Use Kubernetes databases for dev/test.** This gives your team experience with the operator and ensures dev/test environments match production topology.
3. **Evaluate migration to Kubernetes** for Tier 2-3 workloads after your team has built confidence with the operator in non-production environments.
4. **Keep revenue-critical databases on managed services** unless you have a compelling reason to move them (cost, compliance, on-premises requirement).

This path minimizes risk while building the operational muscle needed to run databases on Kubernetes if and when it makes sense.

## Common Mistakes and Misconceptions

- **"Never run databases on Kubernetes."** This was good advice in 2018. Modern operators (CloudNativePG, Percona, Vitess) handle replication, failover, backup, and restore. For many teams, K8s-native databases are simpler than managing separate DB infrastructure.
- **"Kubernetes storage is too slow for databases."** Cloud SSDs (gp3, pd-ssd) provide consistent IOPS. Local NVMe on dedicated node pools rivals bare-metal performance. The storage layer is rarely the bottleneck.
- **"A database operator means zero operational effort."** Operators automate routine tasks but still require monitoring, capacity planning, backup verification, and version upgrade planning. They reduce effort, not eliminate it.

## Further Reading

- [CloudNativePG documentation](https://cloudnative-pg.io/documentation/) --- The leading PostgreSQL operator
- [Crunchy Data PGO](https://access.crunchydata.com/documentation/postgres-operator/) --- Battle-tested PostgreSQL operator
- [Strimzi documentation](https://strimzi.io/documentation/) --- Kafka on Kubernetes
- [Data on Kubernetes community](https://dok.community/) --- Community focused on stateful workloads
- [KubeCon talk: "Is Running Databases on Kubernetes Practical?"](https://www.youtube.com/results?search_query=kubecon+databases+kubernetes) --- Real-world experience reports

---

*Next: [Persistent Storage Patterns](23-storage-patterns.md) --- volumeClaimTemplates, reclaim policies, backup, and resize.*

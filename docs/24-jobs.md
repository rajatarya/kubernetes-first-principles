# Chapter 24: Jobs and CronJobs

Not every workload is a long-running service. Some workloads run to completion: a database migration, a batch data transformation, an ML training run, a nightly report. Deployments and StatefulSets are the wrong abstraction for these workloads because they try to keep pods running forever.
Jobs and CronJobs are Kubernetes's answer to batch and scheduled workloads. A Job creates one or more pods, runs them to completion, and then stops. A CronJob creates Jobs on a schedule. The concepts are simple, but the details --- completion modes, parallelism, failure handling, and concurrency policies --- matter enormously for production reliability.

## Jobs: Run to Completion

A Job ensures that a specified number of pods successfully terminate. The simplest Job runs a single pod:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migration
spec:
  template:
    spec:
      containers:
        - name: migrate
          image: my-app:v2.1.0
          command: ["./migrate", "--target", "v2.1"]
      restartPolicy: Never        # Jobs require Never or OnFailure
  backoffLimit: 3                 # Retry up to 3 times on failure
  activeDeadlineSeconds: 600      # Kill the Job if it runs longer than 10 minutes
  ttlSecondsAfterFinished: 3600   # Clean up completed Job after 1 hour
```

Key fields:

- **`restartPolicy`**: Must be `Never` or `OnFailure`. Jobs cannot use the default `Always` because that would restart the pod after successful completion.
- **`backoffLimit`**: How many times to retry before marking the Job as failed. Each retry uses exponential backoff (10s, 20s, 40s, ...).
- **`activeDeadlineSeconds`**: A hard timeout for the entire Job. If the Job has not completed within this duration, all running pods are terminated and the Job is marked as failed.
- **`ttlSecondsAfterFinished`**: How long to keep the completed (or failed) Job object before garbage collection. Without this, completed Jobs accumulate forever.

## Completion Modes

Jobs support two completion modes that determine how "done" is defined:

### NonIndexed (Default)

The Job is complete when `.spec.completions` pods have succeeded. Each pod is interchangeable --- they all run the same work.

```yaml
spec:
  completions: 5          # 5 pods must succeed
  parallelism: 3          # Run up to 3 pods at a time
  completionMode: NonIndexed
```

This creates 5 pods (3 at a time), each running the same task. If any pod fails, a replacement is created (up to `backoffLimit`). When 5 pods have exited with status 0, the Job is complete.

### Indexed

Each pod gets a unique index (0 through completions-1) via the `JOB_COMPLETION_INDEX` environment variable. This enables work partitioning: each pod processes a different shard of data.

```yaml
spec:
  completions: 10         # 10 indexed pods (0-9)
  parallelism: 5          # Run up to 5 pods at a time
  completionMode: Indexed
```

Each pod knows its identity: pod with index 3 reads `JOB_COMPLETION_INDEX=3` from its environment and processes the corresponding data partition. The Job is complete when each index (0 through 9) has one successful pod.

Indexed Jobs are the Kubernetes-native way to implement MapReduce-style parallelism. Instead of a single pod processing a 1TB dataset, ten pods each process 100GB.

## Parallelism Patterns

The interaction between `completions` and `parallelism` produces different execution patterns:

```
JOB PARALLELISM PATTERNS
──────────────────────────

Pattern 1: Single Pod (default)
completions=1, parallelism=1

  Time ──────────────────────►
  ┌──────────────────┐
  │     Pod 0        │ ✓ Done
  └──────────────────┘


Pattern 2: Fixed Completion Count
completions=5, parallelism=2

  Time ──────────────────────────────────────►
  ┌──────────────┐
  │   Pod 0      │ ✓
  └──────────────┘
  ┌──────────────┐
  │   Pod 1      │ ✓
  └──────────────┘
                   ┌──────────────┐
                   │   Pod 2      │ ✓
                   └──────────────┘
                   ┌──────────────┐
                   │   Pod 3      │ ✓
                   └──────────────┘
                                    ┌──────────────┐
                                    │   Pod 4      │ ✓
                                    └──────────────┘

  2 pods run at a time. 5 must succeed total.


Pattern 3: Work Queue (external coordination)
completions=unset, parallelism=5

  Time ──────────────────────────────────────►
  ┌──────────────────────────────────────┐
  │   Pod 0 (processes items from queue) │ ✓
  └──────────────────────────────────────┘
  ┌────────────────────────────────┐
  │   Pod 1                        │ ✓
  └────────────────────────────────┘
  ┌────────────────────────────────────────────┐
  │   Pod 2                                    │ ✓
  └────────────────────────────────────────────┘
  ┌──────────────────────────────────┐
  │   Pod 3                          │ ✓
  └──────────────────────────────────┘
  ┌──────────────────────┐
  │   Pod 4              │ ✓
  └──────────────────────┘

  All 5 pods run simultaneously.
  Each pulls work from an external queue (SQS, Redis, RabbitMQ).
  When a pod exits successfully, it is not restarted.
  Job completes when at least one pod terminates successfully
  and all other pods have also terminated.


Pattern 4: Indexed Parallel
completions=4, parallelism=4, completionMode=Indexed

  Time ──────────────────────────────────────►
  ┌──────────────────────┐
  │  Pod 0 (index=0)     │ ✓ processes partition 0
  └──────────────────────┘
  ┌────────────────────────────┐
  │  Pod 1 (index=1)          │ ✓ processes partition 1
  └────────────────────────────┘
  ┌──────────────────┐
  │  Pod 2 (index=2) │ ✓ processes partition 2
  └──────────────────┘
  ┌──────────────────────────────────┐
  │  Pod 3 (index=3)                │ ✓ processes partition 3
  └──────────────────────────────────┘

  Each pod gets JOB_COMPLETION_INDEX env var.
  Each processes its assigned data shard.
```

| Pattern | `completions` | `parallelism` | Use Case |
|---------|--------------|---------------|----------|
| Single pod | 1 (default) | 1 (default) | Database migration, one-off script |
| Fixed count | N | M (M <= N) | Batch processing with known work items |
| Work queue | unset | N | Queue-driven processing (SQS, RabbitMQ) |
| Indexed | N | M | Data partitioning, parallel map operations |

## Failure Handling

### backoffLimit

When a pod fails (exits with non-zero status or is evicted), Kubernetes retries with exponential backoff. The delay between retries starts at 10 seconds and doubles each time (10s, 20s, 40s, ...), capped at 6 minutes.

```yaml
spec:
  backoffLimit: 6           # Allow up to 6 failures before giving up
```

After `backoffLimit` failures, the Job is marked as `Failed`. The default is 6.

### activeDeadlineSeconds

A safety net for Jobs that might hang. If the Job has not completed after this many seconds, all pods are killed and the Job fails:

```yaml
spec:
  activeDeadlineSeconds: 3600    # Hard timeout: 1 hour
```

This is essential for production Jobs. Without it, a hung Job consumes resources indefinitely. Always set this to a value comfortably above the expected runtime.

### Pod Failure Policy

Introduced in v1.26 (stable in v1.31), Pod Failure Policy gives fine-grained control over how specific failure types are handled. Instead of treating all failures the same, you can define rules:

```yaml
spec:
  podFailurePolicy:
    rules:
      - action: FailJob                      # Immediately fail the entire Job
        onExitCodes:
          containerName: migrate
          operator: In
          values: [42]                        # Exit code 42 = unrecoverable error

      - action: Ignore                        # Do not count toward backoffLimit
        onPodConditions:
          - type: DisruptionTarget            # Node drain, preemption, etc.

      - action: Count                         # Default: count toward backoffLimit
        onExitCodes:
          containerName: migrate
          operator: In
          values: [1]                         # Exit code 1 = transient, worth retrying
```

This is powerful for distinguishing between transient failures (network timeout, node eviction) and permanent failures (invalid input, schema mismatch). Without Pod Failure Policy, a pod that fails due to node preemption counts toward `backoffLimit` the same as a pod that fails due to a bug --- which is wasteful because the preempted pod should just be retried without penalty.

### ttlSecondsAfterFinished

Completed Jobs (both successful and failed) remain in the cluster until garbage collected. Without `ttlSecondsAfterFinished`, they stay forever, cluttering `kubectl get jobs` output and consuming API server resources:

```yaml
spec:
  ttlSecondsAfterFinished: 86400    # Remove 24 hours after completion
```

Set this on every Job. The appropriate TTL depends on how long you need the Job (and its pod logs) for debugging.

## CronJobs: Scheduled Execution

A CronJob creates Jobs on a schedule. The scheduling uses standard cron syntax:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: nightly-backup
spec:
  schedule: "0 2 * * *"               # 2:00 AM every day
  timeZone: "America/New_York"         # Stable since v1.27
  concurrencyPolicy: Forbid            # Do not start a new Job if the previous is still running
  startingDeadlineSeconds: 300         # If missed by more than 5 minutes, skip this run
  successfulJobsHistoryLimit: 3        # Keep last 3 successful Jobs
  failedJobsHistoryLimit: 5            # Keep last 5 failed Jobs
  jobTemplate:
    spec:
      activeDeadlineSeconds: 7200      # Each Job has a 2-hour timeout
      backoffLimit: 2
      template:
        spec:
          containers:
            - name: backup
              image: backup-tool:v1.3
              command: ["./backup.sh"]
          restartPolicy: OnFailure
```

### Cron Syntax

```
┌───────────── minute (0-59)
│ ┌───────────── hour (0-23)
│ │ ┌───────────── day of month (1-31)
│ │ │ ┌───────────── month (1-12)
│ │ │ │ ┌───────────── day of week (0-6, Sunday=0)
│ │ │ │ │
* * * * *
```

Examples:
- `0 2 * * *` --- Every day at 2:00 AM
- `*/15 * * * *` --- Every 15 minutes
- `0 0 1 * *` --- First day of every month at midnight
- `0 9 * * 1-5` --- Weekdays at 9:00 AM

### timeZone

Before v1.25, CronJobs used the kube-controller-manager's local timezone, which was usually UTC but not always. The `timeZone` field (stable since v1.27) lets you specify the timezone explicitly. "Every day at 2 AM" is meaningless without a timezone.

### concurrencyPolicy

What happens when it is time to start a new Job but the previous one is still running?

| Policy | Behavior | When to Use |
|--------|----------|-------------|
| **Allow** | Start the new Job alongside the running one | Independent jobs where overlap is safe |
| **Forbid** | Skip the new Job if the previous is still running | Backups, database maintenance, anything that should not overlap |
| **Replace** | Kill the running Job and start a new one | Long-running jobs where the latest run supersedes previous runs |

**`Forbid` is the safest default for most production CronJobs.** Two concurrent backup jobs competing for the same database locks is a recipe for failures.

### startingDeadlineSeconds

If the CronJob controller misses a scheduled run (for example, because the controller was down or the cluster was overloaded), `startingDeadlineSeconds` controls how long after the scheduled time Kubernetes will still attempt to start the Job:

```yaml
spec:
  startingDeadlineSeconds: 300    # If missed by more than 5 minutes, skip
```

Without this, Kubernetes counts missed schedules and may try to start all of them at once when the controller recovers. If more than 100 schedules were missed, the CronJob is marked as unable to be scheduled. Setting `startingDeadlineSeconds` provides a clean cutoff.

### History Limits

```yaml
spec:
  successfulJobsHistoryLimit: 3    # Keep 3 successful completed Jobs
  failedJobsHistoryLimit: 5        # Keep 5 failed Jobs (more for debugging)
```

These control how many completed Job objects are retained. Keep enough for debugging (especially for failed Jobs) but not so many that they clutter the cluster.

## Real-World Use Cases

### Data Pipeline Stage

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: etl-daily-20260403
spec:
  completions: 10
  parallelism: 5
  completionMode: Indexed
  backoffLimit: 3
  activeDeadlineSeconds: 14400    # 4 hours max
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      containers:
        - name: etl
          image: data-pipeline:v3.0
          command: ["./process_partition.sh"]
          env:
            - name: TOTAL_PARTITIONS
              value: "10"
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
            limits:
              cpu: "4"
              memory: 8Gi
      restartPolicy: Never
```

Each of the 10 indexed pods processes one partition of the daily data. Five run in parallel. The `JOB_COMPLETION_INDEX` environment variable tells each pod which partition to process.

### Database Backup CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pg-backup
spec:
  schedule: "0 3 * * *"
  timeZone: "UTC"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 600
  successfulJobsHistoryLimit: 7
  failedJobsHistoryLimit: 10
  jobTemplate:
    spec:
      activeDeadlineSeconds: 3600
      backoffLimit: 2
      ttlSecondsAfterFinished: 604800    # Keep for 7 days
      template:
        spec:
          containers:
            - name: backup
              image: postgres:16.2
              command:
                - /bin/bash
                - -c
                - |
                  pg_dump -h db-0.db.default.svc.cluster.local \
                    -U backup_user -Fc mydb | \
                    aws s3 cp - s3://my-backups/pg/$(date +%Y%m%d).dump
              envFrom:
                - secretRef:
                    name: pg-backup-credentials
          restartPolicy: OnFailure
```

### ML Training Job

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: training-run-042
spec:
  completions: 1
  parallelism: 1
  backoffLimit: 1                    # Do not retry expensive training
  activeDeadlineSeconds: 86400       # 24-hour timeout
  ttlSecondsAfterFinished: 604800   # Keep for a week (to check logs)
  template:
    spec:
      containers:
        - name: train
          image: ml-training:v2.1
          command: ["python", "train.py", "--epochs", "100"]
          resources:
            requests:
              cpu: "8"
              memory: 32Gi
              nvidia.com/gpu: "1"
            limits:
              cpu: "8"
              memory: 32Gi
              nvidia.com/gpu: "1"
          volumeMounts:
            - name: model-output
              mountPath: /output
      volumes:
        - name: model-output
          persistentVolumeClaim:
            claimName: training-output
      restartPolicy: Never
```

## Jobs vs Other Workload Types

| Question | Answer |
|----------|--------|
| Should it run forever? | Use Deployment or StatefulSet |
| Should it run once and stop? | Use Job |
| Should it run on a schedule? | Use CronJob |
| Should it run on every node? | Use DaemonSet |
| Does it need stable identity? | Use StatefulSet |
| Does it need parallel indexed processing? | Use Job with `completionMode: Indexed` |

## Common Mistakes and Misconceptions

- **"CronJobs are reliable for exactly-once execution."** CronJobs can create 0 or 2+ Jobs for a single schedule point (missed schedules, clock skew). Use `concurrencyPolicy: Forbid` and design jobs to be idempotent.
- **"Failed Jobs retry forever."** Jobs respect `backoffLimit` (default 6). After that many failures, the Job is marked Failed. Set `activeDeadlineSeconds` to prevent runaway jobs consuming resources.
- **"Jobs clean up after themselves."** Completed and Failed Jobs (and their pods) persist in the API until you or a TTL controller deletes them. Set `ttlSecondsAfterFinished` to auto-clean, or they accumulate and clutter `kubectl get pods`.

## Further Reading

- [Jobs documentation](https://kubernetes.io/docs/concepts/workloads/controllers/job/) --- Official Job reference
- [CronJob documentation](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) --- Official CronJob reference
- [Pod Failure Policy](https://kubernetes.io/docs/concepts/workloads/controllers/job/#pod-failure-policy) --- Fine-grained failure handling
- [Indexed Job for Parallel Processing](https://kubernetes.io/docs/tasks/job/indexed-parallel-processing-static/) --- Tutorial on indexed Jobs
- [Crontab Guru](https://crontab.guru/) --- Interactive cron expression editor

---

*This concludes Part 4: Stateful Workloads. You now know how to run applications that need stable identity, persistent storage, and batch processing semantics. Part 5 turns to the question that becomes urgent once you are running real workloads: how do you secure them?*

Next: [RBAC from First Principles](25-rbac.md)

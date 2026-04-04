# Chapter 33: Resource Tuning Deep Dive

Kubernetes resource management appears simple on the surface: set `requests` and `limits` for CPU and memory, and the scheduler handles the rest. Underneath, these values translate directly into Linux kernel mechanisms --- cgroup parameters that throttle CPU access and kill processes that exceed memory bounds. Getting these values wrong causes throttling on idle nodes, random OOM kills, and wasted capacity at scale. Understanding resource tuning from first principles requires understanding the kernel mechanisms themselves.

## CFS Quota Mechanics

When you set a CPU limit on a container, Kubernetes translates it into two cgroup v2 parameters (or cgroup v1 equivalents):

- **`cpu.cfs_period_us`**: The length of the scheduling period, always 100,000 microseconds (100ms).
- **`cpu.cfs_quota_us`**: The total CPU time the container may consume within each period.

The formula is:

```
cpu.cfs_quota_us = cpu_limit * cpu.cfs_period_us
```

For a container with a CPU limit of `500m` (half a core):

```
cpu.cfs_quota_us = 0.5 * 100,000 = 50,000 us
```

This means the container can use at most 50ms of CPU time in every 100ms period. If it uses its 50ms in the first 30ms of the period, the kernel **throttles** it --- the container gets zero CPU for the remaining 70ms, even if the node's other cores are completely idle.

```
CFS PERIOD AND QUOTA
─────────────────────

  cpu.cfs_period_us = 100,000 (100ms)
  cpu.cfs_quota_us  =  50,000 (50ms)  ← limit: 500m

  Period 1                    Period 2
  ├──────────────────────────┤──────────────────────────┤
  │████████████░░░░░░░░░░░░░░│████████████░░░░░░░░░░░░░░│
  │← 50ms used →│← throttled│← 50ms used →│← throttled│
  │             │   50ms    →│             │   50ms    →│
  └──────────────────────────┘──────────────────────────┘

  Container bursts to full speed, exhausts quota in 50ms,
  then sits idle for 50ms. Latency spikes every 100ms.


  Multi-threaded container with limit: 1000m (1 core)
  and 4 threads running simultaneously:

  ├──────────────────────────┤
  │ Thread 1: ██████ (25ms)  │
  │ Thread 2: ██████ (25ms)  │  Total: 100ms of CPU time
  │ Thread 3: ██████ (25ms)  │  consumed in first 25ms
  │ Thread 4: ██████ (25ms)  │  of wall-clock time
  │                          │
  │ ALL THREADS THROTTLED    │  Quota exhausted.
  │ for remaining 75ms       │  75ms of wall-clock
  │░░░░░░░░░░░░░░░░░░░░░░░░░│  latency added.
  └──────────────────────────┘
```

## The Throttling Paradox

This is the most counterintuitive aspect of CPU limits: **a container can be heavily throttled even when the node has plenty of idle CPU.** CFS quotas are enforced per-container, regardless of overall node utilization. The kernel does not say "the node is 30% utilized, let this container use more." It says "this container has used its quota for this period, stop."

You can observe throttling via:

```bash
# cgroup v2
cat /sys/fs/cgroup/<pod-cgroup>/cpu.stat

# Look for:
#   nr_throttled    ← number of times throttled
#   throttled_usec  ← total time spent throttled (microseconds)
```

Or via Prometheus:

```promql
rate(container_cpu_cfs_throttled_seconds_total[5m])
  / rate(container_cpu_cfs_periods_total[5m])
```

A throttle ratio above 10--20% indicates the limit is actively harming performance.

## Why NOT Setting CPU Limits Is Sometimes Better

For bursty workloads --- web servers, API gateways, batch processors --- CPU usage is spiky. A request handler might be idle for 95ms, then need 40ms of CPU to process a request. With a 500m limit, the container has 50ms of quota per period, which is enough for the burst. But if two requests arrive in the same period, the container needs 80ms and gets throttled for 20ms.

Removing the CPU limit entirely allows the container to burst to whatever the node can provide. The container still has a CPU **request**, which guarantees it a minimum share of CPU via CFS weight (the `cpu.weight` cgroup parameter). Requests affect scheduling and provide a proportional minimum, but without a limit, there is no hard ceiling.

```yaml
resources:
  requests:
    cpu: 500m       # Guaranteed minimum share
    memory: 256Mi
  limits:
    # cpu: omitted  # No hard ceiling --- container can burst
    memory: 512Mi   # Memory limits should ALWAYS be set
```

**When to remove CPU limits:**
- Web servers, API handlers, and other latency-sensitive, bursty workloads
- When throttling metrics show significant throttle ratios
- When the cluster has spare CPU capacity (requests < node allocatable)

**When to keep CPU limits:**
- Multi-tenant clusters where one workload could starve others
- Batch jobs that would happily consume every available core
- Environments that require Guaranteed QoS class (limits must equal requests)

**Always keep memory limits.** Unlike CPU (which throttles), exceeding a memory limit causes the OOM killer to terminate the container. Memory is an incompressible resource --- the kernel cannot "slow down" memory usage the way it can pause CPU access.

## QoS Classes

Kubernetes assigns every pod a Quality of Service class based on its resource configuration. QoS determines eviction priority when a node runs out of resources.

```
QoS CLASSES AND EVICTION ORDER
────────────────────────────────

  EVICTED FIRST                              EVICTED LAST
  ◄──────────────────────────────────────────────────────►

  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐
  │  BestEffort  │  │  Burstable   │  │   Guaranteed     │
  │              │  │              │  │                  │
  │  No requests │  │  Requests    │  │  requests ==     │
  │  No limits   │  │  set, but    │  │  limits for      │
  │              │  │  limits !=   │  │  every container │
  │  First to    │  │  requests    │  │  in every pod    │
  │  die under   │  │  (or limits  │  │                  │
  │  pressure    │  │  missing)    │  │  Last to die     │
  └──────────────┘  └──────────────┘  └──────────────────┘
```

**BestEffort:** No resource requests or limits on any container. These pods are scheduled wherever there is room and are the first evicted. Appropriate only for truly disposable workloads (background log cleanup, test pods).

**Burstable:** At least one container has a request or limit, but they are not equal. This is the most common class. Eviction order within Burstable is based on how far the pod exceeds its requests.

**Guaranteed:** Every container in the pod has requests equal to limits for both CPU and memory. These pods get the highest scheduling priority and are evicted last. The trade-off is that Guaranteed pods cannot burst above their limits, which means you must size them for peak usage or accept throttling.

```yaml
# Guaranteed QoS
resources:
  requests:
    cpu: "2"
    memory: 4Gi
  limits:
    cpu: "2"         # Must equal request
    memory: 4Gi      # Must equal request
```

## Topology Manager and NUMA-Aware Scheduling

On multi-socket servers, memory access times vary depending on which CPU socket is accessing which memory bank. This is Non-Uniform Memory Access (NUMA). A process running on socket 0 accessing memory on socket 1 pays a latency penalty of 50--100 nanoseconds per access --- irrelevant for most workloads, but significant for high-performance computing, machine learning inference, and network-intensive pods using SR-IOV.

The **Topology Manager** is a kubelet component that coordinates resource allocation across CPU Manager, Memory Manager, and Device Manager to ensure aligned NUMA placement. It operates in four policies:

- **none:** No topology alignment (default).
- **best-effort:** Prefer aligned allocation but allow misalignment.
- **restricted:** Require aligned allocation; reject pods that cannot be aligned.
- **single-numa-node:** All resources must come from a single NUMA node.

Topology Manager only affects Guaranteed QoS pods. Burstable and BestEffort pods always get the default behavior.

## Node Allocatable vs Capacity

A node's total resources (capacity) are not entirely available for pods. The kubelet reserves resources for itself, the OS, and eviction thresholds:

```
NODE RESOURCE ACCOUNTING
─────────────────────────

  ┌──────────────────────────────────────┐
  │         Node Capacity (total)        │
  │         e.g., 16 CPU, 64 Gi memory  │
  │                                      │
  │  ┌──────────────────────────────┐    │
  │  │  kube-reserved               │    │
  │  │  (kubelet, container runtime)│    │
  │  │  cpu: 200m, memory: 1Gi     │    │
  │  └──────────────────────────────┘    │
  │  ┌──────────────────────────────┐    │
  │  │  system-reserved             │    │
  │  │  (OS daemons, sshd, journald)│   │
  │  │  cpu: 100m, memory: 500Mi   │    │
  │  └──────────────────────────────┘    │
  │  ┌──────────────────────────────┐    │
  │  │  eviction-threshold          │    │
  │  │  (hard: memory.available<100Mi)│  │
  │  └──────────────────────────────┘    │
  │  ┌──────────────────────────────┐    │
  │  │  ALLOCATABLE                 │    │
  │  │  = capacity - kube-reserved  │    │
  │  │    - system-reserved         │    │
  │  │    - eviction-threshold      │    │
  │  │                              │    │
  │  │  This is what pods can use.  │    │
  │  │  15.7 CPU, 62.4 Gi          │    │
  │  └──────────────────────────────┘    │
  └──────────────────────────────────────┘
```

The scheduler uses **allocatable**, not capacity, when deciding whether a pod fits on a node. If you do not set kube-reserved and system-reserved, the node can become unstable under load as the kubelet and OS compete with pods for resources.

## The Overcommitment Reality

In practice, most clusters are dramatically overcommitted on CPU and undercommitted on memory:

- Developers set CPU requests based on peak usage to avoid throttling.
- Actual average utilization is 10--15% of requested CPU across large clusters.
- Memory is harder to reclaim, so teams set memory requests closer to actual usage.

This means a cluster with 100 CPUs of total requests might only be using 13 CPUs at any given time. The remaining 87 CPUs are reserved but idle.

**Strategies for handling overcommitment:**

1. **VPA in Off mode** to identify overprovisioned workloads (see Chapter 31).
2. **Remove CPU limits** for bursty workloads so they can use idle CPU.
3. **Pod Priority and Preemption** to ensure critical workloads can evict less important ones.
4. **Cluster-level overcommit policies** (request-to-limit ratios in LimitRanges) to systematically set requests lower than limits.
5. **Right-size nodes.** A few large nodes waste less to fragmentation than many small nodes.

## Practical Guidelines

| Resource | Request | Limit | Rationale |
|---|---|---|---|
| CPU (latency-sensitive) | Set to P50 usage | Omit | Burst without throttling |
| CPU (batch/background) | Set to average | Set to max | Prevent neighbor starvation |
| Memory (all workloads) | Set to P95 usage | Set to P99 or max | Always limit memory |

Start with VPA recommendations in Off mode, remove CPU limits for web workloads, always set memory limits, and monitor `container_cpu_cfs_throttled_seconds_total` as a key performance indicator.

## Further Reading

- [Managing Resources for Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) --- Official resource management docs
- [CPU CFS Bandwidth Control](https://www.kernel.org/doc/Documentation/scheduler/sched-bwc.txt) --- Linux kernel CFS documentation
- [Topology Manager](https://kubernetes.io/docs/tasks/administer-cluster/topology-manager/) --- NUMA-aware resource allocation
- [Node Allocatable](https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/) --- Reserving compute resources

---

*This concludes Part 6: Scaling and Performance. You now understand how to scale pods horizontally and vertically, scale nodes underneath them, and tune resource allocation down to the kernel level. Part 7 zooms out from a single cluster to the organizational challenge: running multiple clusters, building internal developer platforms, and managing multi-tenancy.*

Next: [Multi-Cluster Strategies](34-multi-cluster.md)

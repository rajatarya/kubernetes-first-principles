# Chapter 30: Horizontal Pod Autoscaler

A deployment with a fixed replica count is a bet that traffic will stay constant. Traffic never stays constant. If you guess too low, pods become overloaded and latency spikes. If you guess too high, you pay for idle compute around the clock. The Horizontal Pod Autoscaler (HPA) replaces this guessing game with a feedback loop: measure demand, compute the right number of replicas, and adjust --- continuously.

Understanding HPA from first principles requires understanding the algorithm it uses, the metrics it consumes, how to extend it beyond built-in metrics, and the tuning knobs that prevent it from behaving erratically. At its core, the HPA is another instance of the [reconciliation loop](04-api-model.md) we described in Chapter 4: it observes current state (metrics), compares it to desired state (target utilization), and acts to close the gap.

## The Scaling Algorithm

The HPA controller runs a control loop every 15 seconds (configurable via `--horizontal-pod-autoscaler-sync-period`). Each iteration executes a single formula:

```
desiredReplicas = ceil( currentReplicas * ( currentMetricValue / desiredMetricValue ) )
```

This is a proportional controller. If you have 4 replicas running at 80% CPU and your target is 50% CPU, the math is:

```
desiredReplicas = ceil( 4 * (80 / 50) ) = ceil( 6.4 ) = 7
```

The HPA will scale from 4 to 7 replicas. When those 7 replicas bring average CPU down to 45%, the formula produces:

```
desiredReplicas = ceil( 7 * (45 / 50) ) = ceil( 6.3 ) = 7
```

No change. The system has stabilized.

### The 10% Tolerance Band

To prevent constant oscillation around the target, the HPA applies a **tolerance of 0.1** (10%). If the ratio `currentMetric / desiredMetric` falls within `[0.9, 1.1]`, the HPA takes no action. This dead zone prevents the controller from chasing noise.

```
HPA FEEDBACK LOOP
─────────────────

   ┌─────────────────────────────────────────────────────────┐
   │                    HPA Controller                       │
   │                  (runs every 15s)                       │
   │                                                         │
   │   1. Fetch current metric values from Metrics API       │
   │   2. Compute ratio = currentMetric / desiredMetric      │
   │   3. If ratio within [0.9, 1.1] → no action            │
   │   4. desiredReplicas = ceil(current * ratio)            │
   │   5. Clamp to [minReplicas, maxReplicas]                │
   │   6. Patch Deployment .spec.replicas                    │
   │                                                         │
   └──────────┬──────────────────────────────┬───────────────┘
              │                              │
              │ scale up/down                │ fetch metrics
              ▼                              ▼
   ┌──────────────────┐          ┌───────────────────────┐
   │   Deployment     │          │   Metrics API         │
   │   Controller     │          │                       │
   │                  │          │   metrics.k8s.io      │
   │  Adjusts Pod     │          │   (CPU, memory)       │
   │  count to match  │          │                       │
   │  .spec.replicas  │          │   custom.metrics.k8s  │
   └────────┬─────────┘          │   (requests/sec, etc) │
            │                    │                       │
            ▼                    │   external.metrics.k8s│
   ┌──────────────────┐          │   (SQS depth, etc)   │
   │  Running Pods    │──────────┘                       │
   │  (report metrics │   metrics scraped                │
   │   via cAdvisor   │   from pods                      │
   │   or custom)     │                                  │
   └──────────────────┘          └───────────────────────┘
```

## Default Metrics: CPU and Memory

The simplest HPA targets CPU utilization:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-frontend
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web-frontend
  minReplicas: 2
  maxReplicas: 20
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
```

**Critical prerequisite:** CPU utilization is computed as a percentage of the pod's **resource request**. If your pods do not have `resources.requests.cpu` set, the HPA cannot compute utilization and will refuse to scale. This is the single most common HPA misconfiguration.

You can target memory the same way, but memory-based scaling is tricky. Many applications (JVM, Python, Go with large heaps) allocate memory and never release it. Scaling up works, but scaling down may never trigger because memory consumption does not drop when load drops.

## Custom Metrics via Prometheus Adapter

Built-in CPU and memory metrics are crude. Most services should scale on business-relevant metrics: requests per second, queue depth, p99 latency. The custom metrics API (`custom.metrics.k8s.io`) provides the abstraction; **Prometheus Adapter** is the most common implementation that bridges Prometheus metrics into this API.

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-server
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-server
  minReplicas: 3
  maxReplicas: 50
  metrics:
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "1000"
```

The Prometheus Adapter configuration maps PromQL queries to Kubernetes metric names. When the HPA asks "what is the current value of `http_requests_per_second` for deployment `api-server`?", the adapter executes the corresponding PromQL query and returns the result.

## KEDA: Event-Driven Autoscaling

KEDA (Kubernetes Event-Driven Autoscaling) does not replace HPA --- it **extends** it. KEDA solves two problems that HPA cannot:

1. **Zero-to-one scaling.** HPA's `minReplicas` must be at least 1. KEDA can scale a deployment to zero and activate it when an event arrives.

2. **Diverse event sources.** KEDA ships with 60+ scalers: Kafka consumer lag, AWS SQS queue depth, Azure Service Bus, Redis streams, Cron schedules, PostgreSQL query results, and more. Adding a new metric source requires no adapter installation --- just a `ScaledObject` manifest.

### KEDA Architecture

KEDA installs two components:

- **Operator (keda-operator):** Watches `ScaledObject` and `ScaledJob` CRDs. When scaling from 0 to 1, KEDA directly modifies the deployment's replica count. For scaling from 1 to N, KEDA creates and manages an HPA resource, feeding it metrics through the second component.

- **Metrics Adapter (keda-operator-metrics-apiserver):** Implements the external metrics API (`external.metrics.k8s.io`). The HPA that KEDA creates targets metrics served by this adapter.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: order-processor
spec:
  scaleTargetRef:
    name: order-processor
  minReplicaCount: 0       # Scale to zero when idle
  maxReplicaCount: 100
  triggers:
    - type: kafka
      metadata:
        bootstrapServers: kafka:9092
        consumerGroup: orders
        topic: incoming-orders
        lagThreshold: "50"
```

When the Kafka consumer lag for the `orders` group exceeds 50, KEDA activates the deployment (0 to 1), then the HPA scales from 1 to N based on how far the lag exceeds the threshold.

## HPAv2 Behavior Tuning

The autoscaling/v2 API introduced the `behavior` field, which provides fine-grained control over how fast the HPA scales up and down. Without tuning, the HPA can oscillate: a traffic spike causes rapid scale-up, load drops as new pods absorb traffic, the HPA immediately scales down, load spikes again.

```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300      # Wait 5 minutes before scaling down
    policies:
      - type: Percent
        value: 10
        periodSeconds: 60               # Remove at most 10% of pods per minute
      - type: Pods
        value: 2
        periodSeconds: 60               # Or at most 2 pods per minute
    selectPolicy: Min                    # Use whichever policy removes FEWER pods
  scaleUp:
    stabilizationWindowSeconds: 0        # Scale up immediately
    policies:
      - type: Percent
        value: 100
        periodSeconds: 15               # Double pod count every 15 seconds
      - type: Pods
        value: 4
        periodSeconds: 15               # Or add 4 pods every 15 seconds
    selectPolicy: Max                    # Use whichever policy adds MORE pods
```

### Key Concepts

- **stabilizationWindowSeconds:** The HPA looks at the desired replica count over this time window and picks the highest (for scale-down) or lowest (for scale-up). A 300-second stabilization window for scale-down means the HPA will not reduce replicas until the desired count has been lower for at least 5 minutes. This prevents premature scale-down after a traffic burst.

- **Policies (Percent vs Pods):** Each policy defines a maximum change rate. `Percent: 10` means remove at most 10% of current replicas. `Pods: 2` means remove at most 2 pods. You can combine multiple policies.

- **selectPolicy:** When multiple policies exist, `Min` picks the one that changes the least (conservative), `Max` picks the one that changes the most (aggressive), and `Disabled` prevents scaling in that direction entirely.

**General wisdom:** Scale up aggressively (fast `selectPolicy: Max`), scale down conservatively (slow `selectPolicy: Min` with a stabilization window). It is always cheaper to run a few extra pods for a few minutes than to drop requests during a scale-up delay.

## Common Pitfalls

**Metrics lag.** The metrics pipeline introduces latency. cAdvisor scrapes every 10--15 seconds. Metrics Server aggregates. The HPA polls every 15 seconds. End-to-end, there can be 30--60 seconds between a load spike and the HPA deciding to scale. For latency-sensitive services, consider scaling on leading indicators (queue depth, connection count) rather than lagging indicators (CPU).

**Thrashing.** Without behavior tuning, the HPA can oscillate between two replica counts every loop iteration. The stabilization window and policy limits exist to prevent this. If you see `ScalingActive` events alternating between scale-up and scale-down, increase the stabilization window.

**Cold start.** New pods take time to start (image pull, init containers, JVM warmup, cache loading). The HPA sees new pods as "not yet reporting metrics" and may scale up further before the first wave is ready. Use readiness probes with appropriate initial delays and consider `scaleUp.stabilizationWindowSeconds` to give new pods time to absorb load.

**Missing resource requests.** If pods lack `resources.requests.cpu`, the HPA cannot compute utilization percentages and will emit `FailedGetResourceMetric` events. Always set resource requests on pods that will be autoscaled.

**Scaling both on CPU and a custom metric.** When multiple metrics are specified, the HPA computes the desired replica count for each and takes the **maximum**. This is usually correct (scale up if either metric is hot), but can lead to over-provisioning if metrics are poorly correlated.

## Putting It Together

A production-ready HPA configuration typically combines:

1. A primary business metric (requests per second, queue depth)
2. A safety-net CPU metric (catches runaway computation)
3. Conservative scale-down behavior (stabilization window of 5--10 minutes)
4. Aggressive scale-up behavior (double capacity every 15--30 seconds)
5. Reasonable min/max bounds (min = 2 for HA, max = cost limit)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: checkout-service
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: checkout-service
  minReplicas: 3
  maxReplicas: 40
  metrics:
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "500"
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 600
      policies:
        - type: Percent
          value: 10
          periodSeconds: 60
      selectPolicy: Min
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 15
        - type: Pods
          value: 5
          periodSeconds: 15
      selectPolicy: Max
```

## Common Mistakes and Misconceptions

- **"HPA reacts instantly to traffic spikes."** HPA checks metrics every 15 seconds (default), then applies stabilization windows and cooldown periods. End-to-end reaction time is typically 1-2 minutes. For faster response, use KEDA or custom metrics with shorter intervals.
- **"I can use HPA and VPA together on CPU."** HPA and VPA both try to act on CPU metrics, creating a conflict. Use HPA for horizontal scaling on CPU/memory and VPA only for non-HPA-targeted resources, or use the VPA recommendation-only mode alongside HPA.
- **"Setting target CPU utilization to 50% wastes resources."** 50% target means HPA scales up when average utilization exceeds 50%. This headroom absorbs traffic spikes during the scaling delay. Setting it to 90% means pods are overloaded before new ones arrive.
- **"HPA works without resource requests."** HPA computes utilization as a percentage of requests. Without requests, the utilization percentage is undefined, and CPU/memory-based HPA cannot function.

## Further Reading

- [HPA Algorithm Details](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#algorithm-details) --- Official algorithm documentation
- [KEDA Documentation](https://keda.sh/docs/) --- Event-driven autoscaling
- [Prometheus Adapter](https://github.com/kubernetes-sigs/prometheus-adapter) --- Custom metrics bridge
- [HPAv2 Behavior](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/#configurable-scaling-behavior) --- Scaling policies reference

---

*Next: [Vertical Pod Autoscaler](31-vpa.md) --- Right-sizing pod resource requests with VPA, in-place resize, and Goldilocks.*

# Chapter 31: Vertical Pod Autoscaler and Right-Sizing

The Vertical Pod Autoscaler (VPA) adjusts pod resource requests and limits rather than replica count --- a harder problem because changing resources historically required restarting the pod. This constraint shaped VPA's design from the beginning, and in-place pod resize --- alpha since Kubernetes 1.27 and beta since 1.33 --- is expected to reach general availability around Kubernetes 1.35, after more than six years of development. (GA timing and feature details may change; check the KEP-1287 tracking issue for current status.)

Understanding VPA requires understanding why right-sizing matters, how VPA's three modes work, the new in-place resize mechanism, the critical interaction between VPA and HPA, and the practical workflow for using VPA in production.

## Why Right-Sizing Matters

Most teams set resource requests once during initial deployment and never revisit them. Studies of large Kubernetes clusters consistently show that only 10--15% of requested CPU is actually consumed. The remaining 85--90% is reserved but idle --- the scheduler cannot assign it to other workloads because it is "spoken for."

This waste compounds:

- **Overprovisioned pods** reserve resources they never use. The scheduler treats requests as firm commitments, so idle reservations block other pods from being scheduled.
- **Underprovisioned pods** hit CPU throttling and memory OOM kills. Teams respond by doubling requests, creating more waste.
- **Node scaling follows requests, not usage.** The Cluster Autoscaler adds nodes when pods cannot be scheduled, which depends on requested resources. Bloated requests cause premature node scaling.

VPA closes this loop by observing actual usage over time and recommending (or applying) appropriate resource requests.

## VPA Architecture

VPA consists of three components:

```
VPA RECOMMENDATION FLOW
────────────────────────

  ┌─────────────────────────────────────────────────────┐
  │                 VPA Components                       │
  │                                                      │
  │  ┌──────────────┐   ┌──────────────┐   ┌──────────┐│
  │  │  Recommender  │   │   Updater    │   │ Admission ││
  │  │              │   │              │   │ Webhook   ││
  │  │ Watches pod  │   │ Evicts pods  │   │ Mutates   ││
  │  │ metrics over │   │ that are     │   │ pod spec  ││
  │  │ time, builds │   │ outside the  │   │ at        ││
  │  │ histogram of │   │ recommended  │   │ creation  ││
  │  │ usage, emits │   │ range        │   │ time      ││
  │  │ target,      │   │              │   │           ││
  │  │ lowerBound,  │   │ (only in     │   │ (applies  ││
  │  │ upperBound   │   │  Auto mode)  │   │  recs to  ││
  │  └──────┬───────┘   └──────┬───────┘   │  new pods)││
  │         │                  │           └─────┬────┘│
  └─────────┼──────────────────┼─────────────────┼─────┘
            │                  │                 │
            ▼                  ▼                 ▼
  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
  │  Metrics     │   │ Running Pods │   │ API Server   │
  │  Server /    │   │ (evict +     │   │ (pod create  │
  │  Prometheus  │   │  recreate)   │   │  admission)  │
  └──────────────┘   └──────────────┘   └──────────────┘
```

1. **Recommender:** Continuously observes pod resource usage (via Metrics API or Prometheus) and computes recommendations. It maintains a decaying histogram of usage patterns and outputs four values per container: `lowerBound`, `target`, `uncappedTarget`, and `upperBound`.

2. **Updater:** In Auto mode, compares running pods' resource requests against the recommended range. If a pod's requests fall outside the `[lowerBound, upperBound]` range, the Updater evicts it so it can be recreated with updated requests.

3. **Admission Webhook:** Intercepts pod creation requests and mutates the resource requests to match the VPA's current recommendation. This is how the updated values actually get applied --- the Updater evicts the old pod, the Deployment creates a replacement, and the Admission Webhook sets the recommended requests on the new pod.

## The Three Modes (Plus One)

VPA operates in one of four modes, set via `updatePolicy.updateMode`:

### Off (Recommendation Only)

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: api-server-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-server
  updatePolicy:
    updateMode: "Off"
```

The Recommender computes and stores recommendations, but neither the Updater nor the Admission Webhook applies them. You read recommendations from the VPA status and decide manually whether to act. This is the safest starting point.

```bash
kubectl get vpa api-server-vpa -o jsonpath='{.status.recommendation}' | jq .
```

### Initial

The Admission Webhook applies recommendations to **new** pods at creation time, but the Updater does not evict running pods. Existing pods keep their current requests until they are restarted for other reasons (deployment rollout, node drain, crash). This is useful for gradual rollouts --- new pods get right-sized, old pods are unaffected.

### Auto (Recreate)

Both the Updater and Admission Webhook are active. The Updater will evict pods whose requests are outside the recommended range, causing them to be recreated with new requests. This provides fully automated right-sizing but causes pod restarts, which can be disruptive for stateful workloads or services with long startup times.

### InPlaceOrRecreate (New)

With in-place pod resize approaching GA, VPA is gaining a fourth mode (the name `InPlaceOrRecreate` is used here but may differ in the final implementation --- check the VPA documentation for your version). In this mode, VPA first attempts to resize the pod in place --- updating its resource requests without restarting it. If in-place resize is not possible (for example, the new requests exceed node capacity), VPA falls back to the Recreate behavior and evicts the pod.

This is the mode most teams should target once their clusters support in-place resize at GA.

## In-Place Pod Resize

In-place pod resize was proposed in KEP-1287 and has been in development for over six years (alpha in 1.27, beta in 1.33). The core challenge was that Kubernetes originally treated a pod's resource requests as immutable --- changing them required deleting and recreating the pod.

With in-place resize, you can patch a running pod's `spec.containers[*].resources.requests` and `spec.containers[*].resources.limits`, and the kubelet will apply the change to the running container's cgroup without restarting it. The pod's `status.resize` field reports whether the resize was accepted (`InProgress`, `Proposed`, `Deferred`, `Infeasible`).

For CPU, this is straightforward --- the kubelet adjusts the CFS quota. For memory, it is more complex. Increasing memory limits is safe (just raise the cgroup limit). Decreasing memory limits can only succeed if the container's current resident memory is below the new limit.

## VPA and HPA Interaction

**Never use VPA and HPA on the same metric for the same workload.** This is the most critical rule. If both VPA and HPA target CPU:

1. Load increases. CPU utilization rises.
2. HPA wants to add more pods.
3. VPA wants to increase per-pod CPU requests.
4. VPA increases requests. Utilization (relative to new, higher request) drops.
5. HPA sees lower utilization and scales down.
6. Fewer pods mean higher per-pod load. Cycle repeats.

The result is oscillation and instability.

**Safe combinations:**

- HPA scales on a custom metric (requests per second, queue depth). VPA manages CPU and memory requests. They operate on orthogonal signals.
- HPA scales on CPU. VPA is in `Off` mode (recommendation only), and a human periodically adjusts requests based on VPA's suggestions.
- Use Multidimensional Pod Autoscaler (MPA) from Google, which coordinates horizontal and vertical scaling decisions in a single controller.

## The Right-Sizing Workflow

For production workloads, the recommended approach is deliberate and manual:

**Step 1: Deploy VPA in Off mode.** Attach a VPA with `updateMode: "Off"` to your deployment. Let it observe for at least 7 days to capture weekly traffic patterns.

**Step 2: Collect recommendations.** Read the VPA status. The `target` field is what VPA would set. The `lowerBound` and `upperBound` define the acceptable range.

**Step 3: Analyze.** Compare VPA's target against current requests. If the target is significantly lower, your pods are overprovisioned. If higher, they are underprovisioned. Cross-reference with actual OOM kills and CPU throttling events.

**Step 4: Set manual requests.** Update your deployment manifests with the recommended values. Use the `target` as the request and `upperBound` as the limit (or no limit for CPU --- see Chapter 33). Deploy via your normal rollout process.

**Step 5: Repeat.** Traffic patterns change. Revisit VPA recommendations quarterly.

## Goldilocks: Automated Recommendations at Scale

Running `kubectl get vpa` across hundreds of deployments is tedious. **Goldilocks** (by Fairwinds) automates VPA recommendation collection and presents it as a dashboard.

Goldilocks creates a VPA in `Off` mode for every deployment in labeled namespaces, then serves a web UI showing current requests versus VPA recommendations for every container. It provides both "guaranteed" (VPA upper bound) and "burstable" (VPA target) suggestions.

```bash
# Label namespaces for Goldilocks
kubectl label namespace production goldilocks.fairwinds.com/enabled=true

# Goldilocks creates VPAs automatically and serves a dashboard
```

This is the fastest path to answering "how much are we wasting across the entire cluster?" without changing any workload behavior.

## Resource Policy: Constraining VPA

You can constrain VPA's recommendations with a resource policy to prevent it from setting values too low (risking OOM kills) or too high (wasting resources):

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: api-server-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-server
  updatePolicy:
    updateMode: "Auto"
  resourcePolicy:
    containerPolicies:
      - containerName: api-server
        minAllowed:
          cpu: 100m
          memory: 128Mi
        maxAllowed:
          cpu: 4
          memory: 8Gi
        controlledResources: ["cpu", "memory"]
      - containerName: sidecar
        mode: "Off"          # Don't touch the sidecar
```

The `mode: "Off"` per container is particularly useful for sidecars (Istio proxies, log collectors) that should retain their manually tuned requests.

## Common Mistakes and Misconceptions

- **"VPA automatically right-sizes my pods."** In `updateMode: Auto`, VPA evicts and recreates pods with new resources, causing restarts. Use `Off` mode to get recommendations without disruption, then apply them during planned maintenance.
- **"VPA recommendations are immediately correct."** VPA needs days to weeks of historical data to produce good recommendations. Initial recommendations based on hours of data are often wrong. Let it observe through at least one full traffic cycle.
- **"I should apply VPA to every workload."** VPA's pod-restart behavior makes it unsuitable for workloads that can't tolerate restarts (single-replica databases, leader-election services). Use it for stateless services with multiple replicas.

## Further Reading

- [VPA Documentation](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler) --- Official VPA repository
- [KEP-1287: In-Place Pod Resize](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/1287-in-place-update-pod-resources) --- The six-year journey to in-place resize
- [Goldilocks](https://github.com/FairwindsOps/goldilocks) --- VPA recommendation dashboard
- [Multidimensional Pod Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/multidimensional-pod-autoscaler) --- Coordinated horizontal + vertical scaling

---

*Next: [Node Scaling](32-node-scaling.md) --- Cluster Autoscaler, Karpenter, and the architecture of node-level scaling.*

# Chapter 2: The Problems Kubernetes Solves

Kubernetes exists because running containerized applications at scale presents a set of interrelated problems that no individual tool solves. Understanding these problems is essential to understanding why Kubernetes is designed the way it is.

## The Bin Packing Problem

At its most fundamental, Kubernetes solves a **resource allocation problem**. You have N machines, each with some amount of CPU, memory, and other resources. You have M workloads, each requiring some amount of those resources. How do you assign workloads to machines to maximize utilization while respecting constraints?

This is a variant of the NP-hard bin packing problem. In the general case, finding the optimal solution is computationally intractable. But good heuristics exist, and Kubernetes' scheduler implements several of them. The key insight is that **centralized, automated scheduling dramatically outperforms human scheduling**. When humans decide where to place workloads, they tend to be conservative (over-provisioning resources to avoid contention), forgetful (leaving old workloads running on machines long after they should have been decommissioned), and inconsistent (different operators making different decisions for similar workloads).

Borg's experience demonstrated that automated bin packing could improve cluster utilization from the 5-15% typical of manually managed environments to 60-70%. Even modest improvements in utilization translate to enormous cost savings at scale: Google's fleet comprises millions of machines, so a 1% improvement in utilization saves tens of thousands of servers.

## The Service Discovery Problem

In a static world, you can configure your web frontend to talk to your database at a known IP address and port. But in a dynamic, containerized world, nothing has a stable address. Containers are created and destroyed constantly. They are moved between machines when hosts fail or when the scheduler finds a more efficient placement. The set of containers backing a particular service changes every time a deployment rolls out.

This creates the **service discovery problem**: how does one service find and communicate with another in an environment where addresses are constantly changing? There are several classic approaches:

- **DNS-based discovery**: Register service instances in DNS, and clients look up the DNS name. Simple, but DNS has caching and TTL issues that make it slow to reflect changes.
- **Client-side registries**: Services register themselves with a central registry (like ZooKeeper or Consul), and clients query the registry. Flexible, but requires every service to include registry client code.
- **Load balancer-based discovery**: A load balancer sits in front of service instances, and clients talk to the load balancer's stable address. Simple for clients, but adds latency and a single point of failure.

Kubernetes provides service discovery as a first-class primitive through its Service abstraction. A Service has a stable IP address (the ClusterIP) and DNS name. The Kubernetes control plane automatically updates the set of endpoints (pod IP addresses) behind a Service as pods come and go. This is implemented transparently by kube-proxy (or the CNI plugin), which programs iptables/IPVS rules on every node to redirect traffic addressed to a Service's ClusterIP to one of its backing pods.

## The Rolling Deployment Problem

Updating a running application without downtime is one of the hardest problems in operations. The naive approach --- stop all old instances, start all new instances --- causes downtime proportional to the startup time of the new instances. In a microservices architecture with hundreds of services, even brief downtime cascades into widespread failures.

The **rolling deployment** strategy addresses this by incrementally replacing old instances with new ones: start one new instance, wait for it to become healthy, then stop one old instance, and repeat. This maintains capacity throughout the update. But implementing rolling deployments correctly requires solving several sub-problems:

- **Health checking**: How do you know when a new instance is ready to serve traffic? Kubernetes provides readiness probes and liveness probes.
- **Traffic draining**: How do you gracefully stop sending traffic to an instance before terminating it? Kubernetes provides graceful shutdown periods and endpoint management.
- **Rollback**: If the new version is broken, how do you quickly revert? Kubernetes maintains revision history and supports automatic rollback on failure.
- **Surge and unavailability budgets**: How many extra instances can you run during the update (surge), and how many instances can be unavailable at once? Kubernetes' Deployment controller supports configurable maxSurge and maxUnavailable parameters.

## The Self-Healing Problem

In any sufficiently large system, failures are not exceptions --- they are the normal operating condition. Machines crash, networks partition, disks fill up, processes crash, memory leaks accumulate. Google's published data suggests that in a cluster of 10,000 machines, several will fail every day.

The **self-healing problem** is: how do you build a system that automatically detects and recovers from failures without human intervention? Kubernetes addresses this at multiple levels:

- **Container restart**: If a container process crashes, the kubelet automatically restarts it, with exponential backoff to avoid restart storms.
- **Pod health monitoring**: Liveness probes detect when a container is running but unhealthy (e.g., deadlocked). Kubernetes kills and restarts unhealthy containers.
- **Node failure detection**: The control plane detects when a node stops reporting (via the node controller watching heartbeats) and automatically reschedules its pods onto healthy nodes.
- **Replica maintenance**: If a Deployment specifies 3 replicas and one pod dies, the Deployment controller automatically creates a replacement.

The key insight is that self-healing requires a **control loop**: continuously compare the actual state of the system to the desired state, and take action to reconcile any differences. This is the **reconciliation loop**, and it is the central architectural pattern of Kubernetes.

## The Desired State Model vs. Imperative Commands

Perhaps the most important conceptual contribution of Kubernetes is its commitment to the **desired state (declarative) model** over the **imperative model**.

In an imperative model, you issue commands: "start 3 instances of nginx," "stop instance X," "scale up to 5 instances." The system executes each command as a one-shot action. If the command fails, or if the system state drifts after the command succeeds, the system does not automatically correct itself. The operator must detect the drift and issue corrective commands.

In a declarative model, you declare the desired state: "there should be 3 instances of nginx running." The system continuously works to make reality match this declaration. If an instance crashes, the system automatically creates a replacement. If an extra instance somehow appears, the system terminates it. If the declaration changes to "5 instances," the system creates 2 more.

The declarative model is fundamentally more robust because:

1. **It is self-correcting.** The system continuously reconciles actual state toward desired state, handling failures automatically.
2. **It is idempotent.** Applying the same desired state declaration multiple times has the same effect as applying it once.
3. **It separates intent from execution.** The user says *what* they want; the system decides *how* to achieve it.
4. **It enables auditability.** The desired state is a document (YAML or JSON) that can be version-controlled, reviewed, and diffed.
5. **It enables composition.** Multiple controllers can independently reconcile different aspects of the desired state, each responsible for a single concern.

This is not merely a philosophical preference. The imperative model breaks down catastrophically in distributed systems where commands can be lost, duplicated, or reordered. The declarative model, by contrast, is **eventually consistent by design**: no matter what transient failures occur, the system will eventually converge to the desired state.

### Imperative vs. Declarative: A Comparison

| Dimension | Imperative Model | Declarative (Kubernetes) Model |
|-----------|-----------------|-------------------------------|
| User action | Issue commands: "start X", "stop Y" | Declare desired state: "there should be 3 of X" |
| Failure recovery | Manual: operator detects drift and issues corrections | Automatic: reconciliation loop continuously corrects drift |
| Idempotency | Commands may not be safe to replay | Applying same state is always safe to repeat |
| State visibility | State is the cumulative effect of past commands | State is a document that can be inspected, diffed, versioned |
| Scalability | Requires operator attention proportional to scale | Controller workload scales, but operator intent stays constant |
| Composition | Commands must be carefully ordered | Controllers reconcile independently and concurrently |

---

Next: [Architecture from First Principles](03-architecture.md)

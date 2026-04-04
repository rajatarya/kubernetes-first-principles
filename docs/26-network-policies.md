# Chapter 26: Network Policies

By default, every pod in a Kubernetes cluster can talk to every other pod. There are no firewalls, no access control lists, no segmentation. A pod in the `accounting` namespace can reach a pod in `production` without restriction. A compromised pod can scan the entire cluster network, connect to databases, and exfiltrate data to the internet. This is the networking equivalent of giving every employee a master key to every room in the building.

Network Policies are Kubernetes's mechanism for controlling traffic between pods. They are the cluster's internal firewall, and understanding them from first principles requires understanding three things: the default-open model they override, the additive-only logic they use, and the CNI dependency that determines whether they actually work.

## The Fundamental Model

Kubernetes Network Policies operate on three principles:

1. **Non-isolated by default.** A pod with no Network Policy selecting it accepts all inbound and all outbound traffic. Network Policies are opt-in.

2. **Additive allow-only.** There are no "deny" rules. Policies can only allow traffic. If you create a policy that selects a pod, that pod becomes **isolated** for the direction(s) specified (ingress, egress, or both). Once isolated, only traffic explicitly allowed by a policy is permitted.

3. **Both sides must allow.** For traffic to flow from pod A to pod B, the **egress** policy on pod A must allow traffic to B, AND the **ingress** policy on pod B must allow traffic from A. If either side denies (by isolation without a matching allow), the traffic is dropped.

```
NETWORK POLICY TRAFFIC FLOW
─────────────────────────────

  Pod A (team-alpha)              Pod B (team-beta)
  ┌───────────────────┐           ┌───────────────────┐
  │                   │           │                   │
  │  Egress Policy:   │           │  Ingress Policy:  │
  │  "allow to        │──────────▶│  "allow from      │
  │   team-beta pods" │  Traffic  │   team-alpha pods" │
  │                   │  flows    │                   │
  └───────────────────┘  only if  └───────────────────┘
                         BOTH
                         allow

  If Pod A has no egress policy → Pod A is non-isolated
    for egress → all egress allowed (A's side: OK)
  If Pod B has no ingress policy → Pod B is non-isolated
    for ingress → all ingress allowed (B's side: OK)
  If Pod A has egress policy that does NOT list Pod B
    → traffic BLOCKED at A's side
```

## The Essential Policy Templates

### Default Deny All Ingress

The most important policy in any cluster. Apply this to every namespace and then add specific allow rules.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: production
spec:
  podSelector: {}          # Empty selector = all pods in namespace
  policyTypes:
    - Ingress              # Isolate for ingress; no ingress rules = deny all
  # No ingress rules → all inbound traffic denied
```

### Default Deny All Egress

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Egress
  # No egress rules → all outbound traffic denied
```

**Warning:** Denying all egress breaks DNS resolution. Pods will not be able to resolve service names. You almost always need to pair this with a DNS allow rule (see below).

### Default Deny Both Directions

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

### Allow DNS Egress (Critical)

DNS is the number one cause of Network Policy failures. When you deny egress, pods cannot resolve service names, and every application breaks in confusing ways --- timeouts rather than connection refused, because DNS queries silently disappear.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

### Namespace Isolation

Allow traffic only from pods within the same namespace:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}    # All pods in THIS namespace
```

### Specific Pod-to-Pod Communication

Allow only the frontend to reach the backend, and only the backend to reach the database:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-ingress
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - protocol: TCP
          port: 8080
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: database-ingress
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: database
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: backend
      ports:
        - protocol: TCP
          port: 5432
```

### Egress to External IPs

Allow pods to reach a specific external service (e.g., a third-party API):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-api
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: payment-service
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 203.0.113.0/24     # External API range
      ports:
        - protocol: TCP
          port: 443
```

## The AND vs OR Selector Trap

This is the single most common source of Network Policy bugs. The behavior changes depending on whether selectors appear in the **same `from`/`to` item** or in **separate list items**.

```
THE SELECTOR LOGIC TRAP
─────────────────────────

  COMBINED (AND logic) --- both conditions must match:

  ingress:
    - from:
        - namespaceSelector:        ┐
            matchLabels:            │  AND
              env: production       │
          podSelector:              │  Both must be true:
            matchLabels:            │  namespace=production
              app: frontend         ┘  AND app=frontend

  SEPARATE (OR logic) --- either condition can match:

  ingress:
    - from:
        - namespaceSelector:        ← OR: any pod in namespace
            matchLabels:               with env=production
              env: production
        - podSelector:              ← OR: any pod in SAME namespace
            matchLabels:               with app=frontend
              app: frontend

  THE DIFFERENCE:
  Combined: Only frontend pods in production namespaces
  Separate: ALL pods in production namespaces
            OR frontend pods in the CURRENT namespace
```

The difference is a single `-` character (a new list item). Combined selectors are intersections (AND). Separate selectors are unions (OR). Getting this wrong can open your namespace to traffic from every pod in a production-labeled namespace.

## CNI Support: The Enforcement Gap

Network Policies are a Kubernetes API object. Any cluster accepts them. But **enforcing** them requires a CNI plugin that implements the NetworkPolicy specification. If your CNI does not support Network Policies, the policy objects exist in etcd but have zero effect on traffic. This is a silent failure --- no warning, no error, no indication that your security rules are not being enforced.

| CNI Plugin | Network Policy Support | Notes |
|------------|----------------------|-------|
| **Calico** | Full | The most widely deployed policy-capable CNI. Supports both Kubernetes NetworkPolicy and its own more expressive CRDs (GlobalNetworkPolicy, deny rules, application-layer policies). |
| **Cilium** | Full + extended | eBPF-based. Supports Kubernetes NetworkPolicy plus CiliumNetworkPolicy with L7 (HTTP, gRPC, Kafka) filtering, DNS-aware policies, and identity-based enforcement. |
| **Weave Net** | Full | Supports standard NetworkPolicy. Less common in new deployments. |
| **Antrea** | Full | VMware-backed, built on Open vSwitch. Good support for NetworkPolicy and its own Antrea-native policies. |
| **Flannel** | None | Flannel provides connectivity only. If you apply a NetworkPolicy on a Flannel cluster, it is silently ignored. This is the most common enforcement gap in production. |
| **kubenet** | None | Basic CNI for simple clusters. No policy support. |

**How to verify enforcement:** Deploy two pods. Apply a deny-all ingress policy to the target pod's namespace. Attempt to connect from the source pod. If the connection succeeds, your CNI is not enforcing policies.

```bash
# Quick verification test
kubectl run source --image=busybox --rm -it --restart=Never -- \
  wget -qO- --timeout=3 http://target-pod-ip:8080
# If this succeeds after a deny-all policy, your CNI does not enforce policies
```

## A Complete Namespace Policy Set

A production namespace typically needs a layered set of policies. Here is a complete example for a three-tier application:

```
POLICY LAYERING FOR A NAMESPACE
─────────────────────────────────

  production namespace
  ┌──────────────────────────────────────────────────┐
  │                                                    │
  │  Policy 1: default-deny-all (ingress + egress)    │
  │  Policy 2: allow-dns (egress to kube-dns)         │
  │                                                    │
  │  ┌──────────┐    ┌──────────┐    ┌──────────┐    │
  │  │ frontend │───▶│ backend  │───▶│ database │    │
  │  │          │    │          │    │          │    │
  │  └──────────┘    └──────────┘    └──────────┘    │
  │       ▲                │              │           │
  │       │                ▼              │           │
  │  Policy 3:        Policy 5:      Policy 7:       │
  │  allow ingress    allow egress   deny all        │
  │  from ingress     to database    egress (no      │
  │  controller       on 5432        external)        │
  │                                                    │
  │  Policy 4:        Policy 6:                       │
  │  allow egress     allow ingress                   │
  │  to backend       from backend                    │
  │  on 8080          on 5432                         │
  │                                                    │
  └──────────────────────────────────────────────────┘

  External traffic → ingress controller → frontend → backend → database
  Every other path is blocked.
```

## Debugging Network Policies

When traffic is unexpectedly blocked:

1. **Check that policies exist:** `kubectl get networkpolicy -n <namespace>`
2. **Verify CNI enforcement:** Test with a known-blocked connection
3. **Inspect the policy:** `kubectl describe networkpolicy <name> -n <namespace>`
4. **Check labels:** Policies select pods by label. A missing or misspelled label means the policy does not apply to the pod you think it does. `kubectl get pods --show-labels -n <namespace>`
5. **Check DNS:** If pods can connect by IP but not by name, the egress DNS rule is missing or incorrect
6. **Remember the AND/OR trap:** Review your `from`/`to` selectors for unintended union logic

## Limitations of Kubernetes Network Policies

The standard NetworkPolicy API has real limitations:

- **No deny rules.** You cannot explicitly block a specific source. You can only fail to allow it.
- **No logging.** There is no built-in way to log dropped packets.
- **No cluster-wide policies.** Each NetworkPolicy is namespaced. There is no way to apply a policy across all namespaces without creating it in each one.
- **No L7 filtering.** Standard policies operate at L3/L4 (IP and port). They cannot distinguish between `GET /api/public` and `DELETE /api/admin`.

For these capabilities, use your CNI's extended policy CRDs. Calico's GlobalNetworkPolicy and Cilium's CiliumNetworkPolicy both address these gaps.

## Common Mistakes and Misconceptions

- **"Pods are isolated by default."** The opposite: all pods can reach all other pods by default. You must explicitly create NetworkPolicies to restrict traffic. No policy = fully open.
- **"A NetworkPolicy on ingress also blocks egress."** Ingress and egress are independent. A policy selecting only ingress rules does not restrict outbound traffic. You need separate egress rules.
- **"My CNI supports NetworkPolicy."** Not all CNIs do. Flannel does not enforce NetworkPolicies. You need Calico, Cilium, or another policy-aware CNI. Apply a policy and test it — don't assume.
- **"NetworkPolicies work across namespaces automatically."** You must use `namespaceSelector` to allow cross-namespace traffic. A policy only applies to pods in its own namespace.

## Further Reading

- [Network Policies documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/) --- Official reference
- [Network Policy recipes](https://github.com/ahmetb/kubernetes-network-policy-recipes) --- Practical examples
- [Calico Network Policy](https://docs.tigera.io/calico/latest/network-policy/) --- Extended policy features
- [Cilium Network Policy](https://docs.cilium.io/en/stable/network/kubernetes/policy/) --- L7-aware policies
- [Network Policy Editor](https://editor.networkpolicy.io/) --- Visual editor for building and understanding NetworkPolicies

---

*Next: [Supply Chain Security](27-supply-chain.md) --- Image signing, admission policies, SBOMs, and the SLSA framework.*

# Chapter 37: Multi-Tenancy

A Kubernetes cluster is expensive. Running one cluster per team, per environment, or per application multiplies that cost --- not just in compute, but in operational overhead: patching, monitoring, upgrading, and securing each cluster independently. Multi-tenancy is the practice of sharing a single cluster among multiple tenants (teams, applications, customers) while maintaining isolation between them.

The fundamental tension in multi-tenancy is between sharing (for efficiency) and isolation (for safety). Too much sharing and one tenant's misconfiguration affects others. Too much isolation and you lose the efficiency gains that motivated sharing in the first place. Kubernetes provides multiple isolation mechanisms at different strengths, and choosing the right combination depends on your trust model: are tenants friendly teams within the same organization, or are they untrusted customers running arbitrary code?

## Namespace-Level Isolation

The namespace is Kubernetes's primary unit of multi-tenancy. A namespace provides a scope for names and a target for access control, network policies, and resource quotas. For trusted, internal tenants, namespace isolation is often sufficient.

### The Four Pillars

Effective namespace isolation requires four mechanisms working together:

**1. RBAC (who can do what).** Each tenant gets a Role and RoleBinding scoped to their namespace. Tenants can create Deployments, Services, and ConfigMaps in their namespace but cannot access other namespaces or cluster-scoped resources.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-developer
  namespace: team-alpha
rules:
  - apiGroups: ["", "apps", "batch"]
    resources: ["pods", "deployments", "services", "configmaps", "jobs"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]    # Read but not create --- secrets managed by platform
```

**2. NetworkPolicies (who can talk to whom).** Default-deny ingress and egress policies per namespace, with explicit allow rules for legitimate cross-namespace traffic. Without NetworkPolicies, pods in `team-alpha` can freely reach pods in `team-beta`.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: team-alpha
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  egress:
    - to: []                          # DNS only (add DNS allow separately)
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

**3. ResourceQuotas (how much can be consumed).** Without quotas, one tenant can consume all cluster resources, starving others. ResourceQuotas set hard limits per namespace.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-quota
  namespace: team-alpha
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi
    pods: "50"
    services: "10"
    persistentvolumeclaims: "20"
```

**4. LimitRanges (sane defaults).** LimitRanges set default requests and limits for containers that do not specify them, and enforce minimum/maximum bounds. This prevents a developer from deploying a pod with `requests.memory: 1Ti`.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: tenant-limits
  namespace: team-alpha
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 256Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "4"
        memory: 8Gi
      min:
        cpu: 50m
        memory: 64Mi
```

```
NAMESPACE ISOLATION MODEL
──────────────────────────

  ┌─────────────────────────────────────────────────┐
  │                 Shared Cluster                   │
  │                                                  │
  │  ┌──────────────────┐  ┌──────────────────┐     │
  │  │  team-alpha       │  │  team-beta        │    │
  │  │                   │  │                   │    │
  │  │  RBAC: own role   │  │  RBAC: own role   │    │
  │  │  NetworkPolicy:   │  │  NetworkPolicy:   │    │
  │  │    deny by default│  │    deny by default│    │
  │  │  ResourceQuota:   │  │  ResourceQuota:   │    │
  │  │    10 CPU, 20Gi   │  │    8 CPU, 16Gi    │    │
  │  │  LimitRange:      │  │  LimitRange:      │    │
  │  │    defaults set   │  │    defaults set   │    │
  │  │                   │  │                   │    │
  │  │  ┌─────┐ ┌─────┐ │  │  ┌─────┐ ┌─────┐ │    │
  │  │  │Pod A│ │Pod B│ │  │  │Pod C│ │Pod D│ │    │
  │  │  └─────┘ └─────┘ │  │  └─────┘ └─────┘ │    │
  │  └──────────────────┘  └──────────────────┘     │
  │                                                  │
  │  Shared: API server, scheduler, kubelet,        │
  │          etcd, container runtime, nodes          │
  └─────────────────────────────────────────────────┘
```

### Limitations of Namespace Isolation

Namespaces share the Kubernetes control plane. This means:

- **CRDs are cluster-scoped.** One tenant's CRD installation affects all tenants. A buggy CRD controller can crash the API server for everyone.
- **Cluster-scoped resources cannot be isolated.** ClusterRoles, PriorityClasses, IngressClasses, and StorageClasses are visible to all tenants.
- **Node-level resources are shared.** Tenants share the Linux kernel, container runtime, and host filesystem. A container escape vulnerability gives access to all pods on the node.
- **API server rate limits affect everyone.** One tenant's controller making excessive API calls degrades performance for all tenants.
- **No per-tenant admission control.** Admission webhooks are cluster-scoped. You cannot run different admission policies per namespace without complex webhook routing.

For internal teams with moderate trust, these limitations are acceptable. For untrusted tenants or strict compliance requirements, they are not.

## Hierarchical Namespaces (HNC)

In flat namespace models, creating a new team or sub-team requires manual namespace provisioning with duplicated RBAC, NetworkPolicies, and ResourceQuotas. **Hierarchical Namespace Controller (HNC)** adds parent-child relationships between namespaces. A child namespace automatically inherits Roles, RoleBindings, NetworkPolicies, and ResourceQuotas from its parent.

```yaml
apiVersion: hnc.x-k8s.io/v1alpha2
kind: SubnamespaceAnchor
metadata:
  name: team-alpha-staging
  namespace: team-alpha
```

This creates `team-alpha-staging` as a child of `team-alpha`. RBAC bindings from `team-alpha` propagate automatically. When the parent's policies change, children update. This is particularly useful for organizations with hierarchical team structures (org > division > team > project).

HNC does not add stronger isolation --- it makes namespace management more scalable. The isolation boundary is still the namespace with its four pillars.

## vCluster: Virtual Clusters

When namespace isolation is insufficient, the next step is **vCluster** --- a project that creates virtual Kubernetes clusters inside a host cluster. Each vCluster runs its own API server, controller manager, and (optionally) its own etcd, all as pods within a namespace of the host cluster. Tenants interact with their vCluster as if it were a standalone cluster.

```
vCLUSTER ISOLATION MODEL
──────────────────────────

  ┌──────────────────────────────────────────────────────┐
  │                    Host Cluster                       │
  │                                                       │
  │  ┌──────────────────────────┐  ┌────────────────────┐│
  │  │  Namespace: vc-alpha      │  │ Namespace: vc-beta ││
  │  │                           │  │                    ││
  │  │  ┌─────────────────────┐  │  │ ┌────────────────┐││
  │  │  │  vCluster "alpha"   │  │  │ │ vCluster "beta"│││
  │  │  │                     │  │  │ │                │││
  │  │  │  Own API server     │  │  │ │ Own API server │││
  │  │  │  Own controller-mgr │  │  │ │ Own ctrl-mgr   │││
  │  │  │  Own scheduler      │  │  │ │ Own scheduler  │││
  │  │  │  Own etcd (or SQLite│  │  │ │ Own etcd       │││
  │  │  │  for lightweight)   │  │  │ │                │││
  │  │  │                     │  │  │ │                │││
  │  │  │  Tenant sees:       │  │  │ │ Tenant sees:   │││
  │  │  │  - Own namespaces   │  │  │ │ - Own ns       │││
  │  │  │  - Own CRDs         │  │  │ │ - Own CRDs     │││
  │  │  │  - Own RBAC         │  │  │ │ - Own RBAC     │││
  │  │  │  - Own secrets      │  │  │ │ - Own secrets  │││
  │  │  └─────────┬───────────┘  │  │ └───────┬────────┘││
  │  │            │              │  │         │         ││
  │  │  ┌─────────▼───────────┐  │  │ ┌───────▼────────┐││
  │  │  │  Syncer             │  │  │ │ Syncer         │││
  │  │  │  Syncs pods to host │  │  │ │ Syncs pods     │││
  │  │  │  cluster for actual │  │  │ │ to host        │││
  │  │  │  scheduling         │  │  │ │                │││
  │  │  └─────────────────────┘  │  │ └────────────────┘││
  │  └──────────────────────────┘  └────────────────────┘│
  │                                                       │
  │  Host cluster provides: nodes, networking, storage    │
  └──────────────────────────────────────────────────────┘
```

### How vCluster Works

1. The vCluster control plane (API server, controller manager, optional etcd) runs as pods in a host namespace.
2. Tenants connect to the vCluster's API server via a kubeconfig. They see a normal Kubernetes cluster with its own namespaces, CRDs, and RBAC.
3. When a tenant creates a pod in the vCluster, the **syncer** translates it into a pod in the host namespace with a mangled name. The host cluster's scheduler places it on a real node.
4. The tenant's pod runs on host infrastructure but appears in the vCluster's API server with the tenant's labels, annotations, and namespace.

### What vCluster Provides

- **CRD isolation.** Each vCluster can install its own CRDs without affecting other tenants.
- **Cluster-admin per tenant.** Tenants can have `cluster-admin` inside their vCluster without affecting the host.
- **Independent upgrades.** Each vCluster can run a different Kubernetes version.
- **Full RBAC isolation.** ClusterRoles and ClusterRoleBindings are scoped to the vCluster.
- **Admission webhook isolation.** Tenants can install their own admission webhooks.

### What vCluster Does NOT Provide

- **Node-level isolation.** Pods from different vClusters share the same nodes and Linux kernel. Container escape is still a risk.
- **Network isolation by default.** You still need NetworkPolicies on the host cluster to isolate traffic between vClusters.
- **Zero overhead.** Each vCluster's control plane consumes resources (typically 0.5--1 CPU and 512Mi--1Gi memory for the API server and syncer).

## Comparison

| Capability | Namespaces | Namespaces + HNC | vCluster |
|---|---|---|---|
| RBAC isolation | Namespace-scoped | Inherited + namespace | Full cluster-admin |
| CRD isolation | None | None | Full |
| Network isolation | Via NetworkPolicy | Via NetworkPolicy | Via NetworkPolicy + own Services |
| Resource quotas | Per namespace | Inherited | Per vCluster namespace on host |
| Independent K8s version | No | No | Yes |
| Own admission webhooks | No | No | Yes |
| Overhead per tenant | ~0 | ~0 | 0.5--1 CPU, 512Mi--1Gi |
| Node-level isolation | No | No | No (use Kata/gVisor) |
| Suitable for | Internal teams | Hierarchical orgs | SaaS, untrusted tenants |

## When Namespaces Are Not Enough

Use namespace isolation when:
- Tenants are internal teams within the same organization
- Tenants do not need to install CRDs
- Tenants do not need cluster-admin privileges
- A shared admission policy is acceptable

Use vCluster when:
- Tenants need CRD isolation (different operators, different CRD versions)
- Tenants need cluster-admin (for CI/CD testing, development environments)
- You are building a SaaS platform where customers get their own "cluster"
- Different tenants need different Kubernetes versions
- Compliance requires demonstrable control plane isolation

Use separate physical clusters when:
- Tenants are mutually untrusted and require node-level isolation
- Compliance mandates physical separation (some PCI-DSS interpretations)
- Failure domains must be completely independent

## The Isolation Spectrum

Multi-tenancy is not binary. It is a spectrum from shared namespaces to dedicated clusters, and you can mix strategies:

- Production workloads for different teams: namespaces with strict RBAC, NetworkPolicies, and quotas
- Development and CI environments: vClusters (disposable, fast to create, cheap)
- Customer-facing SaaS tenants: vClusters with NetworkPolicies and optional gVisor for runtime isolation
- Regulated workloads: dedicated clusters with Cluster API lifecycle management

The right answer depends on your threat model, compliance requirements, and operational capacity. Start with namespaces, add vCluster when you hit a namespace limitation, and reach for dedicated clusters only when virtual isolation is insufficient.

## Further Reading

- [Multi-tenancy Guide](https://kubernetes.io/docs/concepts/security/multi-tenancy/) --- Official Kubernetes multi-tenancy documentation
- [Hierarchical Namespaces](https://github.com/kubernetes-sigs/hierarchical-namespaces) --- HNC project
- [vCluster Documentation](https://www.vcluster.com/docs) --- Virtual cluster project
- [Kata Containers](https://katacontainers.io/) --- VM-level pod isolation for node-level multi-tenancy

---

*This concludes Part 7: Multi-Cluster and Platform Engineering. You now know how to operate Kubernetes at organizational scale --- managing multiple clusters, building internal platforms, extending the API with Crossplane, and isolating tenants. Part 8 goes deeper into the machinery itself: writing your own controllers, understanding API internals, operating etcd, and running GPU and ML workloads.*

Next: [Writing Controllers and Operators](38-operators.md)

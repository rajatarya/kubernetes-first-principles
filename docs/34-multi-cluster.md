# Chapter 34: Multi-Cluster Strategies

A single Kubernetes cluster is a single failure domain. One misconfigured admission webhook can block all deployments. One etcd corruption event can lose all state. One cloud region outage can take everything offline. As organizations move from "we run some things on Kubernetes" to "Kubernetes is our platform," the question shifts from "how do we run a cluster?" to "how do we run many clusters, and how do they relate to each other?"

Multi-cluster is not about redundancy alone. Teams adopt multiple clusters for blast radius reduction, regulatory compliance, geographic latency, team isolation, and environment separation. The challenge is not running multiple clusters --- it is managing them as a coherent system without reintroducing the operational complexity Kubernetes was supposed to eliminate.

## Why Multi-Cluster

**Blast radius.** A single cluster means a single blast radius. A bad CRD upgrade, a runaway controller, or an API server overload affects every workload. Multiple clusters contain failures: if the staging cluster breaks, production continues unaffected.

**Compliance and data sovereignty.** GDPR, HIPAA, and similar regulations may require that data stays within specific geographic regions. Running a cluster per region, with workloads that process local data, is often simpler than building cross-region data controls within a single cluster.

**Latency.** A cluster in `us-east-1` cannot serve users in Tokyo with sub-50ms latency. Multi-cluster with geographic distribution puts compute close to users.

**Team isolation.** Large organizations may need hard isolation between teams --- separate API servers, separate RBAC configurations, separate upgrade schedules. Namespaces provide soft isolation; separate clusters provide hard isolation.

**Upgrade cadence.** Different workloads may need different Kubernetes versions. Running version N in production and N+1 in staging lets teams validate upgrades before rolling them out.

## Approach 1: Independent Clusters

The simplest multi-cluster strategy is no strategy at all. Each cluster is independently provisioned, independently configured, and independently managed. Teams own their clusters end-to-end.

This works for small organizations with 2--3 clusters and dedicated platform teams per cluster. It fails at scale because every cluster drifts: different versions, different policies, different monitoring configurations, different security postures.

## Approach 2: GitOps-Driven Multi-Cluster

The most widely adopted approach uses a GitOps tool to manage multiple clusters from a single source of truth. **ArgoCD ApplicationSets** are purpose-built for this.

```
GITOPS-DRIVEN MULTI-CLUSTER
─────────────────────────────

  ┌──────────────────────────────────────────────┐
  │                Git Repository                 │
  │                                               │
  │  /clusters/                                   │
  │    us-east/                                   │
  │      values.yaml   (region-specific overrides)│
  │    eu-west/                                   │
  │      values.yaml                              │
  │    ap-south/                                  │
  │      values.yaml                              │
  │  /base/                                       │
  │    deployment.yaml (shared templates)         │
  │    networkpolicy.yaml                         │
  │    monitoring.yaml                            │
  └──────────────────┬────────────────────────────┘
                     │
                     │  ArgoCD watches repo
                     │
  ┌──────────────────▼────────────────────────────┐
  │             ArgoCD (hub cluster)               │
  │                                                │
  │  ApplicationSet generator: clusters            │
  │  → For each cluster in list:                   │
  │    → Create Application targeting that cluster │
  │    → Inject cluster-specific values            │
  │    → Sync state to match Git                   │
  └────┬──────────────┬──────────────┬─────────────┘
       │              │              │
       ▼              ▼              ▼
  ┌──────────┐  ┌──────────┐  ┌──────────┐
  │ us-east  │  │ eu-west  │  │ ap-south │
  │ cluster  │  │ cluster  │  │ cluster  │
  │          │  │          │  │          │
  │ Same base│  │ Same base│  │ Same base│
  │ + region │  │ + region │  │ + region │
  │ overrides│  │ overrides│  │ overrides│
  └──────────┘  └──────────┘  └──────────┘
```

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-services
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            env: production
  template:
    metadata:
      name: "platform-{{name}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/org/platform-config
        targetRevision: main
        path: "clusters/{{metadata.labels.region}}"
      destination:
        server: "{{server}}"
        namespace: platform
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
```

The ApplicationSet generator iterates over all clusters registered in ArgoCD that match the label selector, creates one Application per cluster, and injects cluster-specific values. A single Git commit can roll out a change to every production cluster worldwide.

This approach provides strong consistency guarantees (Git is the source of truth), auditability (every change is a commit), and rollback (revert the commit). It does not, however, provide cross-cluster service discovery or traffic management.

## Approach 3: Federation

Federation projects attempt to provide a single API that spans multiple clusters. You submit a workload to the federation control plane, and it distributes replicas across member clusters.

**KubeFed (Kubernetes Federation v2)** was the original approach but is no longer actively developed. **Karmada** is the current leading project in this space. Karmada provides:

- A dedicated API server that accepts standard Kubernetes resources
- **PropagationPolicy** resources that define which clusters receive which workloads
- **OverridePolicy** resources for per-cluster customization
- Replica scheduling across clusters (weighted, by resource availability, or by policy)

```yaml
apiVersion: policy.karmada.io/v1alpha1
kind: PropagationPolicy
metadata:
  name: api-server-spread
spec:
  resourceSelectors:
    - apiVersion: apps/v1
      kind: Deployment
      name: api-server
  placement:
    clusterAffinity:
      clusterNames:
        - us-east
        - eu-west
        - ap-south
    replicaScheduling:
      replicaDivisionPreference: Weighted
      replicaSchedulingType: Divided
      weightPreference:
        staticWeightList:
          - targetCluster:
              clusterNames: [us-east]
            weight: 2
          - targetCluster:
              clusterNames: [eu-west]
            weight: 1
          - targetCluster:
              clusterNames: [ap-south]
            weight: 1
```

Federation is powerful but complex. It introduces a new control plane that must itself be highly available, and debugging failures requires understanding the federation layer, the per-cluster state, and the reconciliation between them.

## Approach 4: Service Mesh Multi-Cluster

Service meshes solve the cross-cluster networking problem: how do services in cluster A discover and call services in cluster B?

**Istio multi-cluster** supports multiple topologies: shared control plane, replicated control planes, and multi-primary. In the multi-primary model, each cluster runs its own Istio control plane, and they exchange service endpoint information so that a service in cluster A can route traffic to pods in cluster B as if they were local.

**Cilium ClusterMesh** provides a similar capability at the CNI level. Cilium agents across clusters connect via a shared etcd (or KVStoreMesh proxy) and exchange pod identity and endpoint information. Services can be declared as "global," making them accessible from any cluster in the mesh.

```yaml
# Cilium global service annotation
apiVersion: v1
kind: Service
metadata:
  name: api-server
  annotations:
    service.cilium.io/global: "true"
    service.cilium.io/shared: "true"
spec:
  ports:
    - port: 80
```

With this annotation, any pod in any cluster in the ClusterMesh can resolve `api-server` and reach backends in the originating cluster. Cilium handles endpoint synchronization, identity-aware routing, and even affinity (prefer local cluster backends).

## Approach 5: Cluster API for Lifecycle Management

All the above approaches assume clusters already exist. **Cluster API (CAPI)** addresses the lifecycle problem: how do you create, upgrade, and delete clusters declaratively?

Cluster API treats clusters as Kubernetes resources. You define a `Cluster`, `MachineDeployment`, and infrastructure-specific resources (AWS, Azure, GCP, vSphere), and Cluster API controllers reconcile them into running clusters. Upgrading a cluster's Kubernetes version is a spec change; Cluster API handles the rolling update of control plane and worker nodes.

Combining Cluster API with GitOps gives you a fully declarative multi-cluster lifecycle: Git commits create clusters, ArgoCD ApplicationSets configure them, and Cluster API manages their infrastructure.

## Choosing an Approach

| Requirement | Recommended Approach |
|---|---|
| Consistent configuration across clusters | GitOps (ArgoCD ApplicationSets) |
| Cross-cluster service discovery | Service mesh (Istio, Cilium ClusterMesh) |
| Workload distribution across clusters | Federation (Karmada) |
| Declarative cluster lifecycle | Cluster API |
| Simple, low-overhead | Independent clusters + GitOps |

Most organizations start with GitOps-driven multi-cluster and add service mesh or federation only when they have a concrete cross-cluster routing or scheduling requirement. Cluster API is orthogonal --- it manages infrastructure regardless of the workload management strategy.

## Common Mistakes and Misconceptions

- **"One big cluster is always better than multiple small ones."** Large clusters have larger blast radius, harder upgrades, and more complex RBAC. Many organizations use multiple clusters for environment isolation, team autonomy, and regional locality.
- **"Multi-cluster means duplicating everything."** GitOps tools (ArgoCD, Flux) and fleet management (Rancher, GKE Fleet) let you manage multiple clusters from a single source of truth. The marginal cost of an additional cluster is primarily compute, not operational overhead.
- **"Service mesh is required for cross-cluster communication."** DNS-based service discovery, cloud load balancers, or simple ingress routing can connect services across clusters. A mesh adds mTLS and observability but isn't always necessary.

## Further Reading

- [ArgoCD ApplicationSets](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/) --- Multi-cluster GitOps
- [Karmada Documentation](https://karmada.io/docs/) --- Multi-cluster federation
- [Cilium ClusterMesh](https://docs.cilium.io/en/stable/network/clustermesh/) --- Cross-cluster networking
- [Cluster API](https://cluster-api.sigs.k8s.io/) --- Declarative cluster lifecycle management

---

*Next: [Building Internal Developer Platforms](35-platform-engineering.md) --- Backstage, golden paths, and the platform engineering stack.*

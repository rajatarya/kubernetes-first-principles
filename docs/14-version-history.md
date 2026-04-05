# Chapter 14: Kubernetes Version History --- A Guided Tour

For a visual timeline showing how the entire ecosystem evolved in parallel, see [Appendix E: Architecture Evolution Timeline](A5-timeline.md).

```
Kubernetes Release Timeline: The Inflection Points

2015       2016       2017       2018       2019       2020       2021       2022       2023       2024
  |          |          |          |          |          |          |          |          |          |
  v1.0       v1.5       v1.7       v1.9       v1.13      v1.20      v1.22      v1.24      v1.29      v1.31
  CNCF       CRI        CRDs       Apps/v1    kubeadm    Docker     API        docker-    Sidecar    nftables
  launch     intro      replace    GA         GA         deprec.    removals   shim       containers kube-proxy
             Stateful   TPR                   CSI 1.0               forced     removed    beta       
             Sets(b)    RBAC GA                                     migration             KMS v2
             PDB                                                                          GA

  ──────────>──────────>──────────>──────────>──────────>──────────>──────────>──────────>──────────>
  "Can it     "Can it     "Can we    "Is it      "Can      "Cleaning   "Removing  "Runtime   "Mature
   run?"       handle      extend     production  anyone    house"      the        independ-  platform"
               state?"     it?"       ready?"     set it                debt"     ence"
                                                  up?"
```

## v1.0 (July 2015): The Starting Line

Kubernetes 1.0 was released at OSCON 2015 alongside the announcement that Google was donating the project to the newly formed Cloud Native Computing Foundation (CNCF). The CNCF donation (covered in Chapter 8) gave competitors reason to contribute rather than fork.

The 1.0 release was sparse by modern standards. It had Pods, ReplicationControllers (the precursor to ReplicaSets and Deployments), Services, and Secrets. There were no Deployments, no StatefulSets, no RBAC, no CRDs. The scheduler was basic. Networking was primitive. But the core architectural decisions were already in place: the declarative API model, the reconciliation loop pattern, etcd as the state store, and the API server as the single point of access.

The significance of 1.0 was not its feature set but its **commitment to stability**. By calling it 1.0, the project promised backward compatibility. API resources marked as stable would not be removed or changed in breaking ways. This promise --- which Kubernetes has largely kept --- gave enterprises the confidence to invest in the platform.

## v1.2 (March 2016): First Usable for Production

Kubernetes 1.2 introduced three features that transformed it from a promising experiment into something you could actually run in production.

**ConfigMaps** provided a way to inject configuration data into pods without baking it into the container image. Before ConfigMaps, you had two options: environment variables (limited and inflexible) or mounting Secrets (semantically wrong for non-secret configuration).

**DaemonSets** ensured that a specific pod ran on every node (or a selected subset of nodes). This was essential for infrastructure agents: log collectors, monitoring agents, network plugins, storage drivers. Without DaemonSets, operators had to manually ensure these agents were running on every node and handle new nodes joining the cluster.

**Deployments** (in beta) introduced declarative rolling updates. Before Deployments, updating an application required manually managing ReplicationControllers --- creating a new one, scaling it up, scaling the old one down, and handling failures during the transition. Deployments automated this entire process and added rollback capability. The Deployment controller became the workhorse of Kubernetes, managing the vast majority of stateless workloads.

## v1.3 (July 2016): The State Problem

PetSets (later StatefulSets) provided stable network identities, per-pod persistent storage, and ordered scaling --- the features stateful workloads need that Deployments do not provide.

The name "PetSets" reflected the "pets vs. cattle" metaphor that dominated DevOps thinking: stateless containers were "cattle" (identical, replaceable) while stateful services were "pets" (unique, requiring individual care). The rename to StatefulSets in 1.5 was driven by the community's desire for a more descriptive, less metaphorical name.

Cluster federation also appeared in alpha, reflecting an early attempt to manage multiple clusters as a single entity. Federation proved premature --- the problem was real but the approach was wrong --- and it was eventually replaced by tools like Loft's vCluster, Admiralty, and the multi-cluster capabilities of service meshes and GitOps tools.

## v1.5 (December 2016): The Plugin Architecture Emerges

Kubernetes 1.5 was architecturally pivotal. The **Container Runtime Interface (CRI)** was introduced, beginning the process that would eventually lead to Docker's removal (covered in Chapter 10). **StatefulSets** reached beta, making stateful workloads viable for early adopters. **PodDisruptionBudgets** appeared, giving operators a way to express how much disruption a workload could tolerate during maintenance operations.

PodDisruptionBudgets solved a subtle but critical problem. When a node needed to be drained for maintenance (kernel upgrade, hardware repair), the system needed to know whether it was safe to evict a pod. For a Deployment with 10 replicas, losing one pod during a drain is fine. For a three-node etcd cluster, losing one node when another is already down would break quorum. PodDisruptionBudgets let operators express constraints like "at least 2 of 3 replicas must always be available," giving the drain process the information it needed to proceed safely.

## v1.6 (March 2017): Security Gets Serious

**RBAC (Role-Based Access Control)** reached beta and was enabled by default. Before RBAC, Kubernetes had ABAC (Attribute-Based Access Control), which required restarting the API server to change policies. However, the bigger problem was that many clusters simply ran with the AlwaysAllow authorizer --- the permissive default --- which allowed any authenticated user to do anything. ABAC was available as a more restrictive alternative, but its static file-based configuration made it cumbersome to adopt. RBAC changed this fundamentally.

RBAC introduced Roles (permissions scoped to a namespace), ClusterRoles (permissions scoped to the cluster), RoleBindings, and ClusterRoleBindings. It allowed fine-grained access control: developer A can create Deployments in namespace "team-a" but not in namespace "team-b." Service accounts can read ConfigMaps but not Secrets. CI/CD pipelines can deploy but not modify RBAC rules.

This release also migrated the default storage backend from **etcd v2 to etcd v3**, a significant change. etcd v3 introduced a flat key-value model (replacing v2's directory tree), a more efficient storage format, and support for watchers at scale. The migration was transparent to most users but was essential for supporting larger clusters.

**Dynamic storage provisioning** reached GA, allowing PersistentVolumeClaims to automatically trigger the creation of underlying storage (EBS volumes, GCE persistent disks, NFS shares) without manual administrator intervention. This completed the self-service model: developers could request storage in their manifests and the cluster would provision it automatically.

## v1.7 (June 2017): Extensibility Unlocked

**Custom Resource Definitions (CRDs)** replaced the earlier ThirdPartyResources, fundamentally changing what Kubernetes could do. CRDs allowed anyone to define new resource types in the Kubernetes API. Combined with custom controllers, CRDs turned Kubernetes from a container orchestration platform into a **general-purpose platform for managing any kind of resource**.

The significance of CRDs cannot be overstated. They enabled the "operator pattern" --- custom controllers that encode domain-specific operational knowledge. A PostgreSQL operator could define a PostgresCluster CRD, and a controller could watch for these resources and automatically provision databases, configure replication, manage backups, and handle failover. The operator pattern turned Kubernetes into a platform for automating the operation of complex software systems, not just running containers.

**Network Policies** reached GA, providing a mechanism to restrict pod-to-pod communication. Before Network Policies, the flat network model meant any pod could talk to any other pod --- a security model that was unacceptable for multi-tenant clusters or environments handling sensitive data.

## v1.8 (September 2017): RBAC Stabilizes

**RBAC reached GA**, completing its journey from alpha to stable. This was the release where Kubernetes' security model was considered production-ready. From this point forward, the expectation was that all clusters would use RBAC, and tools and documentation assumed its presence.

**CronJobs** reached beta, providing scheduled job execution (the Kubernetes equivalent of cron). While conceptually simple, CronJobs were important because they addressed a common pattern --- batch processing, report generation, database maintenance --- that previously required external scheduling systems.

## v1.9 (December 2017): The Apps API Stabilizes

This release marked the moment Kubernetes' core workload APIs became stable. **Deployments, ReplicaSets, StatefulSets, and DaemonSets all reached GA** under the apps/v1 API group.

The **Container Storage Interface (CSI)** appeared in alpha. CSI would do for storage what CRI did for container runtimes and CNI did for networking: define a standard interface so storage providers could be plugged in without modifying Kubernetes core code. Before CSI, storage drivers were compiled into Kubernetes, meaning a new storage provider required a change to the Kubernetes codebase. CSI decoupled storage from the Kubernetes release cycle.

## v1.11 (June 2018): Infrastructure Refresh

**CoreDNS replaced kube-dns** as the default cluster DNS provider. kube-dns was a composite of three containers (kube-dns, dnsmasq, sidecar) that was complex to debug and had known performance issues. CoreDNS was a single binary, written in Go, with a plugin-based architecture that made it flexible and easy to extend. The switch reflected a maturation of the ecosystem: better tools replaced adequate ones.

**IPVS-based kube-proxy reached GA**, providing an alternative to iptables mode for Service load-balancing. IPVS used hash tables instead of linear iptables chains, offering better performance at scale (thousands of Services). This was a stopgap improvement; the eventual answer would be eBPF, but IPVS provided meaningful improvements for clusters that could not yet adopt eBPF-based solutions.

## v1.13 (December 2018): The Bootstrap Milestone

**kubeadm reached GA**, meaning the Kubernetes project now had a stable, supported way to bootstrap clusters. This was the culmination of two years of development by SIG Cluster Lifecycle and was essential for the ecosystem of higher-level tools (kops, kubespray) that built on kubeadm.

**CSI 1.0** was released, completing the storage plugin interface specification. Storage vendors could now build drivers that worked with any Kubernetes version without compiling code into Kubernetes. This accelerated the storage ecosystem enormously: vendors shipped CSI drivers for their proprietary storage systems, and the community built CSI drivers for NFS, Ceph, and other open-source storage systems.

## v1.16 (September 2019): CRDs Grow Up

**CRDs reached GA with structural schemas**, meaning CRD authors could define OpenAPI v3 schemas for their custom resources. The API server would validate custom resources against these schemas, rejecting invalid objects. Before structural schemas, CRDs accepted any JSON object, which meant validation errors were only caught at the controller level. Structural schemas moved validation to the API server, matching the behavior of built-in resources.

This release also **deprecated extensions/v1beta1** for Deployments, DaemonSets, and ReplicaSets, forcing users to migrate to apps/v1. This was the beginning of a pattern: Kubernetes would aggressively deprecate beta APIs to prevent permanent dependence on unstable interfaces.

## v1.20 (December 2020): The Docker Announcement

The **dockershim deprecation announcement** dominated this release's narrative (covered in detail in Chapter 10). Beyond the Docker story, v1.20 introduced **graceful node shutdown**, allowing the kubelet to detect that the node's operating system was shutting down and gracefully terminate pods in priority order. Before this, a node shutdown simply killed all pods, potentially interrupting critical workloads mid-operation.

## v1.22 (August 2021): The Great API Migration

This release **removed many deprecated beta APIs** that had been deprecated since v1.16. Ingress moved from extensions/v1beta1 to networking.k8s.io/v1. CRD moved from apiextensions.k8s.io/v1beta1 to v1. ValidatingWebhookConfiguration and MutatingWebhookConfiguration moved to admissionregistration.k8s.io/v1.

The removals caused significant disruption. Many Helm charts, operators, and deployment scripts still referenced the old API versions. Tools that generated Kubernetes manifests had to be updated. The community learned a painful lesson about the cost of depending on beta APIs and the importance of migration planning.

**Server-side apply reached GA**, moving manifest merging logic from kubectl to the API server. This enabled conflict detection (two controllers modifying the same field), field ownership tracking, and consistent behavior across all API clients. Server-side apply was foundational for the emerging GitOps ecosystem, where multiple tools might manage different fields of the same resource.

## v1.24 (May 2022): Runtime Independence

The **dockershim was removed**, completing the deprecation announced in v1.20. Clusters using Docker as their container runtime needed to switch to containerd or CRI-O. In practice, most managed Kubernetes services had already made this switch, and the impact on self-managed clusters was modest because containerd --- the actual runtime inside Docker --- was already present on most nodes.

## v1.25 (August 2022): Security Model Modernization

**PodSecurityPolicy (PSP) was removed**, ending a contentious chapter in Kubernetes security. PSP had been the mechanism for restricting what pods could do (run as root, use host networking, mount host paths), but it was widely regarded as confusing, difficult to use correctly, and prone to misconfiguration. Its replacement was **Pod Security Standards** enforced through the Pod Security Admission controller, which defined three profiles --- Privileged, Baseline, and Restricted --- that were simpler to understand and apply.

**Ephemeral containers reached GA**, allowing operators to inject temporary debugging containers into running pods. Before ephemeral containers, debugging a distroless or minimal container (which lacked shells, debugging tools, or even a writable filesystem) required rebuilding the image with debugging tools, redeploying, and reproducing the problem. Ephemeral containers solved this by allowing you to attach a container with debugging tools to a running pod without restarting it.

## v1.27 (April 2023): Resource Flexibility

**In-place pod resource resize** appeared in alpha, addressing a long-standing limitation. Before this feature, changing a pod's CPU or memory limits required deleting and recreating the pod. For stateful workloads, this meant downtime. In-place resize allowed changing resource limits on a running pod, with the kubelet adjusting cgroup limits without restarting the container.

**SeccompDefault reached GA**, enabling Seccomp security profiles by default for all pods. Seccomp restricts which system calls a container can make, reducing the kernel attack surface. Making it default-on was a security hardening step that moved the ecosystem toward defense-in-depth.

## v1.29 (December 2023): Sidecar Containers and Secrets at Scale

**Sidecar containers reached beta (enabled by default)** (formally: native sidecar support via init containers with restartPolicy: Always, with GA expected in v1.33). This addressed a long-standing problem with the sidecar pattern: Kubernetes had no native concept of a container that started before and stopped after the main container. Log collectors, service mesh proxies, and monitoring agents were deployed as sidecars, but Kubernetes treated them as ordinary containers. This led to startup ordering issues (the sidecar proxy might not be ready when the application started) and shutdown ordering issues (the sidecar might be killed before the application finished draining connections).

**KMS v2 reached GA** for secrets encryption at rest. Kubernetes Secrets are stored in etcd, and without encryption at rest, anyone with access to etcd's data directory can read all Secrets in plaintext. KMS v2 provided a standard interface for integrating with external key management services (AWS KMS, Google Cloud KMS, Azure Key Vault, HashiCorp Vault), ensuring Secrets were encrypted in etcd using keys managed by a dedicated, auditable, access-controlled key management system.

## v1.30 (April 2024): Authentication and Resource Management

**Structured authentication configuration** allowed administrators to configure authentication using a file-based configuration rather than a proliferation of API server flags. This made authentication setup more manageable, auditable, and version-controllable.

**Dynamic Resource Allocation (DRA)** continued its progression, providing a framework for managing non-traditional resources (GPUs, FPGAs, network devices) through a structured API rather than the opaque extended resources mechanism. DRA was driven by the explosive growth of AI/ML workloads that required fine-grained GPU allocation and sharing.

## v1.31 (August 2024): Kernel-Level Security and Modern Networking

**AppArmor support reached GA**, providing mandatory access control profiles that restrict container capabilities at the kernel level. AppArmor profiles could limit filesystem access, network operations, and capability usage, providing a defense-in-depth layer beyond Seccomp and Linux capabilities.

The **nftables kube-proxy backend** was promoted to beta (it first appeared as alpha in v1.29), replacing iptables with its successor in the Linux kernel. nftables provides better performance, a cleaner rule syntax, and improved maintainability. While eBPF-based solutions (Cilium, Calico) offer superior performance, nftables modernized the default kube-proxy for environments that prefer to use the standard kernel networking stack.

## v1.32+ (2025-2026): Continued Maturation

Recent and upcoming releases continue the trend of maturation rather than revolution. Dynamic Resource Allocation improvements address the growing demand for GPU and accelerator scheduling in AI/ML workloads. In-place pod resource resize progresses toward GA. The overall pattern is one of stabilization: making alpha features beta, making beta features GA, and improving the operational experience of features that are already stable.

## The Pattern Behind the Versions

Reading the version history as a narrative rather than a changelog reveals a clear pattern of maturation:

**2015-2016: Can it run at all?** The early releases focused on basic functionality --- scheduling pods, running stateless workloads, providing services. Kubernetes was proving that the architecture worked.

**2016-2017: Can it handle real workloads?** StatefulSets, RBAC, CRDs, Network Policies. These features addressed the requirements of production systems: state, security, extensibility, and network isolation.

**2018-2019: Can anyone set it up?** kubeadm, CSI, Helm v3. The focus shifted from what Kubernetes could do to how people could deploy and manage it. The tooling ecosystem matured alongside the platform.

**2020-2022: Cleaning up the debt.** Docker deprecation, API removals, PSP removal. Kubernetes spent these years removing technical debt and forcing the ecosystem to migrate away from deprecated interfaces. This was painful but necessary for long-term health.

**2023-2026: Mature platform.** Sidecar containers, in-place resize, DRA, security hardening. The features being added are refinements, not revolutions. Kubernetes is no longer proving itself; it is optimizing for the workloads and operational patterns that have emerged over a decade of production use.

The version history also reveals the disciplined API lifecycle that makes Kubernetes trustworthy as a platform. Features progress through alpha (disabled by default, may change or be removed), beta (enabled by default, API may change), and GA (stable, backward compatible, will not be removed). This lifecycle gives users clear signals about what is safe to depend on and gives the community space to iterate on APIs before committing to them permanently.

## Common Mistakes and Misconceptions

- **"I should always run the latest Kubernetes version."** New versions may have bugs, and your tools/operators may not support them yet. Use release channels (Stable or Regular) and wait 1-2 months after a minor release before upgrading production.
- **"Skipping minor versions during upgrades is fine."** Kubernetes supports upgrading one minor version at a time (e.g., 1.28 → 1.29 → 1.30). Skipping versions can break API compatibility and is unsupported.
- **"Deprecated APIs will keep working forever."** Deprecated APIs are removed after a defined period (typically 2-3 releases). Plan migrations early using `kubectl convert` or tools like Pluto to detect deprecated APIs.

## Further Reading

- [Kubernetes Release Notes (official)](https://kubernetes.io/releases/) -- The canonical list of all Kubernetes releases with links to changelogs, release notes, and upgrade guides. Start here to understand what changed in any specific version.
- [Kubernetes Deprecation Policy](https://kubernetes.io/docs/reference/using-api/deprecation-policy/) -- The formal rules governing how APIs and features are deprecated and removed, including the minimum version guarantees for GA, beta, and alpha APIs.
- [Kubernetes Enhancement Proposals (KEP) process](https://github.com/kubernetes/enhancements/blob/master/keps/README.md) -- How new features go from idea to implementation. Understanding KEPs explains why features take multiple releases to mature and how the community coordinates large changes.
- [SIG Release](https://github.com/kubernetes/sig-release) -- The Special Interest Group responsible for the release process, cadence, and tooling. The README and meeting notes provide insight into how the three-releases-per-year cadence is managed.
- [Kubernetes CHANGELOG on GitHub](https://github.com/kubernetes/kubernetes/tree/master/CHANGELOG) -- The raw changelogs for every release, useful for detailed investigation of specific changes, bug fixes, and API modifications.
- ["Kubernetes Release Cadence Change: Here's What You Need To Know" (Kubernetes blog)](https://kubernetes.io/blog/2021/07/20/new-kubernetes-release-cadence/) -- Explains the move from four to three releases per year and how the new cadence balances stability with velocity.
- [API Version Lifecycle documentation](https://kubernetes.io/docs/reference/using-api/#api-versioning) -- Official reference for understanding alpha, beta, and GA API stages, which directly maps to the feature maturation pattern described in this chapter.

---

*This concludes Part 2: The Tooling Ecosystem. You now understand how the tools around Kubernetes evolved and why they look the way they do today. Part 3 takes all of this context and puts it into practice --- setting up real clusters, deploying real workloads, and learning to debug when things go wrong.*

Next: [Setting Up a Cluster from Scratch](15-cluster-setup.md)

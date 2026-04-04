# The Ultimate Kubernetes Course

**From First Principles to Production: A Complete Curriculum**

This is an eight-part course that takes you from "why does Kubernetes exist?" to "I'm running GPU-accelerated ML workloads in production across multiple clusters." It is written for someone who understands Linux, networking, and computing but wants to deeply understand Kubernetes --- not just follow tutorials, but build genuine intuition for how the system works and why.

---

## Part 1: First Principles

*Why Kubernetes was designed the way it was.*

1. [The Road to Kubernetes](01-history.md) --- From bare metal to Borg to Kubernetes
2. [The Problems Kubernetes Solves](02-problems.md) --- Bin packing, service discovery, self-healing, and the desired state model
3. [Architecture from First Principles](03-architecture.md) --- etcd, API server, controllers, scheduler, kubelet, kube-proxy
4. [The API Model](04-api-model.md) --- Resources, specs, status, reconciliation loops, labels, and CRDs
5. [The Networking Model](05-networking.md) --- Flat networking, CNI, Services, Ingress, and Network Policies
6. [The Ecosystem](06-ecosystem.md) --- Operators, Helm, service meshes, and Kubernetes as a platform for platforms
7. [Key Design Principles](07-design-principles.md) --- Declarative over imperative, control loops, level-triggered vs edge-triggered
8. [Why Kubernetes Won](08-why-k8s-won.md) --- The competitive landscape and the deeper architectural lesson
9. [References and Further Reading](09-references.md) --- Foundational papers, design documents, talks, and books

## Part 2: The Tooling Ecosystem — History and Evolution

*How the tools around Kubernetes evolved, and why they look the way they do today.*

10. [The Container Runtime Wars](10-container-runtimes.md) --- Docker to containerd to CRI-O: why Docker was deprecated
11. [Bootstrapping a Cluster](11-cluster-bootstrap.md) --- From kube-up.sh to kubeadm: how cluster setup evolved
12. [Package Management and GitOps](12-package-management.md) --- Helm v2/v3, Kustomize, ArgoCD, Flux
13. [The Networking Stack Evolution](13-networking-evolution.md) --- Flannel to Calico to Cilium: how eBPF changed everything
14. [Kubernetes Version History](14-version-history.md) --- A guided tour of key releases and what they introduced

## Part 3: From Theory to Practice

*Connecting the principles from Part 1 to real-world usage.*

15. [Setting Up a Cluster from Scratch](15-cluster-setup.md) --- What kubeadm actually does: TLS bootstrapping, static pods
16. [Managed Kubernetes: EKS, GKE, and AKS](16-managed-k8s.md) --- Cloud provider comparison and how to choose
17. [Cloud Networking and Storage](17-cloud-integration.md) --- VPC CNI, CSI drivers, and how K8s maps to cloud infrastructure
18. [Your First Workloads](18-first-workloads.md) --- Hands-on: Deployments, Services, ConfigMaps, rolling updates
19. [Debugging Kubernetes](19-debugging.md) --- The kubectl toolkit and diagnosing common failures
20. [Production Readiness](20-production-readiness.md) --- Monitoring, logging, security basics, and backup

## Part 4: Stateful Workloads

*Running real applications with persistent state.*

21. [StatefulSets Deep Dive](21-statefulsets.md) --- Stable identities, ordered operations, and headless Services
22. [Databases on Kubernetes](22-databases.md) --- When to run databases on K8s, operators, and the trade-offs
23. [Persistent Storage Patterns](23-storage-patterns.md) --- volumeClaimTemplates, reclaim policies, backup, and resize
24. [Jobs and CronJobs](24-jobs.md) --- Batch processing, indexed completions, and scheduling patterns

## Part 5: Security Deep Dive

*Understanding and implementing Kubernetes security from the ground up.*

25. [RBAC from First Principles](25-rbac.md) --- Roles, bindings, ServiceAccounts, and multi-tenant design
26. [Network Policies](26-network-policies.md) --- Default deny, namespace isolation, and egress control
27. [Supply Chain Security](27-supply-chain.md) --- Image signing, admission policies, scanning, and SLSA
28. [Secrets Management](28-secrets.md) --- Encryption at rest, Vault, External Secrets Operator, and best practices
29. [Pod Security Standards](29-pod-security.md) --- Privileged, Baseline, Restricted profiles and enforcement

## Part 6: Scaling and Performance

*Making Kubernetes handle real-world load.*

30. [Horizontal Pod Autoscaler](30-hpa.md) --- The scaling algorithm, custom metrics, KEDA, and tuning
31. [Vertical Pod Autoscaler and Right-Sizing](31-vpa.md) --- Recommendation mode, in-place resize, and resource tuning
32. [Node Scaling: Cluster Autoscaler and Karpenter](32-node-scaling.md) --- How nodes scale, Karpenter's architecture, and consolidation
33. [Resource Tuning Deep Dive](33-resource-tuning.md) --- CPU throttling, memory cgroups, NUMA, and overcommitment

## Part 7: Multi-Cluster and Platform Engineering

*Operating Kubernetes at organizational scale.*

34. [Multi-Cluster Strategies](34-multi-cluster.md) --- Federation, GitOps-driven, service mesh, and Cluster API
35. [Building Internal Developer Platforms](35-platform-engineering.md) --- Backstage, the platform stack, and reducing cognitive load
36. [Crossplane: Infrastructure as CRDs](36-crossplane.md) --- Managing cloud resources through Kubernetes
37. [Multi-Tenancy](37-multi-tenancy.md) --- Namespace isolation, virtual clusters, and tenant boundaries

## Part 8: Advanced Topics

*Deep dives for infrastructure engineers.*

38. [Writing Controllers and Operators](38-operators.md) --- controller-runtime, Kubebuilder, and the Reconcile pattern
39. [The Kubernetes API Internals](39-api-internals.md) --- Aggregation, admission webhooks, API priority and fairness
40. [etcd Operations](40-etcd-ops.md) --- Backup, restore, compaction, monitoring, and disaster recovery
41. [GPU Workloads and AI/ML on Kubernetes](41-gpu-ml.md) --- Device plugins, DRA, GPU sharing, distributed training
42. [Running LLMs on Kubernetes](42-llm-infrastructure.md) --- vLLM, TGI, KServe, multi-node inference, and model serving
43. [Disaster Recovery](43-disaster-recovery.md) --- Cluster backup, etcd snapshots, multi-region strategies
44. [Cost Optimization](44-cost-optimization.md) --- Right-sizing, spot instances, Kubecost, and chargeback
45. [Observability with OpenTelemetry](45-observability.md) --- Metrics, logs, traces, and the OTel Collector

---

## How to Read This

**Part 1** is the intellectual foundation. Read it first.

**Part 2** fills in the historical context of the tooling. Read it after Part 1.

**Part 3** is hands-on. Reference it as you work through your own cluster.

**Parts 4-5** cover stateful workloads and security — essential for running real production systems.

**Part 6** covers scaling — read it when your workloads need to handle real load.

**Part 7** is for when you're operating multiple clusters or building a platform team.

**Part 8** is deep reference material. Read chapters as needed. The GPU/ML chapters (41-42) are especially relevant for AI infrastructure teams.

**If you only have time for one chapter from each part:**
- Part 1: [Architecture from First Principles](03-architecture.md)
- Part 2: [The Container Runtime Wars](10-container-runtimes.md)
- Part 3: [Debugging Kubernetes](19-debugging.md)
- Part 4: [StatefulSets Deep Dive](21-statefulsets.md)
- Part 5: [RBAC from First Principles](25-rbac.md)
- Part 6: [Node Scaling: Cluster Autoscaler and Karpenter](32-node-scaling.md)
- Part 7: [Building Internal Developer Platforms](35-platform-engineering.md)
- Part 8: [GPU Workloads and AI/ML on Kubernetes](41-gpu-ml.md)

## Appendices

- [Appendix A: Glossary](A1-glossary.md) — Quick-reference definitions for 100+ Kubernetes terms
- [Appendix B: Mental Models](A2-mental-models.md) — Visual diagrams showing how concepts in each part connect
- [Appendix C: Decision Trees](A3-decision-trees.md) — Flowcharts for choosing workload types, storage, networking, and tools
- [Appendix D: Troubleshooting Quick Reference](A4-troubleshooting.md) — Error messages mapped to root causes and fixes
- [Appendix E: Architecture Evolution Timeline](A5-timeline.md) — How the Kubernetes ecosystem evolved from 2013 to today

## Companion Material

- [install.sh](../install.sh) --- The bootstrap script we built to provision Kubernetes nodes on EC2
- [Colophon](COLOPHON.md) --- How this book was made, the prompts used, and accuracy notes

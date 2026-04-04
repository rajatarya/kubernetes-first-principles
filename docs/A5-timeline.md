# Appendix E: Architecture Evolution Timeline

Kubernetes and its ecosystem have evolved rapidly since 2014. This timeline shows the major architectural shifts — each one driven by real problems with the previous approach. Understanding this evolution explains why the current ecosystem looks the way it does.

---

## Visual Timeline (2013-2026)

```
YEAR  CONTAINER RUNTIME        ORCHESTRATION             NETWORKING               PACKAGE MGMT
      ────────────────────     ─────────────────────     ────────────────────     ────────────────────
      
2013  ┌─────────────────┐     ┌─────────────────────┐
      │ Docker released  │     │ Docker Compose       │
      │ (monolithic      │     │ (single host only)   │
      │  daemon)         │     └─────────────────────┘
      └────────┬─────────┘
               │
2014           │              ┌─────────────────────┐
               │              │ K8s announced (June) │
               │              │ Docker Swarm         │
               │              │ Mesos / Marathon     │
               │              └──────────┬──────────┘
               │                         │
2015  ┌────────┴─────────┐   ┌──────────┴──────────┐   ┌────────────────────┐   ┌────────────────────┐
      │ OCI founded      │   │ Kubernetes 1.0       │   │ Flannel (overlay)  │   │ Raw YAML           │
      │ runc extracted   │   │ CNCF founded         │   │ kube-proxy +       │   │ kubectl apply      │
      └────────┬─────────┘   └──────────┬──────────┘   │  iptables          │   └─────────┬──────────┘
               │                         │              └─────────┬──────────┘             │
2016  ┌────────┴─────────┐               │              ┌─────────┴──────────┐   ┌─────────┴──────────┐
      │ containerd       │               │              │ Calico (BGP)       │   │ Helm v2            │
      │ extracted from   │               │              │ Canal              │   │ (with Tiller)      │
      │ Docker           │               │              └─────────┬──────────┘   └─────────┬──────────┘
      └────────┬─────────┘               │                        │                        │
2017  ┌────────┴─────────┐   ┌──────────┴──────────┐   ┌─────────┴──────────┐             │
      │ CRI interface    │   │ Docker Swarm         │   │ CNI spec matures   │             │
      │ defined          │   │ embedded in Docker   │   └─────────┬──────────┘             │
      └────────┬─────────┘   └──────────┬──────────┘             │                        │
               │                         │                        │                        │
2018           │                         │                        │              ┌─────────┴──────────┐
               │                         │                        │              │ Kustomize           │
               │                         │                        │              │ (patch-based)       │
               │                         │                        │              └─────────┬──────────┘
2019           │              ┌──────────┴──────────┐   ┌─────────┴──────────┐   ┌─────────┴──────────┐
               │              │ Docker Enterprise   │   │ Cilium             │   │ Helm v3            │
               │              │ sold to Mirantis    │   │ (eBPF-based)       │   │ (no Tiller!)       │
               │              └──────────┬──────────┘   └─────────┬──────────┘   └─────────┬──────────┘
               │                         │                        │                        │
2020  ┌────────┴─────────┐               │              ┌─────────┴──────────┐   ┌─────────┴──────────┐
      │ K8s 1.20:        │               │              │                    │   │ Helm + Kustomize   │
      │ dockershim       │               │              │                    │   │ combined pattern   │
      │ DEPRECATED       │               │              │                    │   └─────────┬──────────┘
      └────────┬─────────┘               │              │                    │             │
               │              ┌──────────┴──────────┐   │ eBPF goes          │             │
2021           │              │ Apache Mesos         │   │ mainstream         │             │
               │              │ RETIRED              │   │                    │             │
               │              └──────────┬──────────┘   │ Cilium service     │             │
               │                         │              │ mesh               │             │
               │                         │              └─────────┬──────────┘             │
2022  ┌────────┴─────────┐               │                        │                        │
      │ K8s 1.24:        │               │                        │                        │
      │ dockershim       │               │                        │                        │
      │ REMOVED          │               │                        │                        │
      └────────┬─────────┘               │                        │                        │
               │                         │              ┌─────────┴──────────┐   ┌─────────┴──────────┐
2023           │                         │              │ Gateway API GA     │   │ cdk8s, Timoni       │
               │                         │              └─────────┬──────────┘   │ (CUE-based)        │
               │                         │                        │              └─────────┬──────────┘
2024  ┌────────┴─────────┐   ┌──────────┴──────────┐   ┌─────────┴──────────┐             │
      │ containerd +     │   │ Kubernetes is        │   │ Cilium = default   │             │
      │ CRI-O are the    │   │ THE standard         │   │ CNI for many       │             │
      │ standards        │   │                      │   │ platforms          │             │
      └─────────────────┘   └─────────────────────┘   └────────────────────┘             │
```

```
YEAR  SECURITY                 GITOPS & PLATFORM         SCALING                  GPU / ML
      ────────────────────     ─────────────────────     ────────────────────     ────────────────────

2016                                                     ┌────────────────────┐
                                                         │ Cluster Autoscaler │
                                                         └─────────┬──────────┘
2017  ┌────────────────────┐                             ┌─────────┴──────────┐
      │ RBAC GA (K8s 1.8)  │                             │ HPA v2             │
      └─────────┬──────────┘                             └─────────┬──────────┘
                │                                                  │
2018  ┌─────────┴──────────┐   ┌─────────────────────┐             │              ┌────────────────────┐
      │ PodSecurityPolicy  │   │ ArgoCD, Flux v1      │             │              │ Device plugins     │
      │ (PSP)              │   │ GitOps begins         │             │              │ for GPUs           │
      └─────────┬──────────┘   └──────────┬──────────┘             │              └─────────┬──────────┘
                │                          │                        │                        │
2019            │                          │                        │                        │
                │                          │                        │                        │
2020  ┌─────────┴──────────┐   ┌──────────┴──────────┐             │              ┌─────────┴──────────┐
      │ OPA / Gatekeeper   │   │ Flux v2 rewrite      │             │              │ Kubeflow, KubeRay  │
      └─────────┬──────────┘   └──────────┬──────────┘             │              └─────────┬──────────┘
                │                          │                        │                        │
2021  ┌─────────┴──────────┐   ┌──────────┴──────────┐   ┌─────────┴──────────┐             │
      │ Sigstore, Cosign   │   │ Crossplane           │   │ Karpenter (AWS)    │             │
      │ Kyverno matures    │   │ Backstage -> CNCF    │   │                    │             │
      └─────────┬──────────┘   └──────────┬──────────┘   │  ┌──────────────┐  │             │
                │                          │              │  │ WHY:         │  │             │
2022  ┌─────────┴──────────┐   ┌──────────┴──────────┐   │  │ CA was too   │  │   ┌─────────┴──────────┐
      │ PSP DEPRECATED     │   │ Platform Engineering │   │  │ slow, group- │  │   │ NVIDIA GPU         │
      └─────────┬──────────┘   │ as a discipline      │   │  │ based, no    │  │   │ Operator mature    │
                │              └──────────┬──────────┘   │  │ bin-packing  │  │   └─────────┬──────────┘
                │                          │              │  │ Karpenter:   │  │             │
2023  ┌─────────┴──────────┐               │              │  │ provisions   │  │   ┌─────────┴──────────┐
      │ Pod Security       │               │              │  │ nodes per-   │  │   │ DRA alpha          │
      │ Standards (PSS)    │               │              │  │ pod, faster  │  │   │ (Dynamic Resource  │
      │ replace PSP        │               │              │  │ consolidates │  │   │  Allocation)       │
      └─────────┬──────────┘               │              │  └──────────────┘  │   └─────────┬──────────┘
                │                          │              │                    │             │
                │                          │              ├─────────┬──────────┤             │
2024  ┌─────────┴──────────┐   ┌──────────┴──────────┐   │Karpenter│ VPA     │   ┌─────────┴──────────┐
      │ Supply chain       │   │ Internal Developer   │   │ GA      │ improv- │   │ LLM serving        │
      │ security: SBOM,    │   │ Platforms (IDPs)     │   │         │ ements  │   │ explosion: vLLM,   │
      │ SLSA standard      │   │ go mainstream        │   │ Karp.   │         │   │ TGI, KServe        │
      │ practice           │   │                      │   │ Azure   │         │   └─────────┬──────────┘
      └────────────────────┘   └─────────────────────┘   │(preview)│         │             │
                                                         └─────────┴─────────┘   ┌─────────┴──────────┐
2025                                                                             │ llm-d               │
                                                                                 │ LeaderWorkerSet for │
                                                                                 │ multi-node inference│
                                                                                 └────────────────────┘
```

```
YEAR  OBSERVABILITY
      ────────────────────────────

2016  ┌────────────────────────────┐
      │ Prometheus joins CNCF      │
      └──────────────┬─────────────┘
                     │
2018  ┌──────────────┴─────────────┐
      │ Prometheus graduates CNCF  │
      └──────────────┬─────────────┘
                     │
2019  ┌──────────────┴─────────────┐
      │ OpenTelemetry formed       │
      │ (OpenTracing + OpenCensus  │
      │  merger)                   │
      └──────────────┬─────────────┘
                     │
2021  ┌──────────────┴─────────────┐
      │ Grafana Loki, Tempo mature │
      └──────────────┬─────────────┘
                     │
2023  ┌──────────────┴─────────────┐
      │ OpenTelemetry GA           │
      │ (traces, metrics)          │
      └──────────────┬─────────────┘
                     │
2024  ┌──────────────┴─────────────┐
      │ OpenTelemetry logging      │
      │ matures                    │
      └────────────────────────────┘
```

---

## Node Autoscaling: The CA-to-Karpenter Transition

```
  Cluster Autoscaler (2016)                       Karpenter (2021+)
  ┌────────────────────────────┐                  ┌────────────────────────────┐
  │ - Node-group based         │   ──────────>    │ - Groupless provisioning   │
  │ - Scale by group min/max   │   Why it         │ - Per-pod scheduling       │
  │ - Slow reaction time       │   changed:       │ - Fast (seconds, not mins) │
  │ - No bin-packing           │                  │ - Active consolidation     │
  │ - Separate config per      │   CA couldn't    │ - Automatic right-sizing   │
  │   instance type group      │   keep up with   │ - Works across instance    │
  │ - Reactive only            │   diverse GPU/   │   types and architectures  │
  └────────────────────────────┘   ML workloads   └────────────────────────────┘
```

---

## Summary: Architectural Shifts by Domain

| Domain | Old Way | New Way | Why It Changed |
|---|---|---|---|
| **Container Runtime** | Docker (monolithic daemon) | containerd / CRI-O via CRI | Docker included too much (build, swarm, CLI). K8s only needs a runtime. CRI allows pluggable runtimes. |
| **Orchestration** | Docker Swarm, Mesos, multiple options | Kubernetes (universal standard) | K8s won on extensibility (CRDs, operators) and ecosystem. Swarm was too simple, Mesos too complex. |
| **Networking** | Flannel overlay + iptables kube-proxy | Cilium (eBPF) + Gateway API | iptables doesn't scale. Overlay adds latency. eBPF gives kernel-level networking without kube-proxy. |
| **Package Management** | Raw YAML / Helm v2 with Tiller | Helm v3 + Kustomize (or combined) | Tiller was a security risk (cluster-admin in-cluster). Raw YAML doesn't compose. Kustomize avoids templating. |
| **Security** | PodSecurityPolicy (PSP) | Pod Security Standards (PSS) + Kyverno/OPA | PSP was confusing, hard to audit, and couldn't be extended. PSS is simpler; policy engines are more flexible. |
| **GitOps & Platform** | Manual kubectl apply / CI pipelines | ArgoCD/Flux + Internal Developer Platforms | Imperative deploys are fragile and unauditable. GitOps makes the desired state declarative and versioned. |
| **Scaling** | Cluster Autoscaler (node-group based) | Karpenter (groupless, per-pod) | CA was slow and inflexible with diverse workloads. Karpenter provisions exactly what's needed, fast. |
| **GPU/ML** | Basic device plugins | GPU Operator + DRA + specialized serving (vLLM, llm-d) | LLM explosion demands multi-node GPU scheduling, fractional GPUs, and inference-optimized runtimes. |
| **Observability** | Prometheus + ad-hoc logging/tracing | OpenTelemetry (unified) + Grafana stack | Three separate telemetry signals (metrics, logs, traces) needed a unified collection and correlation standard. |

---

*Back to [Table of Contents](00-README.md)*

# Appendix E: Architecture Evolution Timeline

Kubernetes and its ecosystem have evolved rapidly since 2014. This timeline shows the major architectural shifts — each one driven by real problems with the previous approach. Understanding this evolution explains why the current ecosystem looks the way it does.

---

## Visual Timeline (2013-2026)

### Container Runtimes, Orchestration, Networking, and Package Management

```mermaid
flowchart TD
    subgraph y2013 ["2013"]
        docker13["Docker released<br>(monolithic daemon)"]
    end

    subgraph y2015 ["2015"]
        oci["OCI founded<br>runc extracted"]
        k8s10["Kubernetes 1.0<br>CNCF founded"]
        flannel["Flannel (overlay)<br>kube-proxy + iptables"]
        yaml15["Raw YAML<br>kubectl apply"]
    end

    subgraph y2016 ["2016"]
        containerd16["containerd extracted<br>from Docker"]
        calico["Calico (BGP)<br>Canal"]
        helm2["Helm v2<br>(with Tiller)"]
    end

    subgraph y2017 ["2017"]
        cri17["CRI interface defined"]
        swarm17["Docker Swarm<br>embedded in Docker"]
        cni17["CNI spec matures"]
    end

    subgraph y2018 ["2018-2019"]
        kust["Kustomize<br>(patch-based)"]
        cilium["Cilium (eBPF-based)"]
        helm3["Helm v3 (no Tiller!)"]
        mesos["Docker Enterprise<br>sold to Mirantis"]
    end

    subgraph y2020 ["2020-2022"]
        deprec["K8s 1.20: dockershim<br>DEPRECATED"]
        removed["K8s 1.24: dockershim<br>REMOVED"]
        mesos21["Apache Mesos<br>RETIRED"]
        helmkust["Helm + Kustomize<br>combined pattern"]
    end

    subgraph y2023 ["2023-2024"]
        std24["containerd + CRI-O<br>are the standards"]
        k8sstd["Kubernetes is<br>THE standard"]
        gw["Gateway API GA"]
        ciliumdef["Cilium = default CNI<br>for many platforms"]
        cdk["cdk8s, Timoni<br>(CUE-based)"]
    end

    docker13 --> oci --> containerd16 --> cri17 --> deprec --> removed --> std24
    docker13 --> k8s10 --> swarm17 --> mesos --> mesos21 --> k8sstd
    flannel --> calico --> cni17 --> cilium --> gw --> ciliumdef
    yaml15 --> helm2 --> kust --> helm3 --> helmkust --> cdk
```

Four parallel evolutions that shaped the infrastructure layer: Docker's monolith was decomposed into containerd and CRI-O. The orchestration wars ended with Kubernetes as the universal standard. Networking shifted from overlays and iptables to eBPF-native with Cilium. And YAML management evolved from raw manifests through Helm's Tiller era to today's Helm v3 + Kustomize hybrid.

### Security, GitOps, Scaling, and GPU/ML

```mermaid
flowchart TD
    subgraph y2017b ["2016-2017"]
        rbac["RBAC GA (K8s 1.8)"]
        ca["Cluster Autoscaler"]
        hpa["HPA v2"]
    end

    subgraph y2018b ["2018"]
        psp["PodSecurityPolicy"]
        argo["ArgoCD, Flux v1<br>GitOps begins"]
        devplugin["Device plugins<br>for GPUs"]
    end

    subgraph y2020b ["2020-2021"]
        opa["OPA / Gatekeeper"]
        sig["Sigstore, Cosign<br>Kyverno matures"]
        flux2["Flux v2 rewrite"]
        crossplane["Crossplane<br>Backstage joins CNCF"]
        karpenter["Karpenter (AWS)"]
        kubeflow["Kubeflow, KubeRay"]
    end

    subgraph y2022b ["2022-2023"]
        pspdep["PSP DEPRECATED"]
        pss["Pod Security Standards<br>replace PSP"]
        plateng["Platform Engineering<br>as a discipline"]
        gpuop["NVIDIA GPU<br>Operator mature"]
        dra["DRA alpha<br>(Dynamic Resource Allocation)"]
    end

    subgraph y2024b ["2024-2025"]
        supply["Supply chain security:<br>SBOM, SLSA standard"]
        idp["Internal Developer<br>Platforms go mainstream"]
        karpga["Karpenter GA<br>+ Azure support"]
        llm["LLM serving explosion:<br>vLLM, TGI, KServe"]
        llmd["llm-d, LeaderWorkerSet<br>multi-node inference"]
    end

    rbac --> psp --> opa --> pspdep --> pss --> supply
    argo --> flux2 --> crossplane --> plateng --> idp
    ca --> hpa --> karpenter --> karpga
    sig ~~~ pss
    devplugin --> kubeflow --> gpuop --> dra --> llm --> llmd
```

Security moved from the flawed PodSecurityPolicy to the simpler Pod Security Standards, while policy engines like OPA and Kyverno filled the gap. GitOps went from manual kubectl to ArgoCD/Flux, then broadened into full Internal Developer Platforms. Scaling evolved from the slow, group-based Cluster Autoscaler to Karpenter's per-pod provisioning. And GPU/ML infrastructure exploded from basic device plugins to DRA, vLLM, and disaggregated serving with llm-d.

### Observability

```mermaid
timeline
    title Observability Evolution
    2016 : Prometheus joins CNCF
    2018 : Prometheus graduates CNCF
    2019 : OpenTelemetry formed
         : (OpenTracing + OpenCensus merger)
    2021 : Grafana Loki, Tempo mature
    2023 : OpenTelemetry GA
         : (traces, metrics)
    2024 : OpenTelemetry logging matures
```

Observability converged from three fragmented signals — Prometheus for metrics, various tools for logs, and Jaeger/Zipkin for traces — into a unified standard with OpenTelemetry. The Grafana LGTM stack (Loki, Grafana, Tempo, Mimir) emerged as the dominant open-source backend.

---

## Node Autoscaling: The CA-to-Karpenter Transition

| | Cluster Autoscaler (2016) | | Karpenter (2021+) |
|---|---|---|---|
| **Abstraction** | Node-group based | **→** | Groupless provisioning |
| **Scaling unit** | Scale by group min/max | **→** | Per-pod scheduling |
| **Speed** | Slow (minutes) | **→** | Fast (seconds) |
| **Bin-packing** | No | **→** | Cross-instance-type optimization |
| **Consolidation** | Reactive only | **→** | Active consolidation |
| **Instance types** | Fixed per group | **→** | Works across all types |

> **Why it changed:** Cluster Autoscaler couldn't keep up with diverse GPU/ML workloads that needed fast, flexible provisioning across many instance types. Karpenter eliminated the node group abstraction entirely.

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

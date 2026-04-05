# Appendix B: Mental Models

Each part of this book introduces a cluster of related concepts. These diagrams show how they connect — use them as maps when navigating the chapters.

---

## Part 1: First Principles (Chapters 1-9)

**The Reconciliation Loop — the heart of Kubernetes.**

```mermaid
flowchart TD
    A["User writes YAML"] --> B["kubectl"]
    B --> C["API Server"]
    C --> D["etcd<br>(desired state stored here)"]

    C --> E["Controller Manager<br>(reconcile)"]
    C --> F["Scheduler<br>(assign to node)"]

    E --> G["kubelet (on node)"]
    F --> G

    G --> H["Container Runtime"]
    H --> I["Container"]

    subgraph loop ["The Watch / Reconciliation Loop"]
        direction LR
        W1["Controller watches"] --> W2["Detects drift"]
        W2 --> W3["Compares desired<br>vs. actual state"]
        W3 --> W4["Takes action<br>to converge"]
        W4 --> W1
    end
```

---

## Part 2: Tooling Evolution (Chapters 10-14)

**The Stack — what runs on what.**

```mermaid
flowchart TD
    S1["Application"]
    S2["Helm / Kustomize (packaging)"]
    S3["kubeadm / k3s (bootstrap)"]
    S4["Kubernetes API"]
    S5["Container Runtime<br>containerd / CRI-O"]
    S6["CNI Plugin<br>Cilium, Calico, Flannel ..."]
    S7["OCI Runtime (runc)"]

    S1 --> S2 --> S3 --> S4
    S4 --> S5
    S4 --> S6
    S5 --> S7
    S6 --> S7

    subgraph kernel ["Linux Kernel"]
        K1["cgroups<br>(resource limits)"]
        K2["namespaces<br>(isolation)"]
    end

    S7 --> kernel

    subgraph cni ["CNI Virtual Network"]
        direction LR
        PA["Pod A"] <--> PB["Pod B"]
    end

    S6 --> cni
```

---

## Part 3: Practical Setup (Chapters 15-19)

**Your First Cluster — who talks to whom.**

```mermaid
flowchart TD
    Cloud["Cloud Provider<br>(AWS / GCP / AZ)"]
    Cloud --> VPC

    kubectl["kubectl"] --> API
    CICD["CI/CD Pipeline"] --> VPC

    subgraph VPC
        subgraph CP ["Control Plane (managed)"]
            API["API Server"]
        end

        subgraph N1 ["Worker Node 1"]
            subgraph Pod1 ["Pod"]
                App["app"]
                Sidecar["sidecar"]
            end
        end

        subgraph N2 ["Worker Node 2"]
            Pod2a["Pod"]
            Pod2b["Pod"]
        end
    end

    API --> N1
    API --> N2

    subgraph debug ["Debugging Tools"]
        direction LR
        KC["kubectl"] --> Logs["logs"]
        KC --> Exec["exec"]
        KC --> Describe["describe (events)"]
    end
```

---

## Part 4: Stateful Workloads (Chapters 20-24)

**State — the hard problem.**

```mermaid
flowchart TD
    Deploy["Deployment<br>(stateless)<br>Pods are fungible,<br>interchangeable"]
    SS["StatefulSet<br>(ordered, stable ID)<br>pod-0, pod-1, pod-2<br>each has stable name"]

    SS --> PVC["PVC<br>(claim storage)"]
    PVC --> PV["PV<br>(actual volume)"]
    PV --> SC["StorageClass<br>(provisioner)"]
    SC --> Disk["Cloud Disk<br>(EBS / PD / AzD)"]

    subgraph operators ["Operators manage databases on K8s"]
        direction LR
        Op["Operator"] -->|watches| CRD["CRD<br>(e.g. PostgresCluster)"]
        CRD -->|manages| Res["StatefulSet +<br>PVCs + Secrets"]
    end

    subgraph jobs ["Jobs and CronJobs"]
        direction LR
        Job["Job<br>(run once)"]
        CronJob["CronJob<br>(scheduled)"] -->|creates Job<br>on schedule| Job
    end
```

---

## Part 5: Security (Chapters 25-29)

**Defense in Depth.**

```
    ┌────────────────────────────────────────────────────────┐
    │  Supply Chain (outermost ring)                         │
    │  Sigstore, SBOM, image scanning                        │
    │                                                        │
    │  ┌─────────────────────────────────────────────────┐   │
    │  │  Cluster                                        │   │
    │  │  RBAC, Admission Control (OPA/Kyverno)          │   │
    │  │                                                 │   │
    │  │  ┌─────────────────────────────────────────┐    │   │
    │  │  │  Namespace                              │    │   │
    │  │  │  NetworkPolicy, ResourceQuota           │    │   │
    │  │  │                                         │    │   │
    │  │  │  ┌─────────────────────────────────┐    │    │   │
    │  │  │  │  Pod                            │    │    │   │
    │  │  │  │  SecurityContext, Seccomp,      │    │    │   │
    │  │  │  │  AppArmor                       │    │    │   │
    │  │  │  │                                 │    │    │   │
    │  │  │  │  ┌─────────────────────────┐    │    │    │   │
    │  │  │  │  │  Container (innermost)  │    │    │    │   │
    │  │  │  │  │  read-only rootfs       │    │    │    │   │
    │  │  │  │  │  non-root user          │    │    │    │   │
    │  │  │  │  │  dropped capabilities   │    │    │    │   │
    │  │  │  │  └─────────────────────────┘    │    │    │   │
    │  │  │  └─────────────────────────────────┘    │    │   │
    │  │  └─────────────────────────────────────────┘    │   │
    │  └─────────────────────────────────────────────────┘   │
    └────────────────────────────────────────────────────────┘

    Secrets Management (cross-cutting concern):
    ┌──────────────────────────────────────────────┐
    │                                              │
    │  External Secrets ──▶ K8s Secret ──▶ Pod     │
    │       │                                      │
    │  Vault / AWS SM / GCP SM                     │
    │  (source of truth)                           │
    │                                              │
    │  Cuts across ALL rings above                 │
    └──────────────────────────────────────────────┘
```

---

## Part 6: Scaling (Chapters 30-33)

**The Scaling Cascade — metrics to machines.**

```mermaid
flowchart TD
    M["Metrics<br>(CPU, memory, custom)"]
    M --> HPA["HPA"]
    HPA -->|"scale pods<br>horizontally"| Pods["More Pods"]
    HPA -->|"pods go Pending<br>(no capacity)"| KCA["Karpenter /<br>Cluster Autoscaler"]
    KCA -->|"scale nodes"| Cloud["Cloud API<br>(provision new VMs)"]

    subgraph vpa ["VPA (Vertical Pod Autoscaler)"]
        direction LR
        VM["Metrics"] --> VPA2["VPA"] --> Resize["Resize pods vertically<br>(adjust requests/limits)"]
    end

    subgraph scheduling ["Resource Tuning feeds Scheduling"]
        direction LR
        RL["requests and limits<br>(CPU, memory)"] --> Sched["Scheduler decisions"]
        RL --> Effects["Affects bin-packing,<br>QoS class, eviction<br>priority, HPA thresholds"]
    end
```

---

## Part 7: Platform Engineering (Chapters 34-39)

**The Platform — abstraction over infrastructure.**

```mermaid
flowchart TD
    Dev["Developer"] -->|writes Claim| PlatAPI["Platform API<br>(Crossplane XRD / CRD)"]
    PlatAPI -->|provisions| CloudRes["Cloud Resources<br>(RDS, S3, etc.)"]

    Git["Git Repo<br>(source of truth)"] -->|GitOps loop| Argo["ArgoCD / Flux"]
    Argo -->|sync| Clusters["Cluster(s)"]

    subgraph ext ["Extension Mechanism"]
        direction LR
        CRD["CRD<br>(defines new API)"] --> Operator["Operator<br>(watches & reconciles)"] --> Resources["Manages resources"]
    end

    subgraph horiz ["Horizontal Concerns"]
        MC["Multi-Cluster<br>(fleet mgmt, federation)"]
        MT["Multi-Tenancy<br>(namespaces, vClusters,<br>resource quotas)"]
    end
```

---

## Part 8: Advanced Topics (Chapters 40-45)

**Running it for Real.**

```
    Operational Concerns:
    ┌──────────────────────────────────────────────────────┐
    │                                                      │
    │  ┌──────────┐  ┌────────────────┐  ┌─────────────┐   │
    │  │ etcd ops │  │ Disaster       │  │ Cost        │   │
    │  │ (backup, │  │ Recovery       │  │ Optimization│   │
    │  │  defrag, │  │ (Velero)       │  │ (right-size,│   │
    │  │  health) │  │                │  │  spot, idle)│   │
    │  └──────────┘  │ backup ──▶     │  └─────────────┘   │
    │                │ restore ──▶    │                    │
    │                │ migrate        │                    │
    │                └────────────────┘                    │
    └──────────────────────────────────────────────────────┘

    Observability (the three pillars):
            ┌───────────┐
            │  Metrics  │
            │(Prometheus│
            │ / Mimir)  │
            └─────┬─────┘
                  │
        ┌─────────┼─────────┐
        │         │         │
        ▼         ▼         ▼
    ┌───────┐ ┌───────┐ ┌────────┐
    │ Logs  │ │Traces │ │Alerts  │
    │(Loki) │ │(Tempo)│ │(Grafana│
    └───────┘ └───────┘ │ / PD)  │
                        └────────┘

    GPU Scheduling:
    ┌──────────────────┐     ┌──────────────────┐     ┌────────────┐
    │  Pod with        │────▶│  Device Plugin / │────▶│ NVIDIA GPU │
    │  gpu request     │     │  DRA             │     │ (on node)  │
    │  (limits:        │     │  (allocates GPU) │     │            │
    │   nvidia.com/gpu)│     └──────────────────┘     └────────────┘
    └──────────────────┘

    LLM Serving:
    ┌─────────┐    ┌──────────────┐    ┌──────────┐    ┌────────────┐
    │ Model   │───▶│ vLLM / TGI   │───▶│ KServe   │───▶│ Inference  │
    │(weights)│    │ (serving     │    │ (routing,│    │ endpoint   │
    │         │    │  engine)     │    │  scaling)│    │ (/predict) │
    └─────────┘    └──────────────┘    └──────────┘    └────────────┘
```

---

*Back to [Table of Contents](00-README.md)*

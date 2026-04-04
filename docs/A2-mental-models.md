# Appendix B: Mental Models

Each part of this book introduces a cluster of related concepts. These diagrams show how they connect — use them as maps when navigating the chapters.

---

## Part 1: First Principles (Chapters 1-9)

**The Reconciliation Loop — the heart of Kubernetes.**

```
  User writes YAML
        │
        ▼
   ┌─────────┐       ┌────────────┐       ┌───────┐
   │ kubectl  │──────▶│ API Server │──────▶│ etcd  │
   └─────────┘       └─────┬──────┘       └───────┘
                            │                  ▲
                    ┌───────┴───────┐          │
                    │               │    (desired state
                    ▼               ▼     stored here)
            ┌──────────────┐ ┌───────────┐
            │  Controller  │ │ Scheduler │
            │   Manager    │ │ (assign   │
            │ (reconcile)  │ │  to node) │
            └──────┬───────┘ └─────┬─────┘
                   │               │
                   └───────┬───────┘
                           │
                           ▼
              ┌─────────────────────┐
              │   kubelet (on node) │
              └──────────┬──────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │  Container Runtime  │
              └──────────┬──────────┘
                         │
                         ▼
              ┌─────────────────────┐
              │     Container       │
              └─────────────────────┘

    ┌──────────────────────────────────────────────┐
    │          The Watch / Reconciliation Loop      │
    │                                              │
    │  Controller watches ──▶ detects drift        │
    │       │                     │                │
    │       │              compares desired         │
    │       │              vs. actual state         │
    │       │                     │                │
    │       └──── takes action ◀──┘                │
    │             to converge                      │
    └──────────────────────────────────────────────┘
```

---

## Part 2: Tooling Evolution (Chapters 10-14)

**The Stack — what runs on what.**

```
    ┌─────────────────────────────────────────┐
    │             Application                 │
    ├─────────────────────────────────────────┤
    │     Helm / Kustomize  (packaging)       │
    ├─────────────────────────────────────────┤
    │     kubeadm / k3s     (bootstrap)       │
    ├─────────────────────────────────────────┤
    │          Kubernetes API                  │
    ├───────────────────┬─────────────────────┤
    │  Container Runtime│    CNI Plugin       │
    │  containerd /     │  (Cilium, Calico,   │
    │  CRI-O            │   Flannel ...)      │
    ├───────────────────┴─────────────────────┤
    │       OCI Runtime  (runc)               │
    ├─────────────────────────────────────────┤
    │           Linux Kernel                  │
    │     ┌───────────┐  ┌────────────┐       │
    │     │  cgroups   │  │ namespaces │       │
    │     │ (resource  │  │ (isolation)│       │
    │     │  limits)   │  │            │       │
    │     └───────────┘  └────────────┘       │
    └─────────────────────────────────────────┘

    CNI plugs in here ─────────────────┐
    to provide pod networking:         │
                                       ▼
    Pod A ◀──── CNI virtual network ────▶ Pod B
```

---

## Part 3: Practical Setup (Chapters 15-19)

**Your First Cluster — who talks to whom.**

```
                        ┌───────────────┐
                        │ Cloud Provider│
                        │  (AWS/GCP/AZ) │
                        └───────┬───────┘
                                │
                                ▼
                  ┌─────────────────────────┐
                  │           VPC           │
                  │                         │
                  │  ┌───────────────────┐  │
                  │  │   Control Plane   │  │
                  │  │    (managed)      │  │
                  │  │  ┌─────────────┐  │  │
                  │  │  │ API Server  │◀─┼──┼──── kubectl
                  │  │  └─────────────┘  │  │
                  │  └───────────────────┘  │        ┌─────────────┐
                  │                         │◀───────│ CI/CD       │
                  │  ┌───────────────────┐  │        │ Pipeline    │
                  │  │   Worker Node 1   │  │        └─────────────┘
                  │  │ ┌───────────────┐ │  │
                  │  │ │  Pod          │ │  │
                  │  │ │ ┌───┐ ┌─────┐│ │  │
                  │  │ │ │app│ │side-││ │  │
                  │  │ │ │   │ │car  ││ │  │
                  │  │ │ └───┘ └─────┘│ │  │
                  │  │ └───────────────┘ │  │
                  │  └───────────────────┘  │
                  │                         │
                  │  ┌───────────────────┐  │
                  │  │   Worker Node 2   │  │
                  │  │ ┌───────────────┐ │  │
                  │  │ │  Pod     Pod  │ │  │
                  │  │ └───────────────┘ │  │
                  │  └───────────────────┘  │
                  └─────────────────────────┘

    Debugging tools point at pods:
    ┌────────────┐
    │ kubectl    │──▶  logs
    │            │──▶  exec
    │            │──▶  describe (events)
    └────────────┘
```

---

## Part 4: Stateful Workloads (Chapters 20-24)

**State — the hard problem.**

```
    ┌──────────────────────┐    ┌──────────────────────────┐
    │     Deployment       │    │      StatefulSet          │
    │  (stateless)         │    │  (ordered, stable ID)     │
    │                      │    │                          │
    │  Pods are fungible,  │    │  pod-0, pod-1, pod-2    │
    │  interchangeable     │    │  each has stable name    │
    └──────────────────────┘    └────────────┬─────────────┘
                                             │
                                             ▼
                                    ┌────────────────┐
                                    │      PVC       │
                                    │ (claim storage) │
                                    └───────┬────────┘
                                            │
                                            ▼
                                    ┌────────────────┐
                                    │       PV       │
                                    │ (actual volume) │
                                    └───────┬────────┘
                                            │
                                            ▼
                                    ┌────────────────┐
                                    │ StorageClass   │
                                    │ (provisioner)  │
                                    └───────┬────────┘
                                            │
                                            ▼
                                    ┌────────────────┐
                                    │   Cloud Disk   │
                                    │  (EBS/PD/AzD)  │
                                    └────────────────┘

    ┌──────────────────────────────────────────────────┐
    │  Operators manage databases on Kubernetes:       │
    │                                                  │
    │  Operator ──▶ watches CRD ──▶ manages            │
    │               (e.g. PostgresCluster)             │
    │                   StatefulSet + PVCs + Secrets   │
    └──────────────────────────────────────────────────┘

    Jobs & CronJobs (separate branch):
    ┌───────────┐       ┌────────────┐
    │   Job     │       │  CronJob   │
    │ (run once)│       │ (scheduled)│──▶ creates Job on schedule
    └───────────┘       └────────────┘
```

---

## Part 5: Security (Chapters 25-29)

**Defense in Depth.**

```
    ┌─────────────────────────────────────────────────────────┐
    │  Supply Chain (outermost ring)                          │
    │  Sigstore, SBOM, image scanning                        │
    │                                                         │
    │  ┌─────────────────────────────────────────────────┐   │
    │  │  Cluster                                        │   │
    │  │  RBAC, Admission Control (OPA/Kyverno)          │   │
    │  │                                                 │   │
    │  │  ┌─────────────────────────────────────────┐   │   │
    │  │  │  Namespace                              │   │   │
    │  │  │  NetworkPolicy, ResourceQuota           │   │   │
    │  │  │                                         │   │   │
    │  │  │  ┌─────────────────────────────────┐   │   │   │
    │  │  │  │  Pod                            │   │   │   │
    │  │  │  │  SecurityContext, Seccomp,      │   │   │   │
    │  │  │  │  AppArmor                       │   │   │   │
    │  │  │  │                                 │   │   │   │
    │  │  │  │  ┌─────────────────────────┐   │   │   │   │
    │  │  │  │  │  Container (innermost)  │   │   │   │   │
    │  │  │  │  │  read-only rootfs       │   │   │   │   │
    │  │  │  │  │  non-root user          │   │   │   │   │
    │  │  │  │  │  dropped capabilities   │   │   │   │   │
    │  │  │  │  └─────────────────────────┘   │   │   │   │
    │  │  │  └─────────────────────────────────┘   │   │   │
    │  │  └─────────────────────────────────────────┘   │   │
    │  └─────────────────────────────────────────────────┘   │
    └─────────────────────────────────────────────────────────┘

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

```
    ┌──────────┐
    │ Metrics  │  (CPU, memory, custom metrics)
    └────┬─────┘
         │
         ▼
    ┌──────────┐     scale pods         ┌──────────────┐
    │   HPA    │────horizontally───────▶│  More Pods   │
    └────┬─────┘                        └──────────────┘
         │
         │ pods go Pending
         │ (no capacity)
         ▼
    ┌────────────────────┐  scale nodes  ┌──────────────┐
    │ Karpenter /        │──────────────▶│  Cloud API   │
    │ Cluster Autoscaler │               │ (provision   │
    └────────────────────┘               │  new VMs)    │
                                         └──────────────┘

    ┌────────────────────────────────────────────────┐
    │  Side branch: VPA (Vertical Pod Autoscaler)    │
    │                                                │
    │  Metrics ──▶ VPA ──▶ resize pods vertically    │
    │                      (adjust requests/limits)  │
    └────────────────────────────────────────────────┘

    Resource Tuning feeds into scheduling:
    ┌───────────────────┐       ┌─────────────┐
    │ requests & limits │──────▶│  Scheduler  │
    │ (CPU, memory)     │       │  decisions  │
    └───────────────────┘       └─────────────┘
         │
         └──▶ Affects bin-packing, QoS class,
              eviction priority, HPA thresholds
```

---

## Part 7: Platform Engineering (Chapters 34-39)

**The Platform — abstraction over infrastructure.**

```
    ┌────────────┐                ┌────────────────────────┐
    │ Developer  │                │      Git Repo          │
    │            │                │  (source of truth)     │
    └─────┬──────┘                └───────────┬────────────┘
          │                                   │
          │ writes Claim                      │ GitOps loop
          ▼                                   ▼
    ┌────────────────┐              ┌──────────────────┐
    │  Platform API  │              │     ArgoCD /     │
    │  (Crossplane   │              │     Flux         │
    │   XRD / CRD)   │              └────────┬─────────┘
    └───────┬────────┘                       │
            │                                │ sync
            │ provisions                     ▼
            ▼                       ┌──────────────────┐
    ┌────────────────┐              │    Cluster(s)    │
    │ Cloud Resources│              └──────────────────┘
    │ (RDS, S3, etc.)│
    └────────────────┘

    ┌──────────────────────────────────────────────────────┐
    │  Extension Mechanism:                                │
    │                                                      │
    │  CRD ──▶ Operator (controller) ──▶ manages resources │
    │  (defines new API)  (watches & reconciles)           │
    └──────────────────────────────────────────────────────┘

    Horizontal concerns:
    ┌─────────────────┐    ┌───────────────────┐
    │  Multi-Cluster  │    │  Multi-Tenancy    │
    │  (fleet mgmt,   │    │  (namespaces,     │
    │   federation)   │    │   vClusters,      │
    │                 │    │   resource quotas) │
    └─────────────────┘    └───────────────────┘
```

---

## Part 8: Advanced Topics (Chapters 40-45)

**Running it for Real.**

```
    Operational Concerns:
    ┌──────────────────────────────────────────────────────┐
    │                                                      │
    │  ┌──────────┐  ┌────────────────┐  ┌─────────────┐  │
    │  │ etcd ops │  │ Disaster       │  │ Cost        │  │
    │  │ (backup, │  │ Recovery       │  │ Optimization│  │
    │  │  defrag, │  │ (Velero)       │  │ (right-size,│  │
    │  │  health) │  │                │  │  spot, idle)│  │
    │  └──────────┘  │ backup ──▶     │  └─────────────┘  │
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
    └───────┘ └───────┘ │ / PD) │
                        └────────┘

    GPU Scheduling:
    ┌──────────────────┐     ┌─────────────────┐     ┌────────────┐
    │  Pod with        │────▶│  Device Plugin / │────▶│ NVIDIA GPU │
    │  gpu request     │     │  DRA             │     │ (on node)  │
    │  (limits:        │     │  (allocates GPU) │     │            │
    │   nvidia.com/gpu)│     └─────────────────┘     └────────────┘
    └──────────────────┘

    LLM Serving:
    ┌───────┐    ┌──────────────┐    ┌─────────┐    ┌────────────┐
    │ Model │───▶│ vLLM / TGI   │───▶│ KServe  │───▶│ Inference  │
    │(weights)   │ (serving     │    │ (routing,│    │ endpoint   │
    │            │  engine)     │    │  scaling)│    │ (/predict) │
    └───────┘    └──────────────┘    └─────────┘    └────────────┘
```

---

*Back to [Table of Contents](README.md)*

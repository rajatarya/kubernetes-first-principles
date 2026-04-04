# Chapter 41: GPU Workloads and AI/ML on Kubernetes

Kubernetes was built to orchestrate stateless web services. GPUs were built to render triangles and multiply matrices. Bringing these two worlds together required years of extension work --- device plugins, operator stacks, specialized schedulers, and high-speed networking --- because none of the original Kubernetes abstractions anticipated hardware accelerators. This chapter covers the full GPU infrastructure stack from first principles: how GPUs are exposed to the scheduler, how they are shared, how training jobs are orchestrated, and how to avoid burning money on idle accelerators.

## The Device Plugin Framework

Kubernetes has no native understanding of GPUs. It knows about CPU (millicores), memory (bytes), ephemeral storage, and hugepages. Everything else enters through the **device plugin framework**, a gRPC-based extension point introduced in Kubernetes 1.8. In [Chapter 3](03-architecture.md), we described the kubelet as a single-responsibility agent that converts API state into running containers. The device plugin framework extends the kubelet's vocabulary beyond CPU and memory, letting it manage hardware it was never designed to know about.

### How It Works

A device plugin is a process (usually running as a DaemonSet on every GPU node) that implements three gRPC services:

1. **Registration**: The plugin connects to the kubelet's Registration service at `/var/lib/kubelet/device-plugins/kubelet.sock` and announces a resource name (e.g., `nvidia.com/gpu`).

2. **ListAndWatch**: The kubelet calls `ListAndWatch` on the plugin. The plugin returns a stream of device IDs --- one per physical GPU (or virtual slice). If a GPU fails or is removed, the plugin sends an updated list. The kubelet forwards this inventory to the API server, which stores it in the Node's `.status.capacity` and `.status.allocatable` fields.

3. **Allocate**: When the scheduler places a pod requesting `nvidia.com/gpu: 1` on this node, the kubelet calls `Allocate` with the chosen device ID. The plugin returns the environment variables, device mounts, and annotations needed to make the GPU visible inside the container (e.g., `/dev/nvidia0`, the NVIDIA device files, and `NVIDIA_VISIBLE_DEVICES`).

```
DEVICE PLUGIN REGISTRATION AND ALLOCATION FLOW
────────────────────────────────────────────────

  GPU Node
  ┌──────────────────────────────────────────────────────────┐
  │                                                          │
  │  ┌─────────────────┐     1. Register("nvidia.com/gpu")  │
  │  │  NVIDIA Device   │────────────────────────────────►   │
  │  │  Plugin (Pod)    │                                    │
  │  │                  │◄───── 2. ListAndWatch() ────────   │
  │  │  Reports:        │     Plugin streams device IDs:     │
  │  │  GPU-0, GPU-1,   │     {GPU-0, GPU-1, GPU-2, GPU-3}  │
  │  │  GPU-2, GPU-3    │                                    │
  │  │                  │◄───── 4. Allocate(GPU-2) ────────  │
  │  │                  │─────► Returns:                     │
  │  │                  │       - /dev/nvidia2               │
  │  │                  │       - NVIDIA_VISIBLE_DEVICES=2   │
  │  │                  │       - volume mounts              │
  │  └─────────────────┘                                    │
  │                          ┌──────────────┐               │
  │                          │   kubelet     │               │
  │                          │              │               │
  │                          │  3. Updates   │               │
  │                          │  Node status: │               │
  │                          │  capacity:    │               │
  │                          │   nvidia.com/ │               │
  │                          │   gpu: 4      │               │
  │                          └──────┬───────┘               │
  │                                 │                        │
  └─────────────────────────────────┼────────────────────────┘
                                    │
                                    ▼
                           ┌────────────────┐
                           │  API Server     │
                           │                 │
                           │  Node object    │
                           │  .status:       │
                           │   allocatable:  │
                           │    nvidia.com/  │
                           │    gpu: 4       │
                           └────────────────┘
```

### Critical Constraints

The device plugin model has several hard limitations that shape everything downstream:

- **Integer-only quantities.** You request `nvidia.com/gpu: 1` or `nvidia.com/gpu: 2`. There is no `nvidia.com/gpu: 0.5`. Fractional GPUs do not exist in this model.
- **Non-sharable.** A GPU allocated to one pod is exclusively allocated. Two pods cannot share the same device ID through the standard device plugin.
- **Not overcommittable.** Unlike CPU, which can be overcommitted (requests < limits), GPU counts are absolute. If a node has 4 GPUs and 4 are allocated, a fifth pod cannot be scheduled there.
- **No memory management.** Kubernetes has no visibility into GPU memory. There is no equivalent of `resources.limits.memory` for GPU VRAM. A pod requesting `nvidia.com/gpu: 1` gets the full physical GPU, whether it uses 1 GB or 80 GB of its VRAM.

These constraints are why MIG, MPS, time-slicing, and ultimately DRA were created.

## The NVIDIA GPU Operator

Installing GPU drivers on bare metal is annoying. Installing GPU drivers on every node in a Kubernetes cluster, keeping them in sync with the CUDA toolkit version, ensuring the container runtime is configured correctly, and monitoring GPU health across hundreds of nodes --- that is an operational nightmare. The [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/overview.html) solves this by packaging the entire GPU software stack as Kubernetes-native operators and containerized components.

### The Eight Components

| Component | Function |
|---|---|
| **Node Feature Discovery (NFD)** | Labels nodes with hardware capabilities (PCI vendor IDs, CPU features). The GPU stack depends on NFD labels to identify GPU nodes. |
| **GPU Driver Container** | Runs the NVIDIA kernel driver *inside a container*, compiled for the host's kernel version. No host-level driver installation needed. |
| **NVIDIA Container Toolkit** | Configures the container runtime (containerd/CRI-O) to expose GPUs to containers. Installs the `nvidia-container-runtime` hook. |
| **Device Plugin** | The gRPC device plugin described above. Reports GPUs to the kubelet. |
| **GPU Feature Discovery (GFD)** | Labels nodes with GPU-specific metadata: model (`nvidia.com/gpu.product=NVIDIA-A100-SXM4-80GB`), driver version, CUDA version, MIG capabilities. |
| **DCGM Exporter** | Exposes GPU metrics (utilization, temperature, memory usage, ECC errors, power draw) as Prometheus metrics. |
| **MIG Manager** | Configures Multi-Instance GPU partitioning on supported hardware (A100, H100, H200). Applies MIG profiles via node labels. |
| **Operator Validator** | Runs post-installation validation to confirm the entire stack is functional. Reports status as conditions on the ClusterPolicy CRD. |

### The Modern Stack (2025-2026)

NVIDIA announced the evolution of the GPU management stack at KubeCon 2026:

**GPU Operator** --> **DRA Driver** --> **KAI Scheduler**

The GPU Operator now ships a DRA driver (replacing the legacy device plugin path) that exposes GPUs through the Dynamic Resource Allocation API. The [KAI Scheduler](https://github.com/NVIDIA/KAI-Scheduler) is a topology-aware GPU scheduler that understands NVLink domains, MIG slices, and multi-node placement. This trio is the direction all production GPU infrastructure is heading.

## GPU Sharing and Multi-Tenancy

A single H100 has 80 GB of HBM3 memory and massive compute throughput. Running a small inference model that uses 2 GB of VRAM on a dedicated H100 wastes 97.5% of the memory. GPU sharing exists to solve this economics problem.

### Three Approaches

```
GPU SHARING MODELS
──────────────────

  MULTI-INSTANCE GPU (MIG)            MULTI-PROCESS SERVICE (MPS)
  Hardware Partitioning               Software Space Partitioning
  ┌──────────────────────┐            ┌──────────────────────┐
  │     Physical GPU      │            │     Physical GPU      │
  │  ┌─────┬─────┬─────┐ │            │                       │
  │  │ MIG │ MIG │ MIG │ │            │  ┌───┐ ┌───┐ ┌───┐  │
  │  │Inst │Inst │Inst │ │            │  │P1 │ │P2 │ │P3 │  │
  │  │ 0   │ 1   │ 2   │ │            │  │   │ │   │ │   │  │
  │  │     │     │     │ │            │  │30%│ │50%│ │20%│  │
  │  │1g.  │1g.  │1g.  │ │            │  │   │ │   │ │   │  │
  │  │10gb │10gb │10gb │ │            │  └───┘ └───┘ └───┘  │
  │  ├─────┼─────┼─────┤ │            │   Shared CUDA Context │
  │  │Own  │Own  │Own  │ │            │   Explicit memory     │
  │  │SM   │SM   │SM   │ │            │   and compute limits  │
  │  │+Mem │+Mem │+Mem │ │            │   per process         │
  │  └─────┴─────┴─────┘ │            └──────────────────────┘
  └──────────────────────┘
                                       TIME-SLICING
  Isolated compute engines,            CUDA Context Switching
  memory controllers, and              ┌──────────────────────┐
  cache partitions.                    │     Physical GPU      │
  Fault isolation: yes.                │                       │
  Memory isolation: yes.               │  ┌──────────────────┐│
                                       │  │ Time T1: Pod A   ││
                                       │  ├──────────────────┤│
                                       │  │ Time T2: Pod B   ││
                                       │  ├──────────────────┤│
                                       │  │ Time T3: Pod C   ││
                                       │  └──────────────────┘│
                                       │  Round-robin context  │
                                       │  switching. All pods  │
                                       │  see full GPU memory. │
                                       │  No memory isolation. │
                                       └──────────────────────┘
```

**Multi-Instance GPU (MIG)** partitions a physical GPU at the hardware level. On an A100-80GB, you can create up to 7 instances, each with dedicated streaming multiprocessors, memory controllers, and L2 cache. Profiles include `1g.5gb` (1 compute slice, 5 GB), `2g.10gb`, `3g.20gb`, `4g.40gb`, and `7g.80gb`. MIG provides true fault and memory isolation. One instance cannot see another's memory, and a CUDA crash in one instance does not affect others.

**Multi-Process Service (MPS)** is a software-level sharing mechanism. An MPS server sits between CUDA clients and the GPU, multiplexing access. You can set explicit per-client limits: `CUDA_MPS_PINNED_DEVICE_MEM_LIMIT=0=4096M` caps a process to 4 GB. MPS allows concurrent kernel execution (true parallelism on the SM level) but lacks the hard isolation of MIG.

**Time-Slicing** is the simplest approach. The NVIDIA device plugin is configured to advertise more "GPUs" than physically exist (e.g., 4 physical GPUs advertised as 16 time-sliced replicas). CUDA contexts are switched in round-robin fashion. There is no memory isolation --- all pods see the full VRAM and can OOM-kill each other. Context switching adds latency overhead.

### When to Use Each

| Scenario | Recommended Approach | Rationale |
|---|---|---|
| Production inference with SLAs | MIG | Hard isolation, predictable performance |
| Development and experimentation | Time-slicing | Simple setup, maximum flexibility |
| Batch inference pipelines | MPS | Concurrent execution, configurable limits |
| Multi-tenant cluster, untrusted workloads | MIG | Fault isolation between tenants |
| Cost optimization, trusted workloads | Time-slicing or MPS | Maximize utilization |

## Dynamic Resource Allocation (DRA)

The device plugin framework served its purpose for seven years, but its count-based model hit a wall as GPU infrastructure grew more complex. You cannot express "give me a MIG slice with 20 GB of memory on a GPU that has NVLink connectivity to another GPU already allocated to this pod" with `nvidia.com/gpu: 1`.

### Why Device Plugins Were Insufficient

1. **Count-based only.** No way to parameterize requests (memory size, compute capability, MIG profile).
2. **No sharing semantics.** Two pods cannot request access to the same physical device.
3. **No topology awareness.** No way to express "these two GPUs must be on the same NVLink domain."
4. **No scheduling integration.** Device allocation happens at the kubelet level, after scheduling. The scheduler has no visibility into device topology.
5. **Vendor-locked plugin logic.** All allocation intelligence is inside the vendor's plugin binary.

### The DRA Model

DRA, graduating to GA in Kubernetes 1.34-1.35, introduces a structured, parameterized model for hardware allocation.

```
DEVICE PLUGIN MODEL vs DRA MODEL
─────────────────────────────────

  DEVICE PLUGIN (Legacy)                DRA (Modern)
  ──────────────────────                ────────────

  Pod spec:                             Pod spec:
    resources:                            resourceClaims:
      limits:                               - name: gpu
        nvidia.com/gpu: 1                     resourceClaimTemplateName: gpu-claim

  That's it. Count only.                ResourceClaimTemplate:
  No parameters.                          spec:
  No sharing.                               devices:
  No topology.                                requests:
                                              - name: gpu
                                                deviceClassName: gpu.nvidia.com
                                                selectors:
                                                - cel:
                                                    expression: >
                                                      device.attributes["gpu.nvidia.com"]
                                                      .productName == "H100" &&
                                                      device.attributes["gpu.nvidia.com"]
                                                      .memory.isGreaterThan(
                                                        quantity("40Gi"))

  ┌─────────┐  count=1  ┌────────┐     ┌─────────┐ claim  ┌────────────┐
  │   Pod    │─────────►│ kubelet │     │   Pod    │──────►│ Scheduler  │
  │         │          │ picks  │     │         │       │ evaluates  │
  │         │          │ any    │     │         │       │ CEL exprs, │
  │         │          │ GPU    │     │         │       │ topology,  │
  └─────────┘          └────────┘     └─────────┘       │ sharing    │
                                                         └────────────┘
                                                               │
                                                         ┌─────▼──────┐
                                                         │ DRA Driver │
                                                         │ prepares   │
                                                         │ device     │
                                                         └────────────┘
```

### The Four API Objects

| Object | Purpose |
|---|---|
| **ResourceSlice** | Published by the DRA driver. Describes available devices on a node: attributes, capacity, topology. The scheduler reads these to make placement decisions. |
| **DeviceClass** | Cluster-scoped. Defines a class of devices with admin-set constraints and configuration. Example: `gpu.nvidia.com` class might set a default MIG profile. |
| **ResourceClaim** | Namespace-scoped. A pod's request for a device, with CEL-based selectors. Allocated by the scheduler, bound to specific devices. |
| **ResourceClaimTemplate** | Creates ResourceClaims per pod, like PVCs from PVC templates in StatefulSets. |

CEL selector expressions can match on any device attribute: product name, memory size, MIG capability, driver version, NUMA node, NVLink group. You can express prioritized alternatives ("prefer H100, accept A100") and device sharing ("this claim can share a device with that claim").

NVIDIA [donated their DRA driver to the CNCF](https://github.com/NVIDIA/k8s-dra-driver) at KubeCon 2026, making it a vendor-neutral component of the ecosystem.

## ML Training on Kubernetes

Training a large model is a distributed systems problem. A single GPU can handle fine-tuning a 7B model. Training a 70B model from scratch requires hundreds of GPUs coordinated across dozens of nodes, all processing data in lockstep. Kubernetes needs specialized operators and schedulers to manage these workloads.

### Training Operators

**Kubeflow Training Operator** provides CRDs for distributed training frameworks:

- `PyTorchJob`: Launches distributed PyTorch with `torchrun`. Configures `MASTER_ADDR`, `MASTER_PORT`, `WORLD_SIZE`, and `RANK` automatically.
- `TFJob`: TensorFlow distributed training with PS/Worker topology.
- `MPIJob`: MPI-based training (Horovod). Launches an MPI ring with SSH between pods.
- `TrainJob` (v2): The unified API that abstracts framework details behind a single CRD. Specify a model, dataset, and training runtime; the operator generates the correct distributed topology.

**KubeRay** is the Kubernetes operator for [Ray](https://ray.io), the distributed compute framework used by OpenAI for ChatGPT training infrastructure. It provides:

- `RayCluster`: A persistent Ray cluster with head and worker nodes.
- `RayJob`: Submits a job to a RayCluster (or creates an ephemeral one).
- `RayService`: Serves Ray Serve deployments with rolling upgrades.

Ray's advantage is its unified API for training, tuning, and serving. A single Ray program can orchestrate data preprocessing, distributed training with PyTorch, hyperparameter tuning, and model serving.

### Gang Scheduling

Standard Kubernetes scheduling is pod-by-pod. For a distributed training job requiring 64 GPUs across 8 nodes, the default scheduler might place 7 pods and then get stuck waiting for the 8th. Those 7 pods sit idle, burning GPU-hours, waiting for a resource that may not free up for hours.

**Gang scheduling** (all-or-nothing scheduling) ensures that either all pods in a job are scheduled simultaneously, or none are. [Volcano](https://volcano.sh) is the primary gang scheduler for Kubernetes. It introduces:

- `Job` CRD with `minAvailable` (minimum pods required to start).
- Queue-based scheduling with fair-sharing across teams.
- Preemption policies for priority-based scheduling.

### Job Queuing with Kueue

[Kueue](https://kueue.sigs.k8s.io) is the Kubernetes-native job queuing system. While Volcano is a full scheduler replacement, Kueue works *with* the default scheduler, adding queuing and quota semantics on top.

Core concepts:

- **ClusterQueue**: Defines a pool of resources (e.g., 100 GPUs, 200 CPUs) with borrowing limits.
- **LocalQueue**: Namespace-scoped queue that points to a ClusterQueue. Users submit jobs here.
- **ResourceFlavor**: Describes a class of nodes (e.g., `a100-spot`, `h100-ondemand`). Maps to node labels.
- **Cohort borrowing**: ClusterQueues in the same cohort can borrow unused resources from each other. Team A's unused GPU quota flows to Team B automatically.

**Kueue vs Volcano**: Use Kueue when you need multi-tenant quota management and work with the default scheduler. Use Volcano when you need a full scheduler replacement with gang scheduling, preemption, and topology-aware placement. Many production clusters use both: Kueue for queuing and quota, Volcano for gang scheduling.

## Networking for Distributed Training

Distributed training spends a significant fraction of total time on communication. After each forward/backward pass, gradients must be synchronized across all workers (AllReduce). On a 1000-GPU training run, the network is the bottleneck.

### Why Standard TCP Is Insufficient

Standard TCP networking (Pod-to-Pod via CNI) adds multiple copies and context switches per message:

1. GPU memory --> CPU memory (PCIe DMA)
2. CPU memory --> kernel socket buffer
3. Kernel --> NIC (TCP/IP stack processing, segmentation)
4. Network transit
5. NIC --> kernel socket buffer --> CPU memory --> GPU memory (reverse path)

For a 70B parameter model with fp16 gradients, each AllReduce exchanges ~140 GB of data. Over standard 25 Gbps Ethernet with TCP, this gradient sync alone takes minutes. Real-world benchmarks show: **standard TCP can make a training run take 5 hours that completes in 1h40m with GPUDirect RDMA**.

```
GPU-TO-GPU COMMUNICATION PATHS
───────────────────────────────

  STANDARD TCP (SLOW)
  ┌──────┐  PCIe  ┌──────┐  TCP/IP  ┌──────┐  PCIe  ┌──────┐
  │ GPU  │──────►│ CPU  │────────►│ CPU  │──────►│ GPU  │
  │ Node │  copy │ RAM  │  stack  │ RAM  │  copy │ Node │
  │  A   │◄──────│      │◄────────│      │◄──────│  B   │
  └──────┘       └──────┘  NIC    └──────┘       └──────┘
  Copies: 4 (GPU→CPU, CPU→NIC, NIC→CPU, CPU→GPU)
  Latency: ~100μs+       Bandwidth: limited by TCP stack

  RDMA / RoCE (FAST)
  ┌──────┐  PCIe  ┌──────┐  RDMA   ┌──────┐  PCIe  ┌──────┐
  │ GPU  │──────►│ CPU  │ bypass │ CPU  │──────►│ GPU  │
  │ Node │  copy │ RAM  │────────►│ RAM  │  copy │ Node │
  │  A   │       └──────┘ no TCP └──────┘       │  B   │
  └──────┘       NIC does          NIC does     └──────┘
                 direct            direct
                 memory            memory
                 access            access
  Copies: 2 (GPU→CPU, CPU→GPU)
  Latency: ~2μs          Kernel bypass, zero-copy NIC

  GPUDirect RDMA (FASTEST)
  ┌──────┐         RDMA          ┌──────┐
  │ GPU  │──────────────────────►│ GPU  │
  │ Node │  NIC reads directly   │ Node │
  │  A   │  from GPU memory      │  B   │
  │      │◄──────────────────────│      │
  └──────┘  No CPU involved      └──────┘
  Copies: 0 (GPU memory → NIC → network → NIC → GPU memory)
  Latency: ~1μs          Maximum bandwidth, zero CPU overhead
```

### The Communication Stack

**NCCL** (NVIDIA Collective Communications Library) is the standard for multi-GPU collective operations (AllReduce, AllGather, Broadcast). NCCL automatically selects the fastest available transport: NVLink for intra-node, InfiniBand or RoCE for inter-node, falling back to TCP if nothing better exists.

**InfiniBand** provides the highest bandwidth (400 Gbps NDR) with sub-microsecond latency and native RDMA. Most large GPU clusters (DGX SuperPOD, etc.) use InfiniBand fabrics.

**RoCE** (RDMA over Converged Ethernet) provides RDMA semantics over standard Ethernet. Lower cost than InfiniBand, but requires lossless Ethernet configuration (PFC, ECN).

### NVIDIA Network Operator

The [NVIDIA Network Operator](https://docs.nvidia.com/networking/display/cokan10/network+operator) brings RDMA networking to Kubernetes:

- **Multus CNI**: Attaches multiple network interfaces to pods (one for standard traffic, one for RDMA).
- **SR-IOV Device Plugin**: Exposes SR-IOV Virtual Functions as schedulable resources (`nvidia.com/rdma_shared_device_a`).
- **RDMA Shared Device Plugin**: Enables RDMA device sharing across containers.
- **Host Device Network**: Passes InfiniBand/RoCE interfaces directly into pods.

A distributed training pod spec requests both GPUs and RDMA devices:

```yaml
resources:
  limits:
    nvidia.com/gpu: 8
    nvidia.com/rdma_shared_device_a: 1
```

## Cost Optimization for GPU Workloads

H100 instances cost $25-35/hour on-demand in major clouds. A 64-GPU training cluster burns $50,000-$70,000 per day. Cost optimization is not a nice-to-have; it is an engineering requirement.

### Spot/Preemptible GPU Instances

Cloud providers offer GPU instances at 60-80% discounts through spot/preemptible pricing. The tradeoff: instances can be reclaimed with 30-120 seconds notice. For training workloads with checkpointing (save state every N steps), this is viable. For inference with graceful draining, it works with proper pod disruption budgets.

### Karpenter with GPU Node Pools

[Karpenter](https://karpenter.sh) provisions right-sized nodes on demand. For GPU workloads, configure separate NodePools:

- **GPU NodePool**: Instance types restricted to GPU families (p5, p4d, g5). Spot pricing enabled. `SpotToSpotConsolidation` moves workloads between spot pools to maintain availability.
- **CPU NodePool**: Standard instances for non-GPU workloads. Prevents GPU nodes from being used for CPU-only pods.

### Scheduling: Bin-Packing

The default Kubernetes scheduler spreads pods across nodes. For GPU workloads, **bin-packing** is critical: fill GPU nodes completely before allocating new ones. A half-utilized 8-GPU node is a node you are paying full price for. Use `NodeResourcesFit` with `MostAllocated` scoring strategy, or Karpenter's consolidation to continuously pack workloads onto fewer nodes.

### The Full Cost Stack

1. **Spot instances** for fault-tolerant training (60-80% savings).
2. **GPU sharing** (MIG/MPS/time-slicing) for inference and dev workloads (2-7x utilization improvement).
3. **Bin-packing scheduling** to minimize partially-used nodes.
4. **Kueue quotas** to prevent teams from hoarding GPUs.
5. **Scale-to-zero** for inference endpoints with no traffic (via KServe or KEDA).
6. **Preemption policies** to let high-priority training preempt low-priority batch jobs.

## Common Mistakes and Misconceptions

- **"GPUs can be shared across pods like CPU."** By default, a GPU is allocated as a whole device to one pod. Sharing requires MIG (physical partitioning), MPS (time-sharing), or DRA (Dynamic Resource Allocation). Without these, a pod requesting 1 GPU gets exclusive access.
- **"Any Kubernetes node can schedule GPU workloads."** Nodes need the NVIDIA device plugin (or GPU Operator) installed, proper drivers, and the nvidia container runtime configured. Without this stack, K8s doesn't know GPUs exist.
- **"GPU requests and limits work like CPU."** You can only request whole GPUs (e.g., `nvidia.com/gpu: 1`). Fractional GPU requests require MIG or third-party tools. There are no GPU "millicores."
- **"Training and inference need the same infrastructure."** Training needs high-bandwidth interconnects (NVLink, InfiniBand), gang scheduling, and checkpointing. Inference needs low latency, autoscaling, and model serving frameworks. Different workloads, different architectures.

## Further Reading

- [NVIDIA GPU Operator Documentation](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/index.html) --- the complete guide to deploying and managing the GPU Operator, which automates driver installation, container runtime configuration, device plugin deployment, and GPU monitoring.
- [Device Plugins](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/device-plugins/) --- the official Kubernetes documentation on the device plugin framework, explaining how hardware vendors expose accelerators, FPGAs, and other devices to the kubelet.
- [Dynamic Resource Allocation KEP](https://github.com/kubernetes/enhancements/tree/master/keps/sig-node/4381-dra-structured-parameters) --- the Kubernetes Enhancement Proposal for DRA with structured parameters, replacing the opaque device plugin model with a richer, scheduler-integrated resource claim system.
- [NVIDIA Multi-Instance GPU User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/) --- how to partition A100 and H100 GPUs into isolated MIG instances with dedicated compute, memory, and cache, including supported profiles and configuration procedures.
- [Kubeflow Documentation](https://www.kubeflow.org/docs/) --- the full guide to the Kubeflow ML platform, covering pipelines, training operators (TFJob, PyTorchJob, MPIJob), model serving with KServe, and experiment tracking.
- [KubeRay Documentation](https://docs.ray.io/en/latest/cluster/kubernetes/index.html) --- deploying and managing Ray clusters on Kubernetes for distributed training, hyperparameter tuning, and Ray Serve inference workloads.
- [Volcano Scheduler](https://volcano.sh/en/docs/) --- documentation for the batch scheduling system designed for high-performance and ML workloads, supporting gang scheduling, fair-share queuing, and resource reservation.
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/index.html) --- the low-level runtime that makes GPUs accessible inside containers, including installation, configuration, and CDI (Container Device Interface) support.
- [NVIDIA GPU Operator Quickstart](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/getting-started.html) --- Hands-on guide to setting up GPU scheduling on Kubernetes

---

**Next:** [Chapter 42: Running LLMs on Kubernetes](42-llm-infrastructure.md)

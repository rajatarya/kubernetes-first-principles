# Chapter 42: Running LLMs on Kubernetes

Serving a large language model is not the same problem as serving a web application. A web app handles requests independently in milliseconds with megabytes of memory. An LLM loads 50-400 GB of weights into GPU memory, processes requests through billions of sequential matrix multiplications, generates tokens one at a time, and must manage a KV cache that grows with every token. The infrastructure required --- specialized inference servers, GPU-aware autoscaling, multi-node parallelism, model caching, and intelligent routing --- demands a purpose-built stack.

## ML Inference on Kubernetes

The inference server sits between Kubernetes and the GPU. It loads model weights, manages batching, handles tokenization, and exposes an API. Choosing the right one determines your throughput, latency, and cost.

### KServe

[KServe](https://kserve.github.io/website/) is the Kubernetes-native model serving framework. It provides a standard `InferenceService` CRD that abstracts away the inference runtime:

- **Autoscaling** with Knative (including scale-to-zero, so idle models release GPU nodes entirely).
- **Canary rollouts**: Route 10% of traffic to a new model version, monitor metrics, promote or roll back.
- **Multi-framework support**: TensorFlow, PyTorch, ONNX, XGBoost, Triton, vLLM, and custom containers.
- **Transformer/Predictor/Explainer pipeline**: Pre-process, predict, and post-process in a single InferenceService.

**KServe v0.16** introduced the `LLMInferenceService` CRD, purpose-built for large language models:

- OpenAI-compatible API endpoints out of the box (`/v1/chat/completions`, `/v1/completions`).
- Integration with Gateway API for traffic management.
- Distributed parallelism: define tensor parallelism and pipeline parallelism directly in the CRD spec.
- Backend support for vLLM, TGI, and SGLang.

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: LLMInferenceService
metadata:
  name: llama-3-70b
spec:
  modelId: meta-llama/Llama-3-70B-Instruct
  workerSpec:
    tensorParallelSize: 4
    resources:
      limits:
        nvidia.com/gpu: 4
```

### NVIDIA Triton (Dynamo Triton)

[Triton Inference Server](https://developer.nvidia.com/triton-inference-server) (now part of the NVIDIA Dynamo framework) is the most feature-rich inference server:

- **Multi-framework**: Load TensorRT, ONNX, PyTorch, TensorFlow, and Python models simultaneously.
- **Dynamic batching**: Accumulates requests for a configurable window (e.g., 50ms) and batches them into a single GPU kernel launch. Transforms 100 serial requests into 1 batched operation.
- **Model ensembles**: Chain multiple models (tokenizer --> encoder --> decoder --> post-processor) in a DAG with zero-copy tensor passing between stages.
- **Model repository**: Hot-load and unload models from S3/GCS/local storage without restarting.

### vLLM

[vLLM](https://docs.vllm.ai) changed LLM inference economics. Its two core innovations:

**PagedAttention**: Traditional inference servers pre-allocate a contiguous block of GPU memory for each request's KV cache, sized for the maximum sequence length. Most of this memory is wasted (a 2048-token allocation for a 200-token response wastes 90%). PagedAttention borrows the concept of virtual memory paging from operating systems: the KV cache is stored in non-contiguous physical blocks, mapped through a block table. Memory is allocated on demand as tokens are generated.

**Continuous batching**: Traditional batching waits for all requests in a batch to complete before accepting new ones. If one request generates 500 tokens and another generates 10, the short request's GPU cycles are wasted while waiting. Continuous batching (also called iteration-level scheduling) adds and removes requests from the batch at every decode step. The GPU is never idle.

Together, these deliver **up to 24x throughput improvement** over naive serving. Stripe reported a [73% cost reduction](https://stripe.com/blog) after migrating from a traditional serving stack to vLLM.

### Inference Server Comparison

| Feature | KServe + vLLM | Triton (Dynamo) | vLLM standalone |
|---|---|---|---|
| Autoscaling (incl. scale-to-zero) | Yes (Knative/KPA) | Manual / custom | No (needs wrapper) |
| OpenAI-compatible API | Yes (v0.16+) | Via ensemble config | Yes, native |
| Dynamic batching | Continuous (vLLM) | Configurable window | Continuous |
| Multi-model serving | Via multiple InferenceServices | Single server, multiple models | One model per process |
| PagedAttention | Yes | Via vLLM backend | Yes |
| Canary / traffic splitting | Native | External (Istio/Gateway) | External |
| Model ensemble / chaining | Via Transformer pipeline | Native DAG | No |
| Production maturity | High (CNCF project) | High (NVIDIA supported) | High (growing fast) |
| Best for | Production serving with MLOps | Multi-framework, complex pipelines | Maximum single-model throughput |

## The GPU Autoscaling Problem

Autoscaling GPU inference is fundamentally different from autoscaling web services.

**GPU utilization is a misleading metric.** A GPU running vLLM at 95% utilization might be handling 10 requests/sec or 200 requests/sec --- utilization stays pinned high as long as *any* work is being done. GPU utilization stays pinned high as long as any work is in-flight --- it does not indicate whether users are getting good latency.

**The right metrics to scale on:**

- **Queue depth**: Number of requests waiting to be processed. If the queue is growing, you need more replicas.
- **Time to First Token (TTFT)**: Latency from request receipt to first generated token. This is what users perceive as "responsiveness."
- **Inter-Token Latency (ITL)**: Time between consecutive tokens. Affects streaming experience.
- **Request throughput**: Requests completed per second vs requests arriving per second.

### KEDA Configuration for GPU Workloads

[KEDA](https://keda.sh) scales based on external metrics. For LLM inference:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: llm-scaler
spec:
  scaleTargetRef:
    name: llm-deployment
  pollingInterval: 10          # Check every 10s (not 30s default)
  cooldownPeriod: 300          # 5 min cooldown (GPU nodes are expensive to churn)
  minReplicaCount: 1           # Keep 1 warm pod always
  maxReplicaCount: 8
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus:9090
        query: |
          sum(vllm:num_requests_waiting{model="llama-3-70b"})
        threshold: "10"        # Scale up when >10 requests queued
```

### Scaling Latency Benchmarks

Every second of scaling latency is a second of degraded user experience:

| Scenario | Time |
|---|---|
| Warm node, model already loaded | ~45 seconds (pod scheduling + container start) |
| Cold node, Karpenter provisioning | ~6.5 minutes (instance launch + GPU driver init + model load) |
| Model load from NVMe local storage | ~18 seconds (for 70B fp16 model) |
| Model load from SATA/network PVC | ~74 seconds (same model) |
| Model load from S3/GCS | ~90-180 seconds (varies by region and model size) |

The implication: **keep warm pods**. The cost of one idle GPU pod ($25-35/hour) is almost always less than the cost of 6+ minutes of failed requests during cold scale-up.

### Cost Circuit Breakers

KEDA supports `maxReplicaCount`, but that is a blunt instrument. For cost control, implement circuit breakers:

- Set `maxReplicaCount` to cap worst-case spend.
- Use KEDA's `fallback` configuration to define behavior when the metrics source is unreachable.
- Monitor scaling events with alerts: "LLM deployment scaled to max replicas" should trigger investigation.

## Multi-Node Inference

A single 70B parameter model in fp16 requires ~140 GB of GPU memory. An H100 has 80 GB. The model does not fit on one GPU. You have two ways to split it across multiple GPUs, and they solve different bottlenecks.

### Tensor Parallelism (TP)

Tensor parallelism splits individual matrix multiplications across GPUs. For a weight matrix W of shape [4096, 4096], TP=4 gives each GPU a [4096, 1024] slice. Each GPU computes its portion of the output, then an AllReduce synchronizes the results.

**Requirement**: TP demands extremely high inter-GPU bandwidth because synchronization happens *within every layer* (multiple times per token). NVLink (900 GB/s on H100) is required. TP across network-connected GPUs is impractical.

### Pipeline Parallelism (PP)

Pipeline parallelism splits the model by layers. If a model has 80 layers and PP=2, GPU group A handles layers 0-39 and GPU group B handles layers 40-79. A request's activations flow from A to B after layer 39. The communication is sequential and relatively infrequent (once per micro-batch per pipeline stage), so network bandwidth requirements are modest.

**Advantage**: PP works across nodes connected by standard (even Ethernet) networking.

```
TENSOR PARALLELISM vs PIPELINE PARALLELISM
───────────────────────────────────────────

  TENSOR PARALLELISM (TP=4)           PIPELINE PARALLELISM (PP=2)
  Split WITHIN each layer             Split BY layers

  Layer N:                            Node A (Layers 0-39):
  ┌─────────────────────────┐         ┌───────────────────────┐
  │  Weight Matrix [4096²]  │         │  Layer 0              │
  │                         │         │  Layer 1              │
  │  ┌────┬────┬────┬────┐  │         │  ...                  │
  │  │GPU │GPU │GPU │GPU │  │         │  Layer 39             │
  │  │ 0  │ 1  │ 2  │ 3  │  │         │                       │
  │  │1024│1024│1024│1024│  │         │  Activations ─────────┼──►
  │  │cols│cols│cols│cols│  │         └───────────────────────┘
  │  └──┬─┴──┬─┴──┬─┴──┬─┘  │                              Network
  │     │    │    │    │     │                              (modest BW)
  │     └────┴──┬─┴────┘     │
  │          AllReduce        │        Node B (Layers 40-79):
  │         (NVLink,         │         ┌───────────────────────┐
  │          900 GB/s)       │    ──►  │  Layer 40             │
  └─────────────────────────┘         │  Layer 41             │
                                      │  ...                  │
  Communication: per-layer,           │  Layer 79             │
  extremely frequent.                 │                       │
  Requires NVLink.                    │  Output ──────────────┼──►
                                      └───────────────────────┘

  COMBINED: 2 nodes x 8 H100s = TP=8 (within node) + PP=2 (across nodes)
  This is how Llama 3.1 405B runs: ~810 GB in fp16, split across 16 GPUs.
```

### LeaderWorkerSet (LWS)

[LeaderWorkerSet](https://github.com/kubernetes-sigs/lws) is a Kubernetes-native API for multi-node GPU workloads. It creates a group of pods where one is designated the leader and the rest are workers. The leader's hostname and IP are injected into all workers, solving the distributed coordination problem:

```yaml
apiVersion: leaderworkerset.x-k8s.io/v1
kind: LeaderWorkerSet
metadata:
  name: llama-405b
spec:
  replicas: 2               # 2 model replicas
  leaderWorkerTemplate:
    size: 2                  # 2 nodes per replica (PP=2)
    leaderTemplate:
      spec:
        containers:
          - name: vllm
            resources:
              limits:
                nvidia.com/gpu: 8  # TP=8 within each node
    workerTemplate:
      spec:
        containers:
          - name: vllm
            resources:
              limits:
                nvidia.com/gpu: 8
```

## llm-d (CNCF Sandbox, March 2026)

Traditional LLM serving treats prefill and decode as a single operation on the same GPU. This is wasteful: **prefill** (processing the input prompt) is compute-bound and bursty, while **decode** (generating output tokens one at a time) is memory-bandwidth-bound and latency-sensitive. A GPU optimized for one is suboptimal for the other.

[llm-d](https://github.com/llm-d/llm-d) (accepted into CNCF Sandbox in March 2026) disaggregates these phases:

### Prefill/Decode Disaggregation

- **Prefill nodes**: Handle prompt processing. Can use batch-optimized configurations, larger batch sizes, and are less sensitive to per-request latency.
- **Decode nodes**: Handle token generation. Optimized for low latency, smaller batches, dedicated KV cache memory.

Requests flow: client --> prefill node (processes prompt, generates KV cache) --> KV cache transfer --> decode node (generates tokens, streams back to client).

### KV Cache Management

llm-d implements hierarchical KV cache offloading:

1. **GPU HBM**: Fastest, most expensive. Active decode requests.
2. **CPU DRAM**: 10-50x cheaper per GB. Recently completed requests that may be reused (prefix caching).
3. **Local NVMe/distributed storage**: Persistent cache for common prefixes (system prompts, few-shot examples).

When a new request arrives with a prefix matching a cached KV cache, the decode node skips recomputation entirely.

### Performance

Benchmarks from the llm-d team show:

- **~57x faster P90 Time to First Token** compared to round-robin load balancing (because cache-aware routing eliminates redundant prefill).
- **~2x throughput** improvement versus round-robin distribution.

### The Production Stack

The emerging production architecture is: **KServe** (model lifecycle, autoscaling, API) + **llm-d** (intelligent routing, disaggregated serving, KV cache management). KServe handles the Kubernetes-native concerns; llm-d handles the LLM-specific optimization.

## Gateway API Inference Extension

As LLM endpoints proliferate in a cluster, standard load balancing (round-robin, least-connections) leaves performance on the table. A request whose prefix matches a warm KV cache on GPU-3 should be routed to GPU-3, not to GPU-7 which would recompute the cache from scratch. Round-robin ignores the most important variable: which GPU already has relevant computation cached in memory.

The [Gateway API Inference Extension](https://gateway-api-inference-extension.sigs.k8s.io/) adds model-aware routing to Kubernetes. It extends the standard Gateway API (the successor to Ingress) with inference-specific semantics.

### CRDs

- **InferencePool**: Defines a pool of pods serving inference (analogous to a Service, but model-aware). Each pool has an Endpoint Selection Extension (ESE) sidecar that makes routing decisions based on real-time pod state.
- **InferenceModel**: Maps a model name to an InferencePool with criticality levels and traffic policies. Multiple InferenceModel resources can point to the same pool, enabling multi-model routing through a single gateway.

### Endpoint Selection Extension (ESE)

The ESE sidecar receives routing requests from the gateway and selects the optimal backend pod based on:

- **KV cache affinity**: Route to the pod most likely to have the request's prefix cached. This is the single biggest optimization --- prefix cache hits eliminate redundant prefill computation, reducing TTFT from seconds to milliseconds for repeated system prompts.
- **Queue depth**: Avoid overloaded pods. The ESE tracks per-pod pending request counts in real time.
- **Model version**: Route to pods serving the requested model version during canary deployments.
- **LoRA adapter affinity**: When serving multiple LoRA fine-tuned variants from a single base model, route to the pod that already has the requested adapter loaded in memory.

### Request Criticality

InferenceModel supports criticality levels (`Critical`, `Standard`, `Sheddable`). During overload, the gateway sheds `Sheddable` requests first, protecting `Critical` traffic. This maps naturally to production use cases: customer-facing chat is `Critical`, background summarization is `Sheddable`, internal testing is `BestEffort`.

```yaml
apiVersion: inference.networking.x-k8s.io/v1alpha2
kind: InferenceModel
metadata:
  name: llama-critical
spec:
  modelName: meta-llama/Llama-3-70B-Instruct
  criticality: Critical
  poolRef:
    name: llm-pool
  targetModels:
    - name: meta-llama/Llama-3-70B-Instruct
      weight: 100
```

## Model Caching and Storage

The single biggest contributor to LLM cold-start latency is model loading. Llama 3.1 405B in fp16 is ~810 GB. Downloading this from object storage to GPU memory takes minutes. Every strategy in this section exists to minimize or eliminate that wait.

```
MODEL LOADING STRATEGIES
────────────────────────

  STRATEGY 1: Object Storage (Slow, Simple)
  ┌──────┐   download    ┌──────────┐   load    ┌──────┐
  │  S3  │──────────────►│ Pod      │──────────►│ GPU  │
  │  GCS │  90-180s      │ (ephemeral│  10-30s  │ VRAM │
  │  Hub │  (network)    │  storage) │          │      │
  └──────┘               └──────────┘          └──────┘
  Total: 100-210s.  Every scale-up pays this cost.

  STRATEGY 2: Shared PVC (NFS / ReadWriteMany)
  ┌──────────────────────────────────────────────────────┐
  │  NFS PVC (ReadWriteMany)                              │
  │  /models/llama-3-70b/  (pre-populated)               │
  │                                                       │
  │  ┌──────────┐  ┌──────────┐  ┌──────────┐           │
  │  │ Pod A    │  │ Pod B    │  │ Pod C    │           │
  │  │ mounts   │  │ mounts   │  │ mounts   │           │
  │  │ /models  │  │ /models  │  │ /models  │           │
  │  └──────────┘  └──────────┘  └──────────┘           │
  └──────────────────────────────────────────────────────┘
  Total: 30-74s (NFS read → GPU).  No download step.

  STRATEGY 3: KServe LocalModel + Local NVMe
  ┌──────────┐  pre-cached   ┌────────────┐  load   ┌──────┐
  │ LocalModel│──────────────►│ Node NVMe  │────────►│ GPU  │
  │ controller│  (background) │ /mnt/models│  ~18s  │ VRAM │
  └──────────┘               └────────────┘         └──────┘
  Total: ~18s.  Model pre-staged on node before pod starts.

  STRATEGY 4: GKE Hyperdisk ML
  ┌──────────┐   block device  ┌──────────┐  load   ┌──────┐
  │ Hyperdisk│────────────────►│ Pod      │────────►│ GPU  │
  │ ML volume│   1.2 TB/s read │          │  ~20min │ VRAM │
  │ (GKE)    │   throughput    │          │ →20s   │      │
  └──────────┘                 └──────────┘         └──────┘
  Total: ~20s for 405B.  Was 90 min from GCS.
```

### The Concurrent Download Corruption Problem

When multiple pods share an NFS PVC and a new model version is deployed, naive init containers in each pod will download the model simultaneously. This creates a race condition: Pod A writes half the file, Pod B overwrites it, both end up with corrupt weights.

**The solution**: Use a central Kubernetes **Job** that downloads the model once to the shared PVC. Pods wait (via an init container that checks for a sentinel file) until the Job completes. This pattern is simple but eliminates an entire class of data corruption bugs.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: download-llama-70b
spec:
  template:
    spec:
      containers:
        - name: downloader
          image: python:3.11
          command: ["huggingface-cli", "download",
                    "meta-llama/Llama-3-70B-Instruct",
                    "--local-dir", "/models/llama-3-70b"]
          volumeMounts:
            - name: model-store
              mountPath: /models
          env:
            - name: HUGGING_FACE_HUB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-secret
                  key: token
      volumes:
        - name: model-store
          persistentVolumeClaim:
            claimName: shared-model-store
      restartPolicy: OnFailure
```

### GKE Hyperdisk ML

Google's [Hyperdisk ML](https://cloud.google.com/kubernetes-engine/docs/how-to/persistent-volumes/hyperdisk-ml) volumes provide up to 1.2 TB/s read throughput from a block storage volume. For Llama 3.1 405B loading, GKE benchmarks show reduction from **90 minutes (GCS download) to approximately 20 minutes** with Hyperdisk ML, with further improvement possible through multi-volume striping.

## The Hugging Face Ecosystem on Kubernetes

### Text Generation Inference (TGI)

[TGI](https://github.com/huggingface/text-generation-inference) was the first production-grade open-source LLM inference server. It pioneered several techniques now considered industry standard: continuous batching, flash attention integration, tensor parallelism, quantization support (GPTQ, AWQ, EETQ), and speculative decoding.
As of December 2025, the Hugging Face team recommends vLLM or SGLang for new LLM serving deployments. TGI remains in maintenance mode for existing users. If you are currently running TGI in production, it continues to work reliably --- but new deployments should evaluate vLLM (for throughput) or SGLang (for structured generation and agent workloads) first.

### Text Embeddings Inference (TEI)

[TEI](https://github.com/huggingface/text-embeddings-inference) is purpose-built for embedding and reranking models. Key characteristics:

- **Small footprint**: Embedding models (e.g., `BAAI/bge-large-en-v1.5` at 1.3 GB) fit on a single GPU or even CPU.
- **Fast boot**: Sub-second cold starts for small models.
- **Dynamic batching**: Automatically batches concurrent requests.
- **Token-based API**: `POST /embed` with OpenAI-compatible response format.

TEI is the right choice for embedding pipelines in RAG architectures. Run it on a small GPU (T4, L4) or CPU nodes to keep costs minimal.

### Hub Integration on Kubernetes

Most Hugging Face models are served from the [Hugging Face Hub](https://huggingface.co). On Kubernetes, the integration pattern is:

1. **Authentication**: Store your token in a Kubernetes Secret and mount as `HUGGING_FACE_HUB_TOKEN` (or `HF_TOKEN`) environment variable.
2. **Caching**: The Hub client caches downloads in `~/.cache/huggingface/hub`. Mount a PVC at this path to persist downloads across pod restarts.
3. **Multi-replica caching**: For multiple replicas sharing a model, use a ReadWriteMany NFS PVC with a pre-population Job (as described above). This ensures one download, many readers.

```yaml
env:
  - name: HF_TOKEN
    valueFrom:
      secretKeyRef:
        name: hf-secret
        key: token
  - name: HF_HOME
    value: /models/cache
volumeMounts:
  - name: model-cache
    mountPath: /models/cache
```

## NVIDIA NIM

[NVIDIA NIM](https://developer.nvidia.com/nim) (NVIDIA Inference Microservices) provides pre-optimized inference containers. Rather than configuring TensorRT profiles, quantization settings, and parallelism parameters yourself, NIM containers ship with models already optimized for specific GPU configurations.

### Why NIM Matters

Raw vLLM or Triton deployments require significant tuning: choosing the right quantization (GPTQ, AWQ, fp8), compiling TensorRT-LLM engines for your GPU architecture, setting optimal batch sizes and cache configurations. NIM pre-solves this optimization problem. NVIDIA benchmarks show **2.6x throughput improvement** over off-the-shelf vLLM deployment for the same model on the same hardware.

### NIM Operator 3.0.0

The NIM Operator manages NIM containers on Kubernetes:

- **Multi-LLM**: Deploy and manage multiple models from a single operator.
- **Multi-node**: Automatic configuration of tensor and pipeline parallelism across nodes.
- **DRA support**: Integrates with Dynamic Resource Allocation for fine-grained GPU management.
- **NIMCache CRD**: Pre-downloads and caches model engines on nodes, solving the cold-start problem.

```yaml
apiVersion: apps.nvidia.com/v1alpha1
kind: NIMService
metadata:
  name: llama-3-70b-nim
spec:
  image: nvcr.io/nim/meta/llama-3-70b-instruct:latest
  replicas: 2
  resources:
    gpus: 4                  # TP=4 automatically configured
  storage:
    nimCache: llama-cache    # Pre-populated NIMCache
```

### When to Use NIM vs vLLM

Use NIM when you need maximum performance with minimal tuning effort and are running NVIDIA-supported models on NVIDIA GPUs. The pre-optimization is the differentiator: NIM containers include TensorRT-LLM engines compiled for specific GPU architectures, with quantization, batching, and cache settings already tuned. You trade flexibility for performance.

Use vLLM directly when you need full control over serving configuration, run non-NVIDIA hardware (AMD ROCm, Intel Gaudi), serve models not in the NIM catalog, or need to customize the serving logic (custom sampling, constrained decoding, speculative decoding with draft models). vLLM's open-source community moves fast --- new model architectures are typically supported within days of release.

For Hugging Face infrastructure specifically, the typical pattern is: vLLM for the Inference API (maximum model coverage, rapid updates) and NIM for dedicated enterprise deployments where a fixed set of models must run at peak performance.

## Common Mistakes and Misconceptions

- **"Serving an LLM is just deploying a container."** Large models need tensor parallelism across multiple GPUs, KV cache management, continuous batching, and careful memory planning.
- **"Bigger instances are always better for LLM serving."** Cost-per-token often favors multiple smaller GPU instances over fewer large ones, depending on model size and batching strategy. Profile your specific model to find the cost-optimal configuration.
- **"Auto-scaling LLM inference works like web services."** LLM pods take minutes to load models into GPU memory. Scale-from-zero is extremely slow. Maintain warm replicas and scale on custom metrics (queue depth, KV cache utilization) rather than CPU.
- **"All LLM serving frameworks are interchangeable."** vLLM excels at throughput with PagedAttention, TGI integrates tightly with Hugging Face models, Triton supports multi-model serving. Choose based on your specific model and serving requirements.

## Further Reading

- [vLLM Documentation and GitHub](https://github.com/vllm-project/vllm) --- the open-source inference engine covering PagedAttention, continuous batching, tensor parallelism, and supported model architectures.
- [KServe Documentation](https://kserve.github.io/kserve/) --- the Kubernetes-native model inference platform, including its InferenceService CRD, model mesh, and autoscaling configuration.
- [llm-d GitHub Repository](https://github.com/llm-d/llm-d) --- the Kubernetes-native LLM serving stack with disaggregated prefill/decode, KV-cache-aware routing, and LoRA adapter management.
- [LeaderWorkerSet Documentation](https://github.com/kubernetes-sigs/lws) --- the Kubernetes SIG-Apps project for deploying multi-node inference workloads where one leader coordinates multiple workers for tensor and pipeline parallelism.
- [NVIDIA Triton Inference Server Documentation](https://docs.nvidia.com/triton-inference-server/) --- NVIDIA's production inference server covering model ensembles, dynamic batching, and multi-framework support.
- [Text Generation Inference (TGI) by Hugging Face](https://huggingface.co/docs/text-generation-inference/) --- Hugging Face's optimized inference server with flash attention, quantization, watermarking, and grammar-constrained generation.
- [Efficient Memory Management for Large Language Model Serving with PagedAttention (paper)](https://arxiv.org/abs/2309.06180) --- the foundational paper on PagedAttention that enables vLLM's near-optimal KV cache memory management.
- [Anyscale: How Continuous Batching Enables 23x Throughput](https://www.anyscale.com/blog/continuous-batching-llm-inference) --- a practical explanation of why continuous (iteration-level) batching dramatically outperforms static batching for LLM serving.

---

**Next:** [Disaster Recovery](43-disaster-recovery.md) --- cluster backup, etcd snapshots, multi-region strategies, and the procedures you test before you need them.

# Chapter 13: The Networking Stack Evolution

## The Fundamental Requirement

Kubernetes imposes a single, non-negotiable networking requirement: **every pod gets its own IP address, and every pod can communicate with every other pod without NAT.** This is called the flat network model. A pod on Node A can reach a pod on Node B by sending a packet to that pod's IP address directly. No port mapping. No address translation. No special routing configuration by the application developer.

This requirement is deceptively simple to state and remarkably difficult to implement. On a single machine, giving each container its own IP is straightforward using Linux network namespaces and virtual ethernet pairs. But across machines, you must somehow route packets from one node's pod network to another node's pod network, typically over a physical network that knows nothing about Kubernetes pods. This is the problem that CNI (Container Network Interface) plugins solve, and the evolution of these plugins reflects the broader maturation of Kubernetes networking from "good enough" to "production-grade at massive scale."

## Flannel: The First Answer (2014)

**Flannel**, created by CoreOS in 2014, was the first widely-adopted CNI plugin for Kubernetes. Flannel's approach was simple: create a VXLAN overlay network. Each node was assigned a subnet (e.g., node 1 gets 10.244.1.0/24, node 2 gets 10.244.2.0/24), and VXLAN encapsulation handled cross-node communication. When a pod on node 1 sent a packet to a pod on node 2, Flannel encapsulated the pod-to-pod packet inside a UDP packet with the node-to-node addresses, sent it across the physical network, and de-encapsulated it on the other side.

```
Flannel VXLAN Overlay

  Node 1 (10.0.0.1)                          Node 2 (10.0.0.2)
  ┌───────────────────────┐                  ┌───────────────────────┐
  │  Pod A: 10.244.1.5    │                  │  Pod B: 10.244.2.8    │
  │       |               │                  │       ^               │
  │       v               │                  │       |               │
  │  ┌──────────────┐     │                  │  ┌──────────────┐     │
  │  │ flannel.1    │     │                  │  │ flannel.1    │     │
  │  │ (VXLAN dev)  │     │                  │  │ (VXLAN dev)  │     │
  │  └──────┬───────┘     │                  │  └──────┬───────┘     │
  │         |             │                  │         ^             │
  │    encapsulate:       │                  │    decapsulate:       │
  │    src=10.0.0.1       │   physical       │    unwrap to get      │
  │    dst=10.0.0.2       │   network        │    original packet    │
  │    payload=[Pod pkt]  │ ─────────────>   │                      │
  └───────────────────────┘                  └───────────────────────┘
```

Flannel worked. It was simple to deploy, easy to understand, and provided basic pod-to-pod connectivity. But it had significant limitations:

- **No network policy support.** Flannel could not restrict which pods could talk to which other pods. In a multi-tenant cluster, any pod could reach any other pod. This was a non-starter for security-conscious organizations.
- **VXLAN overhead.** Encapsulation added 50 bytes of header overhead to every packet, reducing the effective MTU. It also added CPU overhead for encapsulation and decapsulation.
- **Limited performance.** The overlay approach was inherently slower than native routing because of the encapsulation overhead and the need to traverse the kernel's network stack twice (once for the inner packet, once for the outer packet).

Flannel was "good enough" for getting started, and it remains useful in simple environments and edge deployments (k3s includes Flannel by default). But production clusters needed more.

## Calico: Production-Grade Networking (2016)

**Calico**, created by Tigera, took a fundamentally different approach. Instead of overlay networking, Calico used **BGP (Border Gateway Protocol)** to distribute pod routes across the physical network. Each node announced its pod subnet to its neighbors using BGP, and the physical network infrastructure routed packets natively. No encapsulation. No overlay. Packets traveled from pod to pod using the same routing mechanisms that power the internet.

This approach had significant advantages:

- **Native performance.** Without encapsulation overhead, Calico achieved near-line-rate performance. Packets were not wrapped and unwrapped; they were simply routed.
- **Rich network policies.** Calico implemented Kubernetes NetworkPolicy and extended it with its own CRD-based policies that supported L3/L4 rules, namespace selectors, global policies, and CIDR-based rules for external traffic.
- **Visibility.** Because packets were not encapsulated, standard network debugging tools (tcpdump, traceroute) worked as expected. With overlays, debugging required understanding the encapsulation layer.

The tradeoff was that BGP-based routing required cooperation from the physical network infrastructure. In cloud environments where you could not run BGP (because the cloud provider controlled the network), Calico could fall back to VXLAN or IP-in-IP encapsulation. This hybrid approach made Calico viable everywhere while providing optimal performance on bare metal.

Calico became the de facto standard for production Kubernetes networking. Its combination of performance, network policy support, and operational maturity made it the default choice for most serious deployments.

## The eBPF Revolution

To understand why eBPF changed Kubernetes networking, you must first understand how **kube-proxy** and **iptables** work --- and why they fail at scale.

### The iptables Problem

kube-proxy is the Kubernetes component responsible for implementing Services. When you create a Service with three backend pods, kube-proxy programs the node's packet filtering rules so that traffic to the Service's ClusterIP is load-balanced across the three pods. Historically, kube-proxy used **iptables** to implement this.

iptables is a Linux kernel packet filtering framework that evaluates rules sequentially. For each Service, kube-proxy creates a chain of iptables rules that use probability-based matching to distribute traffic across endpoints. If a Service has three endpoints, the first rule matches with probability 1/3, the second matches with probability 1/2 (of the remaining traffic), and the third catches everything else.

The problem is scale. iptables rules are evaluated **linearly** for each packet. In a cluster with 10,000 Services, each with multiple endpoints, the iptables rule set can grow to hundreds of thousands of rules. Every packet entering the node traverses this list. The result is measurable latency increases at scale, slow rule updates (programming 100,000 iptables rules takes seconds to minutes), and high CPU overhead.

```
iptables vs eBPF: The Performance Cliff

  Packet processing time vs. number of Services

  Latency
  (us)
  |
  |                                           * iptables
  |                                        *
  |                                     *
  |                                  *
  |                              *
  |                          *
  |                      *
  |                  *
  |             *
  |         *
  |     *
  |  ──────────────────────────────────────── eBPF (constant)
  |
  └─────────────────────────────────────────── Number of Services
          1K       5K       10K      20K

  iptables: O(n) linear scan for each packet
  eBPF:     O(1) hash table lookup for each packet
```

**IPVS** (IP Virtual Server) was introduced as an alternative kube-proxy mode to address some of these issues. IPVS uses hash tables rather than linear rule chains, providing better performance at scale. But IPVS still runs in the kernel's Netfilter framework and has limitations around custom packet manipulation and observability.

### eBPF: Programs in the Kernel

**eBPF (extended Berkeley Packet Filter)** is a technology that allows running sandboxed programs directly in the Linux kernel without modifying kernel source code or loading kernel modules. Originally designed for packet filtering (hence the name), eBPF has evolved into a general-purpose in-kernel execution environment.

An eBPF program is compiled to a bytecode that the kernel verifies for safety (no infinite loops, no invalid memory access, bounded execution time) and then JIT-compiles to native machine code. eBPF programs can be attached to various kernel hooks: network device ingress/egress, socket operations, system calls, tracepoints, and more.

For Kubernetes networking, eBPF is transformative because it allows implementing Service load-balancing, network policies, and observability at the **earliest possible point in the kernel's network stack**, using **hash table lookups** instead of linear rule chains.

When a packet arrives at a node destined for a Service ClusterIP, an eBPF program attached to the network device performs a single hash lookup in a BPF map to find the backend pod, rewrites the packet's destination address, and forwards it. O(1) regardless of how many Services exist. No iptables traversal. No Netfilter overhead.

## Cilium: eBPF-Native Networking (2017)

**Cilium**, created by Isovalent in 2017 (Isovalent was acquired by Cisco in 2024), was built from the ground up on eBPF. Where Calico added eBPF support as an alternative to its iptables-based datapath, Cilium was eBPF-native from day one.

Cilium's capabilities extend well beyond basic networking:

**kube-proxy replacement.** Cilium can fully replace kube-proxy, implementing Service load-balancing with eBPF programs. This eliminates the iptables bottleneck entirely and provides features like Maglev consistent hashing (for better load distribution), DSR (Direct Server Return) for reduced latency on reply packets, and graceful connection handling during backend changes.

**L7-aware network policies.** Traditional network policies operate at L3/L4 --- IP addresses and TCP/UDP ports. Cilium's eBPF programs can inspect L7 protocol headers, enabling policies like "allow HTTP GET to /api/v1/users but deny HTTP DELETE" or "allow gRPC calls to the ProductService.GetProduct method but deny ProductService.DeleteProduct." This level of granularity was previously only available through service meshes.

**Hubble observability.** Cilium includes Hubble, an observability platform that provides real-time visibility into network flows, DNS queries, HTTP requests, and connection state --- all captured by eBPF programs with minimal overhead. This is networking observability without sampling, without agents, without instrumentation.

**Transparent encryption.** Cilium can encrypt all pod-to-pod traffic using WireGuard or IPsec, transparently and without application changes. The encryption and decryption happen in eBPF programs attached to the network interfaces, so applications are unaware of the encryption layer.

**Bandwidth management.** eBPF programs can implement EDT (Earliest Departure Time) based rate limiting, providing better bandwidth management than traditional tc (traffic control) approaches.

Cilium became the default CNI on Google Kubernetes Engine in 2023, a significant endorsement. Its adoption reflects a broader trend: the kernel's programmability through eBPF is displacing decades of networking infrastructure built on iptables, ipvs, and userspace proxies.

## The kube-proxy Replacement Story

The move to replace kube-proxy deserves special attention because it illustrates how architectural assumptions age.

When Kubernetes was designed, iptables was the standard way to implement packet manipulation in the Linux kernel. It was well-understood, widely deployed, and sufficient for the cluster sizes of the time (dozens to hundreds of nodes, hundreds to thousands of Services). kube-proxy's iptables mode was a reasonable engineering choice.

But Kubernetes clusters grew. Cloud providers ran clusters with tens of thousands of nodes and tens of thousands of Services. The linear scaling characteristics of iptables became untenable. Rule update latency meant Service changes took minutes to propagate. Connection tracking table overflow caused packet drops.

The progression was:
1. **iptables mode** (original): simple, O(n) per packet, slow updates at scale
2. **IPVS mode** (Kubernetes 1.11 GA): hash-based, better at scale, but still Netfilter-based
3. **eBPF mode** (Cilium, Calico): O(1) per packet, fast updates, additional features
4. **nftables mode** (Kubernetes 1.31): successor to iptables within the Netfilter framework, better performance and maintainability than iptables but still not eBPF-level

Today, organizations running at scale increasingly use Cilium or Calico's eBPF datapath in place of kube-proxy. The kube-proxy component remains the default for backward compatibility and for environments where eBPF is not available (older kernels, certain cloud VMs), but the trajectory is clear.

## Service Mesh Evolution

**Istio**, jointly developed by Google, IBM, and Lyft and announced in 2017, was the first major service mesh for Kubernetes. Istio's architecture injected an **Envoy sidecar proxy** into every pod. All traffic to and from the pod passed through this proxy, which could enforce mTLS (mutual TLS), collect metrics, perform traffic routing, implement circuit breakers, and enforce access policies.

```
Sidecar Mesh vs. Sidecar-less Mesh

  Traditional (Istio with sidecars):

  ┌─────────────────────────┐     ┌─────────────────────────┐
  │  Pod A                  │     │  Pod B                  │
  │  ┌──────┐  ┌─────────┐ │     │ ┌─────────┐  ┌──────┐  │
  │  │ App  │─>│ Envoy   │─┼────>┼─│ Envoy   │─>│ App  │  │
  │  │      │  │ sidecar │ │     │ │ sidecar │  │      │  │
  │  └──────┘  └─────────┘ │     │ └─────────┘  └──────┘  │
  └─────────────────────────┘     └─────────────────────────┘
    Each pod has its own proxy       Memory + CPU per pod

  Sidecar-less (Cilium Service Mesh / Istio Ambient):

  ┌────────────┐  ┌────────────┐
  │  Pod A     │  │  Pod B     │
  │  ┌──────┐  │  │  ┌──────┐  │
  │  │ App  │  │  │  │ App  │  │
  │  └──┬───┘  │  │  └──┬───┘  │
  └─────┼──────┘  └─────┼──────┘
        │               │
  ┌─────▼───────────────▼──────────────────┐
  │  Per-Node Proxy / eBPF datapath        │
  │  (shared, not per-pod)                 │
  │  mTLS, L7 policy, observability        │
  └────────────────────────────────────────┘
    One proxy per node, not per pod
```

The sidecar approach was powerful but expensive. Each sidecar consumed memory (50-100 MB per pod was common for Envoy), added latency (traffic traversed two proxies for each hop), and increased the complexity of the pod lifecycle (the sidecar had to start before the application, and shutting down required careful ordering). In a cluster with 10,000 pods, the sidecar overhead was 500 GB to 1 TB of memory just for the mesh infrastructure.

**Linkerd**, created by Buoyant in 2017, was the lighter-weight alternative. Linkerd's Rust-based proxy (linkerd2-proxy) consumed significantly less memory than Envoy and focused on a smaller, well-defined feature set: mTLS, observability, and reliability features. 
The most significant recent trend is the **sidecar-less mesh**. Cilium Service Mesh uses eBPF programs in the kernel to provide mTLS, L7 policy, and observability without any sidecar proxies. Istio's Ambient Mesh mode uses per-node ztunnel proxies for L4 features (mTLS, L4 policy) and optional waypoint proxies for L7 features, eliminating the per-pod sidecar overhead.

The sidecar-less approach reflects a broader realization: much of what sidecars do can be done more efficiently at the node level or in the kernel. The sidecar was an architectural choice driven by the constraints of 2017 (limited eBPF support, no per-node proxy infrastructure). As the infrastructure has evolved, the architecture is evolving with it.

## The Current Landscape

The Kubernetes networking stack in 2024+ looks nothing like it did in 2015:

- **CNI plugin**: Cilium (dominant, especially on cloud), Calico (strong on-premises), Flannel (edge/simple deployments)
- **Service implementation**: eBPF (Cilium, Calico) replacing iptables/IPVS (kube-proxy)
- **Network policy**: Cilium or Calico, both supporting L3/L4 and increasingly L7
- **Service mesh**: consolidating around sidecar-less approaches; Istio Ambient and Cilium Service Mesh
- **Encryption**: WireGuard-based transparent encryption (Cilium, Calico)

The evolution from Flannel's simple VXLAN overlay to Cilium's eBPF-native stack represents one of the most dramatic technical shifts in the Kubernetes ecosystem. It was driven by scale: the solutions that worked for hundreds of nodes failed at thousands. And it was enabled by a foundational technology shift (eBPF) that changed what was possible inside the Linux kernel. For a quick flowchart on choosing a CNI, see [Appendix C: Decision Trees](A3-decision-trees.md).

## Common Mistakes and Misconceptions

- **"eBPF replaces all of iptables immediately."** Cilium's eBPF datapath replaces kube-proxy's iptables rules for service routing, but iptables still exists on the host for other purposes. Migration is incremental.
- **"I need a service mesh from day one."** Service meshes add complexity (sidecars, mTLS certificate management, control plane). Start without one; add it when you have a concrete need for mTLS, traffic splitting, or observability between services.
- **"Flannel is obsolete."** Flannel is simpler and lighter than Calico or Cilium. For small clusters that don't need NetworkPolicy, Flannel is a perfectly valid choice.

## Further Reading

- [Cilium documentation](https://docs.cilium.io/) -- Comprehensive reference for the eBPF-based CNI plugin that has become the dominant networking solution. The "Concepts" section explains how eBPF replaces iptables for service routing, network policy, and observability.
- [Calico documentation](https://docs.tigera.io/calico/latest/about/) -- Covers Calico's BGP-based networking, network policy engine, and eBPF dataplane. Particularly strong on network policy design patterns for enterprise environments.
- [eBPF.io](https://ebpf.io/) -- The definitive resource for understanding eBPF, the kernel technology underpinning modern Kubernetes networking. Includes tutorials, reference material, and a curated list of eBPF-based projects.
- [Isovalent blog: "eBPF-based Networking, Observability, Security"](https://isovalent.com/blog/) -- Technical deep-dives from the creators of Cilium on how eBPF is applied to networking, including kube-proxy replacement, transparent encryption, and service mesh without sidecars.
- [Thomas Graf -- "Accelerating Envoy with the Linux Kernel" (KubeCon EU 2018)](https://www.youtube.com/watch?v=ER9eIXL2_14) --- Cilium creator on how eBPF fundamentally changes Kubernetes networking performance and architecture.
- [Flannel GitHub repository](https://github.com/flannel-io/flannel) -- The simple overlay network that was the default CNI for early Kubernetes. Reading the design docs helps understand the baseline that more advanced CNI plugins improved upon.
- [Cilium Service Mesh](https://docs.cilium.io/en/stable/network/servicemesh/) -- Documentation on Cilium's sidecar-less service mesh implementation, showing how eBPF enables mTLS, L7 policy, and traffic management without per-pod proxy overhead.
- [Kubernetes Network Policy documentation](https://kubernetes.io/docs/concepts/services-networking/network-policies/) -- The official reference for the NetworkPolicy API, essential for understanding the baseline that CNI plugins like Cilium and Calico extend with their own CRDs.

---

**Next:** [Chapter 14: Kubernetes Version History --- A Guided Tour](14-version-history.md)

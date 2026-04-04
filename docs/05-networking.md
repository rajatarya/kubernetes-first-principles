# Chapter 5: The Networking Model — Why Every Pod Gets an IP

## The Fundamental Networking Problem

Kubernetes' networking model is one of its most distinctive design decisions, and it is the source of much confusion for newcomers. To understand why Kubernetes networking works the way it does, you must first understand the alternative it rejected.

## Docker Port-Mapping vs. Kubernetes Flat Network

```
 DOCKER PORT-MAPPING MODEL              KUBERNETES FLAT NETWORK MODEL
 ─────────────────────────              ────────────────────────────

 Host IP: 192.168.1.10                  Node 1                Node 2
 ┌──────────────────────┐               ┌──────────────┐      ┌──────────────┐
 │ Container A (:80)    │               │ Pod A        │      │ Pod C        │
 │  → mapped to :32768  │               │ 10.244.1.5   │      │ 10.244.2.8   │
 │                      │               │ :80 is :80   │      │ :80 is :80   │
 │ Container B (:80)    │               │              │      │              │
 │  → mapped to :32769  │               │ Pod B        │      │ Pod D        │
 │                      │               │ 10.244.1.6   │      │ 10.244.2.9   │
 │ Container C (:3000)  │               │ :3000 is     │      │ :3000 is     │
 │  → mapped to :32770  │               │  :3000       │      │  :3000       │
 └──────────────────────┘               └──────┬───────┘      └──────┬───────┘
                                               │    Flat network     │
 Client must know:                             └─────────────────────┘
  192.168.1.10:32768                     Any pod can reach any pod by IP.
  192.168.1.10:32769                     No port translation. No NAT.
  192.168.1.10:32770                     Apps bind to the port they expect.
```

## Docker's Port-Mapping Model (and Why Kubernetes Rejected It)

In the default Docker networking model, containers share the host's network namespace. Since multiple containers might want to listen on the same port (e.g., port 80), Docker uses **port mapping**: the container's port 80 is mapped to a high-numbered port on the host (e.g., 32768). This means:

- The container's address from outside is `<host-ip>:<random-port>`, not a predictable address.
- Every service that needs to communicate with the container must know the host IP and the mapped port.
- Port allocation must be coordinated across all containers on a host to avoid conflicts.
- Applications must be aware of port mapping, or an intermediary must translate.

This model breaks a fundamental assumption of network programming: that you know your own address. A container that binds to port 80 thinks it is listening on port 80, but external clients reach it on port 32768. This impedance mismatch complicates service discovery, load balancing, and application configuration.

Google's experience with Borg confirmed that port-mapping models create cascading complexity. In Borg's early design, tasks were assigned random ports, and a naming service (BNS) provided the mapping from logical names to host:port pairs. This worked but was a constant source of operational friction: every application had to be port-aware, load balancers needed frequent updates, and debugging network issues required understanding the port-mapping layer.

## Kubernetes' Flat Networking Model

Kubernetes takes a radically different approach. Its networking model has three fundamental rules:

1. **Every Pod gets its own IP address.** No port mapping. No NAT between pods. A pod that binds to port 80 is reachable on port 80 at its pod IP.
2. **All pods can communicate with all other pods without NAT.** Any pod can reach any other pod using the other pod's IP address, regardless of which node either pod is on.
3. **Agents on a node (kubelet, kube-proxy) can communicate with all pods on that node.**

This is sometimes called the **flat networking model** because from the perspective of pods, the network is flat: every pod is directly reachable from every other pod. There are no layers of NAT or port mapping to navigate.

Why is this model superior? Because it **preserves the assumptions of traditional network programming**. Applications do not need to know about port mapping. They bind to the port they expect. They connect to other services at their expected ports. DNS, load balancers, and monitoring tools work as expected. The mental model is: "pods are like VMs on a flat network." This dramatically simplifies application development and debugging.

## How the Flat Network Is Implemented: CNI

Kubernetes does not implement networking itself. Instead, it defines the **Container Network Interface (CNI)** specification: a standard API that networking plugins must implement. The CNI plugin is responsible for:

- Allocating an IP address for each pod
- Configuring the pod's network namespace (virtual ethernet pair, routes, etc.)
- Ensuring pod-to-pod connectivity across nodes

Different CNI plugins implement this in different ways:

- **Flannel** uses a simple overlay network (VXLAN or host-gateway) to encapsulate pod traffic in UDP or IP-in-IP packets.
- **Calico** uses BGP to distribute pod routes, avoiding encapsulation overhead and enabling network policies.
- **Cilium** uses eBPF (extended Berkeley Packet Filter) programs in the Linux kernel for high-performance, programmable networking.
- **AWS VPC CNI** assigns pod IPs from the AWS VPC address space, making pods first-class citizens in the VPC network.

The CNI abstraction is another example of Kubernetes' design philosophy: **define the interface, not the implementation**. By specifying what networking must provide (unique pod IPs, flat connectivity) without specifying how, Kubernetes allows the networking layer to be optimized for different environments.

## Services: Stable Endpoints for Ephemeral Pods

Pod IP addresses are ephemeral. When a pod is destroyed and recreated, it gets a new IP. This means you cannot rely on pod IPs for service discovery. This is where the **Service** abstraction comes in.

A Service provides a **stable virtual IP address** (the ClusterIP) and a **stable DNS name** that routes traffic to the set of pods matching the Service's label selector. The mapping from Service to pods is maintained by the Endpoints (or EndpointSlice) controller, which watches for pod changes and updates the endpoint list.

```
                    ┌─────────────────────────────────┐
                    │        Service: "web-svc"        │
                    │     ClusterIP: 10.96.0.42       │
                    │     DNS: web-svc.default.svc    │
                    │     Selector: app=web            │
                    └───────────────┬─────────────────┘
                                    │
                         kube-proxy / iptables
                         load-balances across:
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
                    ▼               ▼               ▼
              ┌──────────┐   ┌──────────┐   ┌──────────┐
              │ Pod      │   │ Pod      │   │ Pod      │
              │ app=web  │   │ app=web  │   │ app=web  │
              │10.244.1.5│   │10.244.2.8│   │10.244.1.9│
              │ Node 1   │   │ Node 2   │   │ Node 1   │
              └──────────┘   └──────────┘   └──────────┘

 Client code: http://web-svc:80  →  transparently routed to a pod
```

Kube-proxy (or the CNI plugin) programs rules on every node that intercept traffic to the Service's ClusterIP and redirect it to one of the backing pod IPs, using round-robin or other load-balancing algorithms. From the client's perspective, the Service has a single, stable address; the fact that traffic is being distributed to ephemeral pods is transparent.

Services come in several types:

- **ClusterIP** (default): Accessible only within the cluster.
- **NodePort**: Exposes the Service on a static port on every node's IP, making it accessible from outside the cluster.
- **LoadBalancer**: Provisions an external load balancer (on cloud providers) that routes external traffic to the Service.
- **ExternalName**: Maps the Service to a DNS CNAME record, providing a Kubernetes-native alias for an external service.

## Ingress and Gateway API: L7 Routing

Services operate at Layer 4 (TCP/UDP). For HTTP-level routing --- path-based routing, host-based virtual hosting, TLS termination --- Kubernetes provides the **Ingress** resource (and its successor, the **Gateway API**).

An Ingress is a declaration of routing rules: "route traffic for host foo.example.com to Service foo, and traffic for host bar.example.com to Service bar." An Ingress Controller (a separate component, typically nginx, HAProxy, Traefik, or a cloud load balancer) watches for Ingress resources and configures the actual routing.

The Gateway API, introduced as a successor to Ingress, provides a more expressive and extensible model for routing, with better support for multi-tenancy, traffic splitting, and protocol-specific routing.

## Network Policies: The Missing Firewall

By default, Kubernetes' flat networking model allows all pods to communicate with all other pods. This is convenient but not secure. **Network Policies** provide pod-level firewall rules: you can specify which pods can communicate with which other pods, based on labels, namespaces, and IP blocks.

Network Policies are implemented by the CNI plugin (not all plugins support them). They are another example of Kubernetes' declarative model: you declare the desired network access rules, and the CNI plugin configures the underlying network to enforce them.

### The Four Networking Problems

| Problem | Solution | Key Mechanism |
|---------|----------|---------------|
| Container-to-container on same pod | Shared network namespace (localhost) | Pods share a single IP; containers communicate via localhost |
| Pod-to-pod across nodes | Flat network via CNI plugin | Every pod gets a unique IP; CNI ensures cross-node connectivity |
| Pod-to-Service (service discovery) | Service abstraction with ClusterIP | kube-proxy/CNI programs iptables/IPVS rules for load balancing |
| External-to-Service | NodePort, LoadBalancer, Ingress | Expose services externally via port mapping, cloud LB, or L7 routing |

## Common Mistakes and Misconceptions

- **"Pods need NAT to talk to each other."** Kubernetes requires a flat network where every pod can reach every other pod directly by IP without NAT. This is a fundamental requirement of the networking model, enforced by the CNI plugin. If you find yourself configuring NAT between pods, something is misconfigured.

- **"Services are load balancers."** A Service is a stable virtual IP (ClusterIP) with endpoint tracking and basic load distribution via kube-proxy rules. Only `type: LoadBalancer` provisions an actual external load balancer. ClusterIP and NodePort Services are internal routing constructs, not load balancer appliances.

- **"Pod IPs are stable."** Pod IPs are ephemeral and change every time a pod is restarted or rescheduled. Never hard-code pod IPs in configuration. Use Services for stable endpoints and DNS-based service discovery.

- **"NodePort is fine for production."** NodePort exposes a high-numbered port on every node in the cluster, making it difficult to manage, secure, and integrate with external DNS or TLS. For production external traffic, use Ingress controllers or `type: LoadBalancer` Services instead.

## Further Reading

- [Kubernetes Networking Model](https://kubernetes.io/docs/concepts/cluster-administration/networking/) -- Official documentation explaining the fundamental requirement that every pod gets a unique IP and can communicate with every other pod without NAT.
- [CNI Specification](https://www.cni.dev/docs/spec/) -- The Container Network Interface spec that defines how network plugins integrate with container runtimes; essential for understanding how Calico, Cilium, Flannel, and others plug in.
- [Life of a Packet in Kubernetes (KubeCon talk by Ricardo Katz)](https://www.youtube.com/watch?v=0Omvgd7Hg1I) -- KubeCon presentation tracing a network packet from a client through Services, kube-proxy, and CNI to a destination pod.
- [CoreDNS Documentation](https://coredns.io/manual/toc/) -- Reference for the default DNS server in Kubernetes, covering service discovery, custom DNS entries, and plugin-based extensibility.
- [iptables vs. IPVS for kube-proxy](https://www.tigera.io/blog/comparing-kube-proxy-modes-iptables-or-ipvs/) -- Tigera blog post comparing the two kube-proxy modes, including performance benchmarks and guidance on when to switch to IPVS.
- [Kubernetes Networking Deep Dive (KubeCon talk by Laurent Bernaille & Bowei Du)](https://www.youtube.com/watch?v=tq9ng_Nz9j8) -- In-depth walkthrough of how pod networking, Services, and DNS work together under the hood.
- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/) -- The next-generation Kubernetes API for L7 routing, replacing Ingress with a more expressive and role-oriented model.

---

Next: [The Ecosystem](06-ecosystem.md)

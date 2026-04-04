# Chapter 11: Bootstrapping a Cluster --- From kube-up.sh to kubeadm

```
Timeline: Cluster Bootstrap Tools

2014          2016          2018          2020          2022          2024
  |             |             |             |             |             |
  v             v             v             v             v             v
kube-up.sh    kubeadm       kubeadm GA    k3s mature    Managed K8s   Managed K8s
(GCE only)    (alpha)       kops GA       kind 0.9      dominates     >70% of
              minikube      kubespray     k0s 0.9                     production
              kops alpha    k3s launch

              ──────────── Increasing abstraction ────────────>

              "Provision     "Bootstrap    "Single        "You don't
              and install    on existing   binary, no     even think
              everything"    machines"     dependencies"  about it"
```

## The Problem: What Does It Actually Take to Run Kubernetes?

Before examining the tools, consider what bootstrapping a Kubernetes cluster requires. This is not a trivial task. At minimum, you must:

1. **Generate a Public Key Infrastructure (PKI).** Kubernetes components communicate over mutually authenticated TLS. The API server needs a certificate. Each kubelet needs a certificate. etcd needs certificates. The front proxy needs certificates. A typical cluster has 10+ certificates, each with specific Subject Alternative Names, key usages, and expiration policies. Getting any of these wrong results in cryptic TLS handshake failures.

2. **Deploy and configure etcd.** etcd must form a quorum, which means each member must know about the others. In a multi-node etcd cluster, the initial bootstrap is a chicken-and-egg problem: members need to discover each other before they can form a cluster.

3. **Configure the API server.** The API server needs to know where etcd is, which certificates to use, which admission controllers to enable, which authentication methods to support, and how to reach the kubelet on each node.

4. **Configure the controller manager and scheduler.** Both need kubeconfig files with credentials to authenticate to the API server.

5. **Join worker nodes.** Each worker node needs a kubelet configured with the correct API server address and authentication credentials. The node needs a container runtime installed and configured. It needs kube-proxy or a replacement for service networking.

6. **Install cluster networking.** Kubernetes mandates that every pod can communicate with every other pod without NAT. This requires a CNI (Container Network Interface) plugin, which must be installed after the control plane is running but before workloads can function.

7. **Install DNS.** Kubernetes assumes that a cluster DNS service (CoreDNS) is available. Services are discovered by DNS name, and without DNS, almost nothing works correctly.

Each of these steps has dependencies on the others. Certificates must be generated before any component can start. etcd must be running before the API server can start. The API server must be running before the controller manager, scheduler, or any kubelets can connect. Networking must be installed before pods can communicate. The ordering is strict, and mistakes are difficult to diagnose.

## The Early Days: kube-up.sh

In 2014-2015, the primary way to create a Kubernetes cluster was a shell script called **kube-up.sh**. This script attempted to do everything: provision cloud resources (VMs, networks, firewalls, load balancers), install Kubernetes binaries, generate certificates, configure all components, and join nodes into a cluster.

The script was massive --- thousands of lines of bash --- and was built primarily for Google Compute Engine (GCE). It had branches for AWS and other providers, but these were maintained with varying degrees of quality. The fundamental problem was that kube-up.sh conflated two very different concerns:

- **Infrastructure provisioning**: creating VMs, networks, and storage. This is cloud-provider-specific and depends on each provider's API, authentication model, and resource semantics.
- **Cluster bootstrapping**: installing and configuring Kubernetes on machines that already exist. This is (or should be) cloud-agnostic.

By combining both concerns in a single script, kube-up.sh was fragile, difficult to debug, and nearly impossible to extend. If you wanted to customize the VM size, the network topology, or the operating system, you had to modify the script. If the script failed halfway through, there was no reliable way to resume. If you wanted to bootstrap Kubernetes on bare metal or on a cloud provider that kube-up.sh did not support, you were on your own.

The script was also undocumented in any meaningful way. Understanding what it did required reading thousands of lines of bash, following variable expansions across multiple files, and understanding the implicit assumptions about the environment. This was the era when "setting up a Kubernetes cluster" was a multi-day project that required deep expertise.

## kubeadm: Separating Bootstrap from Provisioning

The Kubernetes community recognized that the solution was to separate concerns. Infrastructure provisioning should be handled by tools designed for that purpose --- Terraform, CloudFormation, Ansible, or cloud-provider CLIs. Cluster bootstrapping should be handled by a dedicated tool that assumed machines already existed and focused exclusively on turning those machines into a Kubernetes cluster.

**kubeadm** emerged from SIG Cluster Lifecycle in 2016, reached beta in Kubernetes 1.11, and became GA in Kubernetes 1.13 (December 2018). Its design principles were explicit:

- **Scope limitation**: kubeadm bootstraps a cluster on existing machines. It does not provision infrastructure.
- **Composability**: kubeadm is designed to be a building block for higher-level tools. kops, kubespray, and managed Kubernetes services all use kubeadm internally.
- **Phases**: the bootstrap process is broken into discrete, independently executable phases. If something fails, you can re-run a specific phase without starting over.

### What kubeadm Actually Does

When you run `kubeadm init` on a machine destined to be a control plane node, it executes the following phases:

**Preflight checks.** kubeadm verifies that the machine meets requirements: the container runtime is installed and running, required kernel modules are loaded, required ports are available, swap is disabled (Kubernetes historically required this because the scheduler's resource accounting assumed no swap), and the machine has sufficient resources.

**PKI generation.** kubeadm generates the entire certificate authority hierarchy: a root CA, an API server certificate, kubelet client certificates, front proxy certificates, etcd CA and certificates, and service account signing keys. Each certificate has appropriate SANs and key usages. This single phase eliminates what was previously one of the most error-prone manual steps.

**Static pod manifests.** Rather than running control plane components as system services, kubeadm writes static pod manifests to `/etc/kubernetes/manifests/`. The kubelet watches this directory and automatically creates pods for any manifests it finds. This means the API server, controller manager, scheduler, and etcd all run as pods on the control plane node --- Kubernetes managing itself. This approach is elegant: it means the same mechanisms that manage user workloads also manage the control plane.

```
kubeadm init: What Happens

  Machine with kubelet + container runtime installed
  │
  ├─ Phase 1: Preflight checks
  │   └─ Verify container runtime, ports, kernel modules, resources
  │
  ├─ Phase 2: Generate PKI
  │   └─ CA, API server cert, kubelet certs, etcd certs, SA keys
  │   └─ Writes to /etc/kubernetes/pki/
  │
  ├─ Phase 3: Generate kubeconfig files
  │   └─ admin.conf, kubelet.conf, controller-manager.conf, scheduler.conf
  │
  ├─ Phase 4: Write static pod manifests
  │   └─ /etc/kubernetes/manifests/kube-apiserver.yaml
  │   └─ /etc/kubernetes/manifests/kube-controller-manager.yaml
  │   └─ /etc/kubernetes/manifests/kube-scheduler.yaml
  │   └─ /etc/kubernetes/manifests/etcd.yaml
  │
  ├─ Phase 5: Wait for control plane
  │   └─ kubelet reads manifests, starts pods, API server becomes healthy
  │
  ├─ Phase 6: Upload configuration
  │   └─ Store cluster config in ConfigMap for future joins
  │
  ├─ Phase 7: Generate bootstrap token
  │   └─ Short-lived token for worker nodes to join
  │
  └─ Phase 8: Install addons
      └─ CoreDNS (cluster DNS)
      └─ kube-proxy (service networking)
```

**Bootstrap tokens.** kubeadm generates a short-lived token that worker nodes use to authenticate with the API server during the join process. This solves the chicken-and-egg problem of node authentication: the node needs credentials to talk to the API server, but the API server needs to verify the node's identity. The bootstrap token provides initial trust, and the node uses it to request a proper kubelet certificate through the TLS bootstrap protocol.

**Addon installation.** kubeadm installs CoreDNS (for cluster DNS) and kube-proxy (for service networking) as cluster addons. These are deployed as regular Kubernetes workloads, managed by the same control plane they support.

## The Alternatives: Different Problems, Different Tools

kubeadm solved the bootstrap problem but deliberately left the provisioning problem to others. This created space for tools that combined provisioning and bootstrapping, each optimized for different use cases.

### kops (Kubernetes Operations)

**kops** took the opposite approach from kubeadm: it handled both provisioning and bootstrapping. Originally built for AWS, kops could create VPCs, subnets, auto-scaling groups, security groups, IAM roles, Route53 DNS entries, and S3 state storage, then install and configure Kubernetes across the provisioned infrastructure.

kops was opinionated and comprehensive. It stored cluster state in a cloud storage bucket (S3 on AWS) and could perform rolling updates, upgrade Kubernetes versions, and resize clusters. For AWS users who wanted a production-grade, self-managed Kubernetes cluster without a managed service, kops was often the best choice.

The tradeoff was scope. kops did so much that understanding what it was doing --- and debugging it when things went wrong --- required understanding both AWS infrastructure and Kubernetes internals. It was also tightly coupled to specific cloud providers, primarily AWS, with later support for GCE and OpenStack.

### kubespray

**kubespray** used Ansible playbooks to install Kubernetes on existing machines. It supported a wide range of operating systems, container runtimes, and network plugins. kubespray was the tool of choice for organizations that already used Ansible for configuration management, had bare-metal infrastructure, or needed to customize every aspect of the installation.

kubespray occupied the middle ground between kubeadm's minimalism and kops' full-stack approach. It assumed you had provisioned machines (like kubeadm) but handled more of the pre-requisite setup than kubeadm did (installing container runtimes, configuring kernel parameters, setting up load balancers for HA control planes).

### k3s

**k3s**, created by Rancher Labs (later acquired by SUSE), took a radically different approach. Instead of a collection of separate binaries with complex interdependencies, k3s packaged the entire Kubernetes distribution into a **single binary** under 100MB.

k3s achieved this by making several substitutions:

- **SQLite instead of etcd** for the default datastore (etcd and other datastores available as options)
- **Flannel** built-in for networking
- **Traefik** built-in as the ingress controller
- **Local storage provider** built-in
- Removed legacy and alpha features, cloud provider integrations, and storage drivers that were not needed in edge/IoT scenarios

The result was a Kubernetes distribution that could run on a Raspberry Pi, start in 30 seconds, and be installed with a single curl command. k3s was certified conformant --- it passed the CNCF conformance tests --- meaning it was "real Kubernetes," just packaged differently.

k3s demonstrated that the complexity of Kubernetes installation was largely accidental, not essential. The core of Kubernetes is not that large; it was the matrix of configuration options, pluggable interfaces, and backward compatibility that made installation complex.

### kind (Kubernetes IN Docker)

**kind** solved a different problem entirely: running Kubernetes in CI/CD pipelines and for local testing. kind created a multi-node Kubernetes cluster by running each "node" as a Docker container. Inside each container, it ran the kubelet and a container runtime (containerd), creating a nested container architecture.

kind was fast (cluster creation in under a minute), lightweight (no VMs required), and disposable (clusters could be created and destroyed as part of a test pipeline). It became the standard tool for testing Kubernetes itself --- the Kubernetes CI infrastructure uses kind to run conformance tests.

### minikube

**minikube** was the original local Kubernetes development tool, created alongside kubeadm in 2016. It ran a single-node Kubernetes cluster inside a VM (or later, a container). minikube was the tool most developers encountered first when learning Kubernetes. It prioritized ease of use and supported add-ons for common development needs: dashboards, metrics, registries, and ingress controllers.

### k0s

**k0s** (zero friction Kubernetes) followed k3s' single-binary approach but aimed to be closer to upstream Kubernetes with fewer opinionated substitutions. k0s packaged all control plane components into a single binary and supported running the control plane and worker components separately, making it suitable for both single-node and multi-node deployments.

## The Managed Service Explosion

The most significant development in cluster bootstrapping was the emergence of managed Kubernetes services that made bootstrapping irrelevant for a large portion of users.

**Google Kubernetes Engine (GKE)**, launched in 2015, was the first. Google managed the control plane --- etcd, API server, controller manager, scheduler --- as a service. Users only managed worker nodes (and later, with Autopilot mode, not even that). GKE's early availability gave it a lasting advantage: it had years of operational experience that competitors could not quickly replicate.

**Azure Kubernetes Service (AKS)** launched in 2017, and **Amazon Elastic Kubernetes Service (EKS)** launched in 2018. AWS was notably late to the Kubernetes party, having bet heavily on its own orchestration system (ECS) before market demand forced its hand. EKS's eventual success validated Kubernetes as the industry standard: when the largest cloud provider builds a managed service for your project, you have won.

By the mid-2020s, managed Kubernetes services account for the majority of production Kubernetes usage. For many organizations, the question "how do I bootstrap a Kubernetes cluster?" has been replaced by "which managed service should I use?" The bootstrapping tools --- kubeadm, kops, kubespray --- remain essential for on-premises deployments, specialized environments, and educational purposes, but the center of gravity has shifted decisively toward managed services.

```
Who Uses What (2024+)

  Use Case                          Tool
  ─────────────────────────────     ──────────────────────
  Production (cloud)                Managed: GKE, EKS, AKS
  Production (on-premises)          kubeadm + kubespray, or k0s/k3s
  Production (AWS, self-managed)    kops
  Edge / IoT / Raspberry Pi         k3s
  CI/CD testing                     kind
  Local development                 minikube, kind, Docker Desktop
  Learning                          minikube, kind, k3s
```

The evolution of bootstrapping tools mirrors a broader pattern in infrastructure software: complexity moves from the user to the platform. In 2014, bootstrapping a cluster required deep expertise in Linux administration, PKI, and distributed systems. By 2024, it requires a credit card and a cloud provider account. The knowledge is still valuable --- someone has to build and operate those managed services --- but the barrier to entry for Kubernetes users has dropped by orders of magnitude.

## Common Mistakes and Misconceptions

- **"kubeadm is only for learning."** kubeadm is used in production by many organizations. It handles TLS bootstrapping, certificate rotation, and upgrade orchestration. Managed services are easier, but kubeadm is production-grade.
- **"k3s is not real Kubernetes."** k3s is a certified, conformant Kubernetes distribution. It passes the same conformance tests as full K8s. It just has a smaller binary and uses SQLite instead of etcd by default.
- **"I should use minikube/kind for production."** These tools are for local development and CI. They run single-node clusters without HA, proper networking, or persistent storage guarantees.

## Further Reading

- [kubeadm documentation](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/) -- Official reference for the standard cluster bootstrapping tool. Covers `kubeadm init`, `kubeadm join`, certificate management, and upgrade procedures.
- [kops GitHub repository](https://github.com/kubernetes/kops) -- The Kubernetes Operations project for deploying production clusters on AWS, GCE, and other clouds. The docs include architecture decisions and comparison with other tools.
- [kubespray documentation](https://kubespray.io/) -- Ansible-based cluster provisioning that supports bare metal, AWS, GCE, Azure, and more. Useful for understanding the infrastructure-as-code approach to cluster bootstrapping.
- [k3s documentation](https://docs.k3s.io/) -- Rancher's lightweight Kubernetes distribution designed for edge, IoT, and resource-constrained environments. Explains the trade-offs made to shrink Kubernetes into a single binary.
- [Rancher documentation](https://ranchermanager.docs.rancher.com/) -- Multi-cluster management platform that abstracts over different bootstrap methods. Covers fleet management, RBAC, and the operational layer above individual clusters.
- [kind (Kubernetes in Docker)](https://kind.sigs.k8s.io/) -- A tool for running local Kubernetes clusters using Docker containers as nodes. Designed for testing Kubernetes itself, and widely used in CI/CD pipelines.
- [minikube documentation](https://minikube.sigs.k8s.io/docs/) -- The original local Kubernetes tool, supporting multiple drivers (Docker, VirtualBox, HyperKit, etc.). Remains the most approachable path for developers learning Kubernetes.

---

**Next:** [Chapter 12: Package Management and GitOps](12-package-management.md)

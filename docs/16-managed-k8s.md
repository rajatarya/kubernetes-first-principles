# Chapter 16: Managed Kubernetes: EKS, GKE, and AKS

Running your own control plane is an excellent way to learn Kubernetes. It is a terrible way to run production workloads. The control plane --- etcd, the API server, the controller manager, the scheduler --- requires careful backup, monitoring, upgrade orchestration, and high-availability configuration. Managed Kubernetes services take this burden off your team so you can focus on what runs *on* the cluster rather than what runs *the* cluster.

But "managed" does not mean "fully operated." Every cloud provider draws the line differently between what they manage and what remains your responsibility. Understanding exactly where that line falls is essential for making an informed choice.

## The Shared Responsibility Model

```
MANAGED KUBERNETES: WHO MANAGES WHAT?
──────────────────────────────────────

          Cloud Provider Manages           │        You Manage
          ─────────────────────            │        ──────────
                                           │
  ┌─────────────────────────────────┐      │  ┌─────────────────────────────────┐
  │  Control Plane                  │      │  │  Worker Nodes                   │
  │  ┌───────────┐  ┌────────────┐ │      │  │  ┌───────────┐  ┌───────────┐  │
  │  │ API Server│  │ Controller │ │      │  │  │  kubelet  │  │ Your Pods │  │
  │  │ (HA, TLS) │  │ Manager    │ │      │  │  │           │  │           │  │
  │  └───────────┘  └────────────┘ │      │  │  └───────────┘  └───────────┘  │
  │  ┌───────────┐  ┌────────────┐ │      │  │  ┌───────────┐  ┌───────────┐  │
  │  │ Scheduler │  │    etcd    │ │      │  │  │ kube-proxy│  │ CNI agent │  │
  │  │           │  │ (backups)  │ │      │  │  │           │  │           │  │
  │  └───────────┘  └────────────┘ │      │  │  └───────────┘  └───────────┘  │
  │                                │      │  │                                │
  │  Upgrades, patches, HA,       │      │  │  OS patching, scaling,         │
  │  etcd backups, API cert       │      │  │  node upgrades, app deploys,   │
  │  rotation                     │      │  │  networking config, storage,   │
  └─────────────────────────────────┘      │  │  security policies, RBAC      │
                                           │  └─────────────────────────────────┘
                                           │
  * GKE Autopilot: Google also manages     │  * With node auto-upgrade enabled,
    the worker nodes and their sizing      │    the provider patches node OS
```

All three major providers manage the control plane: they run the API server, etcd, controller manager, and scheduler in a highly available configuration that you never directly access. You interact with the API server through a managed endpoint. etcd is backed up automatically. Control plane upgrades are handled by the provider (though you still decide *when* to upgrade).

What remains your responsibility in all cases: your application workloads, your RBAC policies, your network policies, your storage configuration, your monitoring, your cost management.

## GKE: Google Kubernetes Engine

GKE is the most mature managed Kubernetes service. Google invented Kubernetes from Borg, and GKE reflects that lineage --- it is typically the first to adopt new Kubernetes features and the most opinionated about best practices.

**Networking.** GKE uses a **VPC-native** networking model with **Alias IPs**. Each node is allocated a secondary IP range from the VPC. Pods receive IPs from this secondary range. These are real VPC IPs --- they are routable within the VPC without overlay networks or encapsulation. This means VPC firewall rules, routes, and VPC peering work natively with pod IPs.

**Autopilot mode.** GKE offers two modes: Standard (you manage node pools) and Autopilot (Google manages everything, including node provisioning and sizing). In Autopilot mode, you submit workloads and Google provisions the right amount of compute. You pay per pod resource request, not per node. Autopilot enforces security best practices by default: workloads run as non-root, privilege escalation is blocked, and host path mounts are disallowed.

**Upgrades.** GKE is typically the fastest to support new Kubernetes versions. It offers release channels (Rapid, Regular, Stable) that automatically upgrade the control plane and node pools on a schedule. Surge upgrades create extra nodes to maintain capacity during rolling node upgrades.

**Pricing.** $0.10/hr for the cluster management fee (Standard mode). Autopilot charges per pod resource request instead.

### GKE Strengths
- Fastest Kubernetes version adoption
- Autopilot removes node management entirely
- VPC-native networking eliminates overlay complexity
- Tight integration with Google Cloud networking (Cloud NAT, Cloud Armor, Internal Load Balancers)
- Binary Authorization for supply chain security

### GKE Weaknesses
- Smaller ecosystem of third-party integrations compared to AWS
- Autopilot restrictions may be too opinionated for some workloads
- Vendor lock-in to GCP networking model

## EKS: Amazon Elastic Kubernetes Service

EKS is the most widely used managed Kubernetes service, reflecting AWS's dominant market position. It is also the most "assembly required" of the three --- AWS provides the control plane and expects you to configure everything else.

**Networking.** EKS uses the **AWS VPC CNI plugin**, which assigns pods real VPC IP addresses from Elastic Network Interfaces (ENIs). Each EC2 instance has a limit on the number of ENIs it can attach and the number of secondary IPs per ENI. This means **pod density is limited by instance type**:

| Instance Type | Max ENIs | IPs per ENI | Max Pods |
|--------------|----------|-------------|----------|
| t3.nano | 2 | 2 | ~4 |
| t3.medium | 3 | 6 | ~17 |
| m5.large | 3 | 10 | ~29 |
| m5.xlarge | 4 | 15 | ~58 |
| m5.24xlarge | 15 | 50 | ~737 |

This is a critical capacity planning consideration. If you run many small pods, you may hit the pod limit before you exhaust CPU or memory. AWS offers **prefix delegation** to increase pod density by assigning /28 prefixes instead of individual IPs.

**Node management.** EKS offers three options: self-managed nodes (EC2 instances you configure), managed node groups (AWS manages the EC2 lifecycle), and Fargate (serverless pods, similar to GKE Autopilot but per-pod). **Karpenter** is AWS's open-source node autoscaler, which provisions right-sized nodes based on pending pod requirements --- it is faster and more flexible than the Cluster Autoscaler.

**Upgrades.** EKS upgrades are the most manual of the three providers. You upgrade the control plane first (one API call or console click), then upgrade each node group separately. There is no automatic release channel for control plane upgrades. You must actively track Kubernetes versions and initiate upgrades.

**Pricing.** $0.10/hr for the cluster ($72/month). EKS on Fargate adds a per-pod charge.

### EKS Strengths
- Largest ecosystem --- most third-party tools are tested on EKS first
- Deep AWS integration (IAM roles for service accounts, ALB Ingress Controller, EBS CSI driver)
- Karpenter for intelligent, fast node autoscaling
- Most flexibility in configuration
- AWS marketplace of EKS add-ons

### EKS Weaknesses
- Most manual upgrade process
- VPC CNI pod density limits require careful instance type selection
- More "assembly required" than GKE or AKS

## AKS: Azure Kubernetes Service

AKS differentiates primarily on pricing: the control plane is **free** in the Free tier. You pay only for the worker node VMs. This makes AKS the cheapest option for development and testing clusters.

**Networking.** AKS offers two networking models. **kubenet** is a basic overlay network where pods get IPs from a virtual network that is not routable in the VPC (Azure calls it VNet). **Azure CNI** assigns pods real VNet IPs, similar to AWS VPC CNI and GKE Alias IPs. Azure CNI Overlay is a newer option that provides Azure CNI features without consuming VNet IPs for every pod.

**Upgrades.** AKS has the fastest security patching cadence. It supports automatic upgrades through channels (none, patch, stable, rapid, node-image). Node image upgrades can be applied independently from Kubernetes version upgrades.

**Pricing.** Free tier: $0 for the control plane. Standard tier: $0.10/hr (adds SLA and more features). Premium tier: $0.60/hr (adds long-term support versions).

### AKS Strengths
- Free control plane in Free tier
- Fastest security patching
- Strong integration with Azure Active Directory for RBAC
- Azure Arc extends AKS management to on-premises and other clouds
- AKS Automatic mode (similar to GKE Autopilot)

### AKS Weaknesses
- Azure networking can be complex (VNet peering, NSG interactions)
- Historically slower Kubernetes version adoption than GKE
- Smaller Kubernetes-specific community than AWS

## Comparison Table

| Feature | GKE | EKS | AKS |
|---------|-----|-----|-----|
| **Control plane cost** | $0.10/hr | $0.10/hr | Free (Free tier) |
| **Serverless pods** | Autopilot | Fargate | Virtual Nodes |
| **Pod networking** | Alias IPs (VPC-native) | VPC CNI (ENI-based) | Azure CNI or kubenet |
| **Pod IP routable in VPC?** | Yes | Yes | Yes (Azure CNI) |
| **Default node autoscaler** | Cluster Autoscaler | Karpenter / CA | Cluster Autoscaler / KEDA |
| **Upgrade automation** | Release channels | Manual initiation | Upgrade channels |
| **Version adoption speed** | Fastest | Moderate | Moderate |
| **Identity integration** | Google IAM + Workload Identity | IAM Roles for Service Accounts | Azure AD + Workload Identity |
| **Service mesh** | Anthos Service Mesh | App Mesh / Istio | Open Service Mesh / Istio |
| **GPU support** | Yes (multi-GPU, TPU) | Yes (GPU, Inferentia, Trainium) | Yes (GPU) |
| **Max nodes per cluster** | 15,000 | 5,000 (soft limit) | 5,000 |

## When to Choose Each

**Choose GKE when:**
- You want the most automated, opinionated experience
- You are already on Google Cloud or are starting fresh
- You want Autopilot to eliminate node management
- You need fast access to the latest Kubernetes features
- You are running ML/AI workloads with TPU requirements

**Choose EKS when:**
- You are already on AWS (most organizations are)
- You need maximum flexibility and control
- Your team has AWS expertise
- You need deep integration with the AWS ecosystem (Lambda, SQS, DynamoDB)
- You want Karpenter for intelligent autoscaling

**Choose AKS when:**
- You are already on Azure or have an Enterprise Agreement
- You want a free control plane for dev/test
- You use Azure Active Directory for identity management
- You need hybrid cloud with Azure Arc
- You want the cheapest entry point for learning

**Choose self-managed (kubeadm) when:**
- You are on-premises with no cloud option
- You have strict regulatory requirements about where the control plane runs
- You are learning Kubernetes internals
- You need control over every component's configuration

## The Hidden Costs

The control plane fee is the smallest part of the bill. The real costs are:

- **Worker node compute**: The VMs or instances running your pods (typically 80-90% of the bill)
- **Load balancers**: Each Service of type LoadBalancer creates a cloud load balancer ($15-25/month each)
- **NAT gateways**: Required for private clusters to reach the internet ($30-45/month + data processing fees)
- **Persistent storage**: EBS volumes, Persistent Disks, Managed Disks ($0.08-0.10/GB/month for SSD)
- **Data transfer**: Cross-AZ traffic is charged on all three clouds ($0.01-0.02/GB)
- **Monitoring and logging**: CloudWatch, Cloud Monitoring, Azure Monitor charges for ingestion and storage

A "free" AKS control plane cluster running three m5.large worker nodes with a load balancer, NAT gateway, and 100 GB of persistent storage will cost approximately $300-400/month before data transfer.

## Further Reading

- [GKE documentation](https://cloud.google.com/kubernetes-engine/docs) --- Comprehensive guides for Standard and Autopilot modes
- [EKS documentation](https://docs.aws.amazon.com/eks/) --- Setup guides, best practices, and blueprints
- [AKS documentation](https://learn.microsoft.com/en-us/azure/aks/) --- Getting started, networking, and security guides
- [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/) --- AWS's official best practices for EKS
- [Karpenter documentation](https://karpenter.sh/) --- Intelligent node autoscaling for Kubernetes
- [GKE Autopilot overview](https://cloud.google.com/kubernetes-engine/docs/concepts/autopilot-overview) --- Understanding the fully managed mode
- [KubeCon talks on YouTube](https://www.youtube.com/@caborhood) --- CNCF conference presentations on real-world managed K8s usage
- [CNCF Slack #eks, #gke, #aks channels](https://slack.cncf.io/) --- Community support for each provider

---

*Next: [Cloud Networking and Storage](17-cloud-integration.md)*

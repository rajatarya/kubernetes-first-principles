# Appendix C: Decision Trees

Kubernetes offers many options for the same problem. These decision trees encode the trade-offs discussed throughout the book into quick-reference flowcharts.

---

## 1. Which Workload Controller?

Kubernetes provides several controllers for running workloads, each designed for a different scheduling pattern. [Chapter 18](18-first-workloads.md) covers Deployments and Services, [Chapter 21](21-statefulsets.md) covers StatefulSets, [Chapter 24](24-jobs.md) covers Jobs and CronJobs, and [Chapter 42](42-llm-infrastructure.md) covers LeaderWorkerSet for ML gang scheduling. Start by asking whether your workload is stateless.

```mermaid
flowchart TD
    A[New Workload] --> B{Stateless?}
    B -->|Yes| C([Deployment])
    B -->|No| D{Need stable identity<br>or ordering?}
    D -->|Yes| E([StatefulSet])
    D -->|No| F{Run on every node?}
    F -->|Yes| G([DaemonSet])
    F -->|No| H{Run to completion?}
    H -->|Yes| I([Job])
    H -->|No| J{Run on schedule?}
    J -->|Yes| K([CronJob])
    J -->|No| L(["LeaderWorkerSet + Volcano<br>(ML gang scheduling)"])
```

---

## 2. Which Service Type?

Every application that receives traffic needs a Service, but Kubernetes offers five types with very different behaviors. [Chapter 18](18-first-workloads.md) introduces ClusterIP and NodePort, [Chapter 17](17-cloud-integration.md) covers LoadBalancer integration with cloud providers, and [Chapter 13](13-networking-evolution.md) discusses Ingress and the newer Gateway API.

```mermaid
flowchart TD
    A[Expose a Service] --> B{Internal only?}
    B -->|Yes| C([ClusterIP])
    B -->|No| D{External DNS name<br>only, no proxy?}
    D -->|Yes| E([ExternalName])
    D -->|No| F{Need L7 routing<br>by host or path?}
    F -->|Yes| G(["Ingress / Gateway API"])
    F -->|No| H{Dev/test only?}
    H -->|Yes| I([NodePort])
    H -->|No| J(["LoadBalancer<br>(L4 TCP/UDP)"])
```

---

## 3. Which Storage?

Storage decisions depend on durability, access patterns, and whether multiple pods need simultaneous access. [Chapter 23](23-storage.md) covers PersistentVolumes, StorageClasses, and CSI drivers in depth. [Chapter 17](17-cloud-integration.md) explains how cloud providers implement storage backends.

```mermaid
flowchart TD
    A[Need Storage] --> B{Ephemeral — survives<br>container restart?}
    B -->|Yes| C([emptyDir])
    B -->|No| D{Shared across pods<br>ReadWriteMany?}
    D -->|Yes| E(["NFS / EFS<br>(RWX PVC)"])
    D -->|No| F{High IOPS database?}
    F -->|Yes| G(["Local SSD / io2<br>(PVC + StorageClass)"])
    F -->|No| H{Object storage?}
    H -->|Yes| I(["S3 / GCS<br>(use SDK, not a PV)"])
    H -->|No| J(["PVC + StorageClass<br>(general purpose)"])
```

---

## 4. Which Autoscaler?

Kubernetes scaling operates at two levels: pod-level (adding replicas or resizing resource requests) and node-level (adding machines when pods can't be scheduled). [Chapter 30](30-hpa.md) covers HPA, [Chapter 31](31-vpa.md) covers VPA, [Chapter 32](32-node-scaling.md) covers Karpenter and Cluster Autoscaler, and [Chapter 33](33-resource-tuning.md) explains how resource requests feed into scheduling.

```mermaid
flowchart TD
    A[Need Autoscaling] --> B{Scale pods or nodes?}
    B -->|Pods| C{Horizontal —<br>more replicas?}
    B -->|Nodes| D{Running on AWS?}
    C -->|Yes| E([HPA])
    C -->|No| F{Right-size resources?}
    F -->|Yes| G([VPA])
    F -->|No| H(["KEDA<br>(event-driven, queues, etc.)"])
    D -->|Yes| I([Karpenter])
    D -->|No| J(["Cluster Autoscaler<br>(GCP / Azure / on-prem)"])
```

---

## 5. Which Managed Kubernetes?

The choice between managed and self-managed Kubernetes depends on your infrastructure constraints and operational maturity. [Chapter 16](16-managed-k8s.md) compares EKS, GKE, and AKS in detail. [Chapter 15](15-cluster-setup.md) covers kubeadm for self-managed clusters, and [Chapter 11](11-cluster-bootstrap.md) covers k3s and other lightweight distributions.

```mermaid
flowchart TD
    A[Choose Managed K8s] --> B{On-premises?}
    B -->|Yes| C(["kubeadm / k3s / Rancher"])
    B -->|No| D{Which cloud?}
    D -->|AWS| E(["EKS<br>(see Karpenter for node scaling)"])
    D -->|GCP| F[GKE] --> G{Zero node management?}
    G -->|Yes| H([GKE Autopilot])
    G -->|No| I([GKE Standard])
    D -->|Azure| J[AKS] --> K(["AKS Free tier<br>(free control plane, dev)"])
```

---

## 6. Which CNI?

The Container Network Interface plugin determines how pods get IP addresses and how network traffic flows between nodes. Most managed clusters default to the cloud provider's native CNI, but self-managed clusters require an explicit choice. [Chapter 13](13-networking-evolution.md) traces the evolution from Flannel through Calico to Cilium and explains the eBPF performance advantage.

```mermaid
flowchart TD
    A[Choose a CNI] --> B{Managed cloud cluster?}
    B -->|Yes| C(["Use provider default<br>(VPC CNI / Azure CNI / GKE native)"])
    B -->|No| D{Need eBPF, no<br>iptables overhead?}
    D -->|Yes| E([Cilium])
    D -->|No| F{Need NetworkPolicy?}
    F -->|Yes| G([Calico])
    F -->|No| H(["Flannel<br>(simple overlay)"])
```

---

## 7. Which Package Manager?

Managing Kubernetes YAML at scale requires tooling — the question is which kind. Helm uses Go templates for parameterization and dominates third-party chart distribution. Kustomize uses overlay-based patching without any template language. Many teams combine both. [Chapter 12](12-package-management.md) covers all three approaches and explains when to use each.

```mermaid
flowchart TD
    A["Package / Template<br>K8s Manifests"] --> B{Need type-safe<br>code generation?}
    B -->|Yes| C([cdk8s])
    B -->|No| D{Need Go-template style<br>parameterization?}
    D -->|Yes| E(["Helm<br>(most popular for 3rd-party<br>chart distribution)"])
    D -->|No| F{Want patch-based overlays<br>without templates?}
    F -->|Yes| G([Kustomize])
    F -->|Both| H(["helm template |<br>kustomize build<br>(common hybrid)"])
```

---

## 8. Which Secret Management?

Secrets require special handling: they must not appear in plain text in Git, they may need to rotate automatically, and they often originate from an external vault or cloud provider. [Chapter 28](28-secrets.md) covers Kubernetes Secrets and encryption at rest, Sealed Secrets for GitOps, and integration with HashiCorp Vault and cloud secret managers via the External Secrets Operator.

```mermaid
flowchart TD
    A[Manage Secrets] --> B{Need external secret store<br>— Vault, AWS SM?}
    B -->|Yes| C{Need auto-rotation?}
    B -->|No| D{Storing in Git<br>for GitOps?}
    C -->|Yes| E(["Vault + sidecar injector<br>(dynamic secrets)"])
    C -->|No| F(["External Secrets Operator<br>+ Vault / AWS Secrets Manager"])
    D -->|Yes| G(["Sealed Secrets<br>(encrypt before committing)"])
    D -->|No| H(["K8s Secrets +<br>encryption at rest<br>(simple, low security)"])
```

---

## 9. Which GitOps Tool?

GitOps applies the Kubernetes reconciliation pattern to deployment itself: a controller watches a Git repository and ensures the cluster matches. The two major tools are ArgoCD and Flux, which differ primarily in UI richness and multi-cluster management. [Chapter 12](12-package-management.md) covers both, and [Chapter 34](34-multi-cluster.md) discusses multi-cluster GitOps patterns.

```mermaid
flowchart TD
    A[Adopt GitOps] --> B{Need rich UI, multi-cluster,<br>app-of-apps pattern?}
    B -->|Yes| C([ArgoCD])
    B -->|No| D{Want lightweight, Git-native,<br>Helm/Kustomize controller?}
    D -->|Yes| E([Flux])
    D -->|Both| F(["They can coexist:<br>Flux for infra clusters,<br>Argo for app clusters"])
```

---

## 10. StatefulSet vs Operator for Databases?

Running databases on Kubernetes is possible but requires careful consideration. A managed cloud database (RDS, Cloud SQL) avoids the operational burden entirely. If you must run on K8s, operators like CloudNativePG and Percona handle failover, backups, and scaling automatically. A raw StatefulSet works for dev/staging but lacks production automation. [Chapter 22](22-databases.md) covers this decision in depth, and [Chapter 37](37-operators.md) explains the operator pattern.

```mermaid
flowchart TD
    A[Run a Database on K8s] --> B{Managed DB available<br>— RDS, Cloud SQL, etc.?}
    B -->|Yes| C(["Use managed DB<br>(provision via Crossplane<br>or Terraform)"])
    B -->|No| D{Production with failover,<br>backup, scaling?}
    D -->|Yes| E(["Use an Operator<br>(CloudNativePG, Percona,<br>Strimzi, etc.)"])
    D -->|No| F(["StatefulSet<br>(simple, single instance,<br>dev/staging)"])
```

---

*Back to [Table of Contents](00-README.md)*

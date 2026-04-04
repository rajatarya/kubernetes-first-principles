# Appendix C: Decision Trees

Kubernetes offers many options for the same problem. These decision trees encode the trade-offs discussed throughout the book into quick-reference flowcharts.

---

## 1. Which Workload Controller?

```
                        ┌─────────────────┐
                        │  New Workload    │
                        └────────┬────────┘
                                 │
                        ┌────────▼────────┐
                        ◇  Stateless?     ◇
                        └──┬───────────┬──┘
                       yes │           │ no
                           │           │
                  ┌────────▼──┐  ┌─────▼──────────────┐
                  │ Deployment │  ◇ Need stable        ◇
                  └────────────┘  ◇ identity/ordering? ◇
                                  └──┬──────────────┬──┘
                                 yes │              │ no
                                     │              │
                            ┌────────▼────┐  ┌──────▼──────────┐
                            │ StatefulSet  │  ◇ Run on every   ◇
                            └─────────────┘  ◇ node?           ◇
                                              └──┬──────────┬──┘
                                             yes │          │ no
                                                 │          │
                                       ┌─────────▼──┐ ┌────▼──────────┐
                                       │  DaemonSet  │ ◇ Run to       ◇
                                       └─────────────┘ ◇ completion?  ◇
                                                        └──┬───────┬──┘
                                                       yes │       │ no
                                                           │       │
                                                    ┌──────▼─┐ ┌───▼───────────┐
                                                    │  Job   │ ◇ Run on        ◇
                                                    └────────┘ ◇ schedule?     ◇
                                                                └──┬────────┬──┘
                                                               yes │        │ no
                                                                   │        │
                                                          ┌────────▼──┐ ┌───▼──────────────┐
                                                          │  CronJob  │ │ LeaderWorkerSet  │
                                                          └───────────┘ │ + Volcano        │
                                                                        │ (ML gang sched.) │
                                                                        └──────────────────┘
```

---

## 2. Which Service Type?

```
                        ┌──────────────────┐
                        │  Expose a Service │
                        └────────┬─────────┘
                                 │
                        ┌────────▼────────┐
                        ◇ Internal only?  ◇
                        └──┬───────────┬──┘
                       yes │           │ no
                           │           │
                 ┌─────────▼───┐ ┌─────▼──────────────┐
                 │  ClusterIP  │ ◇ External DNS name  ◇
                 └─────────────┘ ◇ only (no proxy)?   ◇
                                  └──┬──────────────┬──┘
                                 yes │              │ no
                                     │              │
                          ┌──────────▼──────┐ ┌─────▼─────────────┐
                          │  ExternalName   │ ◇ Need L7 routing   ◇
                          └─────────────────┘ ◇ (host/path)?      ◇
                                               └──┬────────────┬──┘
                                              yes │            │ no
                                                  │            │
                                    ┌─────────────▼──────┐ ┌───▼──────────────┐
                                    │ Ingress /          │ ◇ Dev/test only?   ◇
                                    │ Gateway API        │ └──┬────────────┬──┘
                                    └────────────────────┘ yes│            │ no
                                                              │            │
                                                    ┌─────────▼──┐ ┌──────▼───────┐
                                                    │  NodePort   │ │ LoadBalancer │
                                                    └─────────────┘ │ (L4 TCP/UDP)│
                                                                    └──────────────┘
```

---

## 3. Which Storage?

```
                        ┌──────────────────┐
                        │  Need Storage    │
                        └────────┬─────────┘
                                 │
                        ┌────────▼─────────────┐
                        ◇ Ephemeral (survives  ◇
                        ◇ container restart)?  ◇
                        └──┬────────────────┬──┘
                       yes │                │ no (need persistence)
                           │                │
                  ┌────────▼───┐  ┌─────────▼──────────────┐
                  │  emptyDir  │  ◇ Shared across pods     ◇
                  └────────────┘  ◇ (ReadWriteMany)?       ◇
                                  └──┬──────────────────┬──┘
                               yes   │                  │ no
                                     │                  │
                          ┌──────────▼──────┐  ┌────────▼──────────┐
                          │ NFS / EFS       │  ◇ High IOPS        ◇
                          │ (RWX PVC)       │  ◇ database?        ◇
                          └─────────────────┘  └──┬────────────┬──┘
                                              yes │            │ no
                                                  │            │
                                     ┌────────────▼─────┐ ┌───▼──────────────┐
                                     │ Local SSD / io2  │ ◇ Object storage?  ◇
                                     │ (PVC + SC)       │ └──┬────────────┬──┘
                                     └──────────────────┘ yes│            │ no
                                                             │            │
                                                  ┌──────────▼──────┐ ┌───▼──────────────┐
                                                  │ S3 / GCS       │ │ PVC +            │
                                                  │ (use SDK, not  │ │ StorageClass     │
                                                  │  a PV)         │ │ (general purpose)│
                                                  └─────────────────┘ └──────────────────┘
```

---

## 4. Which Autoscaler?

```
                        ┌─────────────────────┐
                        │  Need Autoscaling   │
                        └────────┬────────────┘
                                 │
                        ┌────────▼──────────────┐
                        ◇ Scale pods or nodes?  ◇
                        └──┬─────────────────┬──┘
                      pods │                 │ nodes
                           │                 │
              ┌────────────▼──────┐  ┌───────▼──────────────┐
              ◇ Horizontal        ◇  ◇ Running on AWS?      ◇
              ◇ (more replicas)?  ◇  └──┬────────────────┬──┘
              └──┬─────────────┬──┘ yes │                │ no
             yes │             │ no     │                │
                 │             │   ┌────▼──────┐  ┌──────▼──────────┐
          ┌──────▼──┐  ┌───────▼───────┐      │  │ Cluster          │
          │  HPA    │  ◇ Right-size    ◇      │  │ Autoscaler       │
          └─────────┘  ◇ resources?    ◇ ┌────▼──────┐  │ (GCP/Azure/   │
                       └──┬─────────┬──┘ │ Karpenter │  │  on-prem)     │
                      yes │         │ no └───────────┘  └───────────────┘
                          │         │
                   ┌──────▼──┐ ┌────▼──────────┐
                   │  VPA    │ │ KEDA           │
                   └─────────┘ │ (event-driven, │
                               │  queues, etc.) │
                               └────────────────┘
```

---

## 5. Which Managed Kubernetes?

```
                        ┌──────────────────────┐
                        │  Choose Managed K8s  │
                        └────────┬─────────────┘
                                 │
                        ┌────────▼─────────────┐
                        ◇ On-premises?         ◇
                        └──┬────────────────┬──┘
                       yes │                │ no (cloud)
                           │                │
              ┌────────────▼──────┐  ┌──────▼──────────────┐
              │ kubeadm / k3s /  │  ◇ Which cloud?        ◇
              │ Rancher          │  └──┬───────┬────────┬──┘
              └───────────────────┘  AWS│    GCP│     Azure│
                                       │       │         │
                               ┌───────▼──┐ ┌──▼──────┐ ┌▼────────┐
                               │   EKS    │ │  GKE    │ │  AKS    │
                               └───────┬──┘ └──┬──────┘ └──┬──────┘
                                       │       │           │
                                       │  ┌────▼────────┐  │
                                       │  ◇ Zero node   ◇  │
                                       │  ◇ management? ◇  │
                                       │  └──┬───────┬──┘  │
                                       │ yes │       │ no  │
                                       │     │       │     │
                                       │ ┌───▼─────────┐  ┌▼──────────────┐
                                       │ │ GKE         │  │ AKS Free tier │
                                       │ │ Autopilot   │  │ (free control │
                                       │ └─────────────┘  │  plane, dev)  │
                                       │                  └───────────────┘
                                       │
                              (EKS: see Karpenter
                               for node scaling)
```

---

## 6. Which CNI?

```
                        ┌──────────────────┐
                        │  Choose a CNI    │
                        └────────┬─────────┘
                                 │
                        ┌────────▼──────────────┐
                        ◇ Managed cloud cluster? ◇
                        └──┬─────────────────┬──┘
                       yes │                 │ no (self-managed)
                           │                 │
              ┌────────────▼──────────┐ ┌────▼──────────────────┐
              │ Use provider default  │ ◇ Need eBPF, no        ◇
              │ (VPC CNI / Azure CNI  │ ◇ iptables overhead?   ◇
              │  / GKE native)        │ └──┬────────────────┬──┘
              └───────────────────────┘ yes │                │ no
                                            │                │
                                   ┌────────▼──┐  ┌──────────▼──────────┐
                                   │  Cilium   │  ◇ Need NetworkPolicy? ◇
                                   └───────────┘  └──┬───────────────┬──┘
                                                 yes │               │ no
                                                     │               │
                                            ┌────────▼──┐  ┌─────────▼─────┐
                                            │  Calico   │  │  Flannel      │
                                            └───────────┘  │  (simple      │
                                                           │   overlay)    │
                                                           └───────────────┘
```

---

## 7. Which Package Manager?

```
                        ┌──────────────────────┐
                        │  Package / Template  │
                        │  K8s Manifests       │
                        └────────┬─────────────┘
                                 │
                        ┌────────▼──────────────────┐
                        ◇ Need type-safe code gen?  ◇
                        └──┬─────────────────────┬──┘
                       yes │                     │ no
                           │                     │
                  ┌────────▼──┐    ┌─────────────▼─────────────┐
                  │  cdk8s    │    ◇ Need Go-template style    ◇
                  └───────────┘    ◇ parameterization?         ◇
                                   └──┬─────────────────────┬──┘
                               yes    │                     │ no
                                      │                     │
                             ┌────────▼──┐  ┌───────────────▼───────────┐
                             │   Helm    │  ◇ Want patch-based overlays ◇
                             └─────┬─────┘  ◇ without templates?       ◇
                                   │        └──┬─────────────────────┬──┘
                                   │       yes │                     │ both
                                   │           │                     │
                                   │  ┌────────▼─────┐  ┌───────────▼───────────┐
                                   │  │  Kustomize   │  │ helm template |       │
                                   │  └──────────────┘  │ kustomize build       │
                                   │                    │ (common hybrid)       │
                                   │                    └───────────────────────┘
                                   │
                          (Helm is also the most
                           popular for 3rd-party
                           chart distribution)
```

---

## 8. Which Secret Management?

```
                        ┌───────────────────────┐
                        │  Manage Secrets       │
                        └────────┬──────────────┘
                                 │
                        ┌────────▼──────────────────┐
                        ◇ Need external secret      ◇
                        ◇ store (Vault, AWS SM)?     ◇
                        └──┬─────────────────────┬──┘
                       yes │                     │ no
                           │                     │
              ┌────────────▼──────────────┐ ┌────▼─────────────────────┐
              ◇ Need auto-rotation?       ◇ ◇ Storing in Git (GitOps)? ◇
              └──┬─────────────────────┬──┘ └──┬────────────────────┬──┘
             yes │                     │ no yes │                    │ no
                 │                     │       │                    │
     ┌───────────▼──────────┐  ┌───────▼──────────────┐  ┌─────────▼──────────┐
     │ Vault + sidecar      │  │ External Secrets     │  │ Sealed Secrets     │
     │ injector             │  │ Operator + Vault /   │  │ (encrypt before    │
     │ (dynamic secrets)    │  │ AWS Secrets Manager  │  │  committing)       │
     └──────────────────────┘  └──────────────────────┘  └────────────────────┘
                                                                    │
                                                         ┌──────────▼──────────┐
                                                         │ K8s Secrets +       │
                                                         │ encryption at rest  │
                                                         │ (simple, low-sec)   │
                                                         └─────────────────────┘
```

---

## 9. Which GitOps Tool?

```
                        ┌───────────────────┐
                        │  Adopt GitOps     │
                        └────────┬──────────┘
                                 │
                        ┌────────▼──────────────────────┐
                        ◇ Need rich UI, multi-cluster,  ◇
                        ◇ app-of-apps pattern?          ◇
                        └──┬─────────────────────────┬──┘
                       yes │                         │ no
                           │                         │
              ┌────────────▼──────┐    ┌─────────────▼─────────────────┐
              │     ArgoCD       │    ◇ Want lightweight, Git-native, ◇
              └──────────────────┘    ◇ Helm/Kustomize controller?   ◇
                                      └──┬────────────────────────┬──┘
                                     yes │                        │ both
                                         │                        │
                                ┌────────▼──┐    ┌────────────────▼──────────┐
                                │   Flux    │    │ They can coexist:        │
                                └───────────┘    │ Flux for infra clusters, │
                                                 │ Argo for app clusters    │
                                                 └──────────────────────────┘
```

---

## 10. StatefulSet vs Operator for Databases?

```
                        ┌──────────────────────────┐
                        │  Run a Database on K8s   │
                        └────────┬─────────────────┘
                                 │
                        ┌────────▼──────────────────┐
                        ◇ Managed DB available      ◇
                        ◇ (RDS, Cloud SQL, etc.)?   ◇
                        └──┬─────────────────────┬──┘
                       yes │                     │ no
                           │                     │
              ┌────────────▼──────────────┐ ┌────▼──────────────────────┐
              │ Use managed DB            │ ◇ Production with failover, ◇
              │ (provision via Crossplane │ ◇ backup, scaling?          ◇
              │  or Terraform)           │ └──┬─────────────────────┬──┘
              └───────────────────────────┘ yes│                     │ no
                                               │                     │
                                  ┌────────────▼───────────┐  ┌──────▼──────────┐
                                  │ Use an Operator        │  │ StatefulSet     │
                                  │ (CloudNativePG,        │  │ (simple, single │
                                  │  Percona, Strimzi,     │  │  instance, dev/ │
                                  │  etc.)                 │  │  staging)       │
                                  └────────────────────────┘  └─────────────────┘
```

---

*Back to [Table of Contents](00-README.md)*

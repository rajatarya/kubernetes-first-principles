# Chapter 17: Cloud Networking and Storage

Kubernetes defines abstractions --- Services, PersistentVolumes, Ingress --- but it does not implement them. The implementation is provided by cloud-specific controllers and plugins. Understanding how these abstractions map to real cloud infrastructure is the difference between writing YAML that works and writing YAML that works *well*.

## How Pod Networking Maps to Cloud Networking

In Chapter 5, we established that every pod gets its own IP and all pods can reach all other pods without NAT. In a cloud environment, this flat network must be implemented on top of the cloud's virtual networking layer. Each cloud takes a different approach, and the choice has real consequences for performance, pod density, and network policy enforcement.

### AWS VPC CNI: Pods as First-Class VPC Citizens

The AWS VPC CNI plugin gives each pod a real VPC IP address. It does this by leveraging Elastic Network Interfaces (ENIs), which are virtual network cards that can be attached to EC2 instances.

```
AWS VPC CNI: HOW PODS GET IPS
──────────────────────────────

EC2 Instance (m5.large)
┌──────────────────────────────────────────────────┐
│                                                  │
│  Primary ENI (eth0)                              │
│  ┌────────────────────────────────────┐          │
│  │ Primary IP: 10.0.1.100 (node IP)  │          │
│  │ Secondary IP: 10.0.1.101 → Pod A  │          │
│  │ Secondary IP: 10.0.1.102 → Pod B  │          │
│  │ Secondary IP: 10.0.1.103 → Pod C  │          │
│  │ ...up to 10 IPs per ENI           │          │
│  └────────────────────────────────────┘          │
│                                                  │
│  Secondary ENI (eth1)                            │
│  ┌────────────────────────────────────┐          │
│  │ Primary IP: 10.0.1.200            │          │
│  │ Secondary IP: 10.0.1.201 → Pod D  │          │
│  │ Secondary IP: 10.0.1.202 → Pod E  │          │
│  │ ...up to 10 IPs per ENI           │          │
│  └────────────────────────────────────┘          │
│                                                  │
│  Secondary ENI (eth2)                            │
│  ┌────────────────────────────────────┐          │
│  │ Primary IP: 10.0.1.210            │          │
│  │ Secondary IP: 10.0.1.211 → Pod F  │          │
│  │ ...                               │          │
│  └────────────────────────────────────┘          │
│                                                  │
│  m5.large: 3 ENIs x 10 IPs = ~29 max pods       │
│                                                  │
└──────────────────────────────────────────────────┘

Pod A (10.0.1.101) can reach Pod X (10.0.2.55) on another
node directly through VPC routing. No encapsulation.
No overlay. Just VPC route tables.
```

The IPAMD (IP Address Management Daemon) runs on each node as part of the VPC CNI. It pre-allocates ENIs and warms secondary IPs so that new pods get IPs quickly. When a pod is scheduled, the CNI assigns a pre-warmed IP from the pool.

**Advantages**: No overlay network. No encapsulation overhead. Pod IPs are routable in the VPC, so VPC security groups, NACLs, VPC Flow Logs, and VPC peering work natively with pod traffic.

**Trade-off**: Pod density is constrained by the instance type's ENI and IP limits. A `t3.nano` can run approximately 4 pods. An `m5.large` can run approximately 29. This matters: if you run many small pods (sidecars, agents), you may exhaust the IP limit before CPU or memory. Enable **prefix delegation** to assign /28 prefixes (16 IPs each) instead of individual IPs, dramatically increasing pod density.

### GKE Alias IPs: VPC-Native Pods

GKE's VPC-native mode uses **Alias IP ranges**. Each node is assigned a secondary IP range (e.g., a /24 from the pod CIDR), and pods receive IPs from this range. These are real VPC IPs routable within the GCP VPC.

The mechanism is different from AWS (no ENI concept), but the result is similar: pod IPs are part of the VPC address space, and VPC firewall rules and routes work natively. GKE allocates IP ranges at the node level, which avoids the per-instance-type density limits that constrain AWS.

### On-Premises: Why Overlay Networks Are Necessary

On-premises clusters lack the cloud's SDN (Software-Defined Networking) layer. The physical network routers do not know about pod CIDRs. An overlay network --- VXLAN (used by Flannel, Calico), Geneve (used by Cilium), or IP-in-IP (used by Calico) --- encapsulates pod traffic inside packets addressed to node IPs, which the physical network can route.

```
OVERLAY vs. CLOUD-NATIVE NETWORKING
────────────────────────────────────

Cloud-Native (AWS VPC CNI, GKE Alias IPs):
  Pod A ──► [Packet: src=10.0.1.101, dst=10.0.2.55] ──► VPC Router ──► Pod X
  No encapsulation. Direct routing.

On-Prem Overlay (VXLAN):
  Pod A ──► [Outer: src=192.168.1.10, dst=192.168.1.20]
            [VXLAN header]
            [Inner: src=10.244.1.5, dst=10.244.2.8]     ──► Physical Switch ──► Pod X
  Pod packet wrapped inside a node-to-node packet.
  ~50 bytes overhead per packet. Physical network only sees node IPs.
```

The overlay approach works everywhere but adds latency (encapsulation/decapsulation), reduces MTU (the inner packet must be smaller than the outer packet), and makes network debugging harder (tcpdump on the physical network shows encapsulated traffic). Cloud-native CNI plugins avoid all of this by integrating with the cloud's routing layer.

## How Storage Maps to Cloud Infrastructure

Kubernetes storage abstractions --- PersistentVolumes (PV), PersistentVolumeClaims (PVC), and StorageClasses --- map to specific cloud storage services through the Container Storage Interface (CSI).

### Storage Access Modes

| Access Mode | Abbreviation | Meaning | Cloud Examples |
|-------------|-------------|---------|----------------|
| ReadWriteOnce | RWO | One node can mount read-write | EBS, GCE PD, Azure Managed Disk |
| ReadOnlyMany | ROX | Many nodes can mount read-only | EBS (snapshot-based), GCE PD |
| ReadWriteMany | RWX | Many nodes can mount read-write | EFS, Filestore, Azure Files |
| ReadWriteOncePod | RWOP | One pod can mount read-write | EBS (since CSI spec 1.5) |

The most common mistake is requesting RWX for a workload that only needs RWO. Block storage (EBS, GCE PD, Azure Managed Disks) is RWO --- a single volume can only be attached to one node at a time. If you need shared storage across multiple pods on different nodes, you must use a file storage service (EFS, Filestore, Azure Files) or a distributed storage system (Ceph, GlusterFS).

### Cloud Storage Mapping

| Kubernetes Concept | AWS | GCP | Azure |
|-------------------|-----|-----|-------|
| RWO PersistentVolume | EBS (gp3, io2) | GCE Persistent Disk (pd-balanced, pd-ssd) | Azure Managed Disk (Premium SSD, Standard SSD) |
| RWX PersistentVolume | EFS | Cloud Filestore | Azure Files |
| StorageClass provisioner | ebs.csi.aws.com | pd.csi.storage.gke.io | disk.csi.azure.com |
| Volume snapshots | EBS snapshots | PD snapshots | Azure Disk snapshots |

### The CSI Architecture

CSI (Container Storage Interface) is the standard that allows storage vendors to write plugins for Kubernetes without modifying Kubernetes itself. The architecture has two components deployed differently:

```
CSI ARCHITECTURE
────────────────

┌─────────────────────────────────────────────────────────┐
│                    CONTROL PLANE                         │
│                                                         │
│  CSI Controller Plugin (Deployment, 1-3 replicas)       │
│  ┌───────────────────────────────────────────────────┐  │
│  │                                                   │  │
│  │  ┌──────────────────┐  ┌──────────────────────┐  │  │
│  │  │ external-        │  │ external-            │  │  │
│  │  │ provisioner      │  │ attacher             │  │  │
│  │  │                  │  │                      │  │  │
│  │  │ Watches PVCs,    │  │ Watches VolumeAttach │  │  │
│  │  │ calls CSI        │  │ objects, calls CSI   │  │  │
│  │  │ CreateVolume()   │  │ ControllerPublish()  │  │  │
│  │  └────────┬─────────┘  └────────┬─────────────┘  │  │
│  │           │                     │                 │  │
│  │  ┌────────▼─────────────────────▼─────────────┐  │  │
│  │  │         CSI Driver (controller mode)        │  │  │
│  │  │                                             │  │  │
│  │  │  Translates CSI calls to cloud API calls:   │  │  │
│  │  │  CreateVolume() → aws ec2 create-volume     │  │  │
│  │  │  ControllerPublish() → aws ec2 attach-vol   │  │  │
│  │  └─────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│                    EVERY NODE                            │
│                                                         │
│  CSI Node Plugin (DaemonSet, one per node)              │
│  ┌───────────────────────────────────────────────────┐  │
│  │                                                   │  │
│  │  ┌──────────────────┐                             │  │
│  │  │ node-driver-     │                             │  │
│  │  │ registrar        │  Registers the CSI driver   │  │
│  │  │                  │  with the kubelet            │  │
│  │  └────────┬─────────┘                             │  │
│  │           │                                       │  │
│  │  ┌────────▼───────────────────────────────────┐   │  │
│  │  │         CSI Driver (node mode)              │   │  │
│  │  │                                             │   │  │
│  │  │  NodeStageVolume() → format + mount to      │   │  │
│  │  │                      staging path           │   │  │
│  │  │  NodePublishVolume() → bind mount into      │   │  │
│  │  │                       pod's filesystem      │   │  │
│  │  └─────────────────────────────────────────────┘   │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

The **Controller Plugin** runs as a Deployment (typically 1-3 replicas). It handles volume lifecycle operations that do not require node-level access: creating volumes, deleting volumes, creating snapshots, and attaching volumes to nodes (at the cloud API level).

The **Node Plugin** runs as a DaemonSet (one per node). It handles operations that require access to the node's filesystem: formatting the volume, mounting it, and bind-mounting it into the pod's filesystem.

**Sidecar containers** bridge between Kubernetes and CSI. They watch Kubernetes API objects and translate them into CSI calls:

- `external-provisioner`: Watches PVCs, calls `CreateVolume()`
- `external-attacher`: Watches VolumeAttachment objects, calls `ControllerPublishVolume()`
- `external-snapshotter`: Watches VolumeSnapshot objects, calls `CreateSnapshot()`
- `external-resizer`: Watches PVC size changes, calls `ControllerExpandVolume()`
- `node-driver-registrar`: Registers the CSI driver with kubelet

### Dynamic Provisioning Flow

When you create a PVC with a StorageClass, the following sequence occurs:

```
DYNAMIC PROVISIONING FLOW
──────────────────────────

1. User creates PVC
   ┌──────────────────────────────┐
   │ kind: PersistentVolumeClaim  │
   │ spec:                        │
   │   storageClassName: gp3      │
   │   resources:                 │
   │     requests:                │
   │       storage: 50Gi          │
   └──────────┬───────────────────┘
              │
              ▼
2. external-provisioner sees unbound PVC
   with storageClassName matching its driver
              │
              ▼
3. Calls CSI CreateVolume() → cloud creates EBS volume
              │
              ▼
4. Creates PV object bound to the PVC
              │
              ▼
5. Pod is scheduled to a node
              │
              ▼
6. external-attacher sees VolumeAttachment →
   calls CSI ControllerPublishVolume() →
   cloud attaches EBS to EC2 instance
              │
              ▼
7. Node plugin: NodeStageVolume() formats + mounts
              │
              ▼
8. Node plugin: NodePublishVolume() bind-mounts into pod
              │
              ▼
9. Pod sees /data with 50Gi filesystem
```

### WaitForFirstConsumer: Why It Matters

StorageClasses have a `volumeBindingMode` field with two options:

- `Immediate`: The volume is created as soon as the PVC is created.
- `WaitForFirstConsumer`: The volume is not created until a pod using the PVC is scheduled.

`WaitForFirstConsumer` is critical for availability-zone-aware storage. EBS volumes, GCE PDs, and Azure Managed Disks are **zonal** --- they exist in a specific availability zone. If a PVC creates an EBS volume in `us-east-1a` immediately, but the scheduler places the pod in `us-east-1b`, the volume cannot be attached. `WaitForFirstConsumer` delays volume creation until the pod is scheduled, so the volume is created in the same AZ as the node.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-waitforfirstconsumer
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
```

Always use `WaitForFirstConsumer` for zonal block storage. The only exception is if you are running a single-AZ cluster.

### Volume Snapshots

CSI volume snapshots allow point-in-time copies of PersistentVolumes. The workflow uses three objects:

```yaml
# 1. VolumeSnapshotClass (like StorageClass but for snapshots)
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: ebs-snapshot-class
driver: ebs.csi.aws.com
deletionPolicy: Delete

---
# 2. VolumeSnapshot (request a snapshot of an existing PVC)
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: my-app-snapshot
spec:
  volumeSnapshotClassName: ebs-snapshot-class
  source:
    persistentVolumeClaimName: my-app-data

---
# 3. Restore from snapshot (create a PVC from the snapshot)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-data-restored
spec:
  storageClassName: gp3
  dataSource:
    name: my-app-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
```

This is the foundation for backup workflows. Tools like Velero use CSI snapshots internally.

## Common Mistakes and Misconceptions

- **"All storage classes perform the same."** gp3 vs io2 vs local NVMe have vastly different IOPS, throughput, and cost profiles. Match storage class to workload requirements, especially for databases.
- **"Cross-AZ traffic is free."** All three major clouds charge $0.01-0.02/GB for cross-AZ data transfer. High-traffic services with pods spread across AZs can accumulate significant costs.
- **"I should use one big VPC for everything."** Separate VPCs (or at least subnets) for dev/staging/production provide network-level isolation. VPC peering connects them when needed.

## Further Reading

- [AWS VPC CNI documentation](https://github.com/aws/amazon-vpc-cni-k8s) --- Detailed explanation of ENI-based pod networking
- [GKE VPC-native clusters](https://cloud.google.com/kubernetes-engine/docs/concepts/alias-ips) --- How Alias IPs work for pod networking
- [Azure CNI overview](https://learn.microsoft.com/en-us/azure/aks/configure-azure-cni) --- Azure CNI vs kubenet comparison
- [CSI specification](https://github.com/container-storage-interface/spec) --- The official CSI spec
- [EBS CSI driver](https://github.com/kubernetes-sigs/aws-ebs-csi-driver) --- AWS EBS CSI implementation
- [Kubernetes storage documentation](https://kubernetes.io/docs/concepts/storage/) --- Official PV, PVC, and StorageClass docs
- [Volume snapshot documentation](https://kubernetes.io/docs/concepts/storage/volume-snapshots/) --- CSI snapshot workflow

---

*Next: [Your First Workloads](18-first-workloads.md)*

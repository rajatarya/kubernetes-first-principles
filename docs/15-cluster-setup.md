# Chapter 15: Setting Up a Cluster from Scratch

Every Kubernetes cluster begins as a collection of Linux machines that know nothing about each other. Something must generate the certificates, write the configuration files, start the control plane processes, and establish the trust relationships that let workers join.

## What kubeadm Actually Does

kubeadm is the official bootstrapping tool. When you run `kubeadm init`, it executes 10 phases in sequence. Each phase solves a specific problem in the bootstrap chain.

```
kubeadm init
│
├── 1. preflight          Validate the node can become a control plane
├── 2. certs              Generate the entire PKI hierarchy
├── 3. kubeconfig         Generate kubeconfig files for each component
├── 4. kubelet-start       Configure and start the kubelet
├── 5. control-plane      Write static pod manifests for control plane
├── 6. etcd               Write static pod manifest for local etcd
├── 7. upload-config      Store kubeadm and kubelet config in ConfigMaps
├── 8. upload-certs       (optional) Upload certs for HA join
├── 9. mark-control-plane Taint and label the node
├── 10. bootstrap-token    Create token for worker node joining
├── 11. kubelet-finalize   Update kubelet config for TLS bootstrap
├── 12. addon              Install CoreDNS and kube-proxy
│
▼
Control plane is running. Workers can join.
```

Let us walk through each phase in detail.

### Phase 1: Preflight Checks

Before touching anything, kubeadm validates that the system meets the minimum requirements. This includes:

- **Swap is disabled.** The kubelet refuses to start if swap is enabled (by default) because the scheduler's resource accounting assumes no swap; swap breaks memory limit enforcement.
- **Required ports are available.** The API server needs port 6443, etcd needs 2379-2380, the scheduler needs 10259, the controller manager needs 10257. If another process occupies these ports, the control plane cannot start.
- **Container runtime is reachable.** kubeadm checks for a CRI-compatible runtime (containerd or CRI-O) at the expected socket path.
- **cgroup driver matches.** The kubelet and the container runtime must agree on whether to use `cgroupfs` or `systemd` as the cgroup driver. A mismatch causes containers to start in the wrong cgroup hierarchy, breaking resource accounting. Since Kubernetes 1.22, `systemd` is the recommended default.
- **Required kernel modules and sysctl settings** are present (br_netfilter, ip_forward).

### Phase 2: Certificate Generation

This is the most important phase. Kubernetes is a distributed system where every component authenticates to every other component using mutual TLS. kubeadm generates the entire PKI hierarchy and writes it to `/etc/kubernetes/pki/`.

```
PKI HIERARCHY
─────────────

/etc/kubernetes/pki/
│
├── ca.crt / ca.key                    ◄── Cluster Root CA
│   │
│   ├── apiserver.crt / apiserver.key         API server serving cert
│   ├── apiserver-kubelet-client.crt/key      API server → kubelet client cert
│   ├── front-proxy-ca.crt / .key      ◄── Front Proxy CA (aggregation layer)
│   │   └── front-proxy-client.crt/key        Aggregation layer client cert
│   │
│   └── (kubeconfig embedded certs)
│       ├── admin client cert                 kubectl access
│       ├── controller-manager client cert    controller-manager → API server
│       └── scheduler client cert             scheduler → API server
│
├── etcd/
│   ├── ca.crt / ca.key                ◄── etcd Root CA (separate trust domain)
│   ├── server.crt / server.key               etcd server serving cert
│   ├── peer.crt / peer.key                   etcd peer-to-peer communication
│   └── healthcheck-client.crt/key            Health check client cert
│
├── apiserver-etcd-client.crt/key             API server → etcd client cert
│
└── sa.key / sa.pub                           Service account signing keypair
```

Two separate CAs exist by design. The cluster CA signs all Kubernetes component certificates. The etcd CA signs all etcd certificates. This separation means a compromise of the cluster CA does not automatically grant access to etcd, and vice versa. The API server holds a client certificate signed by the etcd CA, which is how it authenticates to etcd.

The service account keypair (`sa.key` / `sa.pub`) is used by the controller manager to sign service account tokens and by the API server to verify them. This is not a CA --- it is a signing key for JWTs.

### Phase 3: kubeconfig Generation

kubeadm generates four kubeconfig files in `/etc/kubernetes/`:

| File | Used By | Purpose |
|------|---------|---------|
| `admin.conf` | kubectl (cluster admin) | Full cluster access |
| `controller-manager.conf` | kube-controller-manager | Authenticate to API server |
| `scheduler.conf` | kube-scheduler | Authenticate to API server |
| `kubelet.conf` | kubelet on the control plane node | Authenticate to API server |

Each kubeconfig file embeds a client certificate (signed by the cluster CA) and the CA certificate for verifying the API server. This is mutual TLS: the component authenticates to the API server, and the API server authenticates back to the component.

### Phase 4-6: Static Pod Manifests and the Bootstrap Problem

Here is the fundamental bootstrap problem: the API server, controller manager, scheduler, and etcd must run as containers, but the kubelet cannot pull their pod specs from an API server that does not yet exist. This is a circular dependency.

Kubernetes solves this with **static pods**. The kubelet can read pod manifests directly from a local directory (`/etc/kubernetes/manifests/`) and run them without any API server involvement. kubeadm writes four manifest files:

```
/etc/kubernetes/manifests/
├── kube-apiserver.yaml
├── kube-controller-manager.yaml
├── kube-scheduler.yaml
└── etcd.yaml
```

The kubelet detects these files, creates the pods, and monitors them. If a static pod crashes, the kubelet restarts it. Once the API server is running, the kubelet creates **mirror pods** in the API --- read-only representations that make static pods visible through `kubectl get pods -n kube-system`, even though the API server does not manage them.

This is one of the most elegant solutions in Kubernetes' design. The kubelet operates in two modes simultaneously: it manages static pods from local files (for bootstrapping) and regular pods from the API server (for everything else).

### Phase 7-9: Configuration and Node Marking

kubeadm stores its own configuration and the kubelet's configuration as ConfigMaps in the `kube-system` namespace. This serves two purposes: it documents how the cluster was initialized, and it provides configuration for worker nodes joining later.

The control plane node is tainted with `node-role.kubernetes.io/control-plane:NoSchedule` so that regular workloads are not scheduled onto it. This is a convention, not a hard rule --- you can remove this taint on single-node clusters.

### Phase 10: Bootstrap Tokens and the TLS Bootstrap Handshake

When a worker node joins the cluster, it needs to authenticate to the API server. But it has no certificate yet --- that is what it is trying to obtain. This is solved by the **TLS bootstrap** protocol.

```
TLS BOOTSTRAP HANDSHAKE
────────────────────────

Worker Node                              Control Plane
─────────────                            ─────────────
    │                                         │
    │  1. kubeadm join --token abc123         │
    │     (token was generated during init)   │
    │                                         │
    │  2. Connect to API server on port 6443  │
    │     Verify server cert against          │
    │     discovery token CA cert hash        │
    │──────────────────────────────────────►  │
    │                                         │
    │  3. Authenticate with bootstrap token   │
    │     (token maps to a service account    │
    │      with permission to create CSRs)    │
    │──────────────────────────────────────►  │
    │                                         │
    │  4. Create CertificateSigningRequest    │
    │     "I am node X, give me a cert"       │
    │──────────────────────────────────────►  │
    │                                         │
    │  5. Controller auto-approves the CSR    │
    │     (csrapproving controller)           │
    │                                         │
    │  6. Signed certificate returned         │
    │◄──────────────────────────────────────  │
    │                                         │
    │  7. Kubelet now uses real cert for      │
    │     all future API server communication │
    │                                         │
    ▼                                         ▼
```

The bootstrap token is a short-lived, low-privilege credential. It grants exactly one permission: the ability to create a CertificateSigningRequest. The `csrapproving` controller in the controller manager automatically approves CSRs from bootstrap tokens (for the first certificate). The worker receives a signed certificate and uses it for all subsequent communication. The bootstrap token can now be revoked.

The `--discovery-token-ca-cert-hash` flag prevents man-in-the-middle attacks during the initial connection. The worker verifies the API server's certificate against this hash before sending the bootstrap token.

### Phase 11-12: Addons

kubeadm installs two mandatory addons as Deployments:

- **CoreDNS**: Provides cluster DNS. Pods resolve service names (e.g., `my-svc.my-namespace.svc.cluster.local`) through CoreDNS.
- **kube-proxy**: Runs as a DaemonSet on every node. Manages iptables or IPVS rules that implement Service routing.

Note that kubeadm does **not** install a CNI plugin. This is deliberate: the choice of CNI plugin is a critical networking decision that kubeadm leaves to the operator. Until a CNI plugin is installed, pods on the control plane node will be stuck in `Pending` and nodes will show as `NotReady`.

## Using a kubeadm Configuration File

While `kubeadm init` accepts dozens of CLI flags, production usage should always use a YAML configuration file. This makes the cluster setup reproducible and auditable.

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.32.0
controlPlaneEndpoint: "k8s-api.example.com:6443"
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
  dnsDomain: "cluster.local"
apiServer:
  certSANs:
    - "k8s-api.example.com"
    - "10.0.0.100"
  extraArgs:
    - name: "audit-log-path"
      value: "/var/log/kubernetes/audit.log"
etcd:
  local:
    dataDir: "/var/lib/etcd"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: "unix:///var/run/containerd/containerd.sock"
  kubeletExtraArgs:
    - name: "cgroup-driver"
      value: "systemd"
```

Run with: `kubeadm init --config=kubeadm-config.yaml`

The `controlPlaneEndpoint` is critical for HA clusters. It should point to a load balancer in front of multiple API server instances. Setting it during initial setup avoids painful reconfiguration later.

## Kubernetes the Hard Way

Kelsey Hightower's *Kubernetes the Hard Way* is a 13-lab exercise that provisions a cluster by hand, without kubeadm. The labs (updated for v1.32.x) walk you through:

1. Generating every certificate by hand (you will appreciate kubeadm's Phase 2 after this)
2. Writing every kubeconfig file manually
3. Configuring etcd from scratch
4. Writing systemd unit files for every component
5. Configuring kubelet and kube-proxy on each worker
6. Setting up pod networking manually

What *The Hard Way* teaches that kubeadm hides:

- **The CA is just files.** There is no magic PKI server. You generate a CA key, use it to sign certificates, and distribute them. Understanding this demystifies all of Kubernetes' authentication.
- **The API server is just a binary with flags.** Every feature --- authentication methods, authorization modes, admission controllers --- is controlled by command-line flags to `kube-apiserver`.
- **Networking is not built-in.** You must configure routing tables or install a CNI plugin yourself. This makes you understand why CNI exists.
- **etcd is independent.** It runs as its own cluster and can be inspected with `etcdctl` independently of Kubernetes.

Do *The Hard Way* once, then use kubeadm for everything after. The exercise takes 4-8 hours and permanently changes how you think about clusters.

## Common Pitfalls

| Problem | Symptom | Fix |
|---------|---------|-----|
| Swap enabled | kubelet refuses to start | `swapoff -a` and remove swap from `/etc/fstab` |
| cgroup driver mismatch | Pods fail with cgroup errors | Ensure kubelet and containerd both use `systemd` |
| Port 6443 in use | API server fails to bind | Check for existing processes: `ss -tlnp \| grep 6443` |
| Firewall blocking | Workers cannot join | Open 6443, 2379-2380, 10250, 10259, 10257 |
| CNI not installed | All pods stuck in Pending, nodes NotReady | Install a CNI plugin (Calico, Cilium, Flannel) |
| Wrong podSubnet | CNI and kubeadm disagree on pod CIDR | Match `podSubnet` in kubeadm config with CNI config |
| Expired bootstrap token | Workers cannot join after 24h | Generate new token: `kubeadm token create --print-join-command` |

## Common Mistakes and Misconceptions

- **"One control plane node is enough for production."** A single control plane is a single point of failure. Production clusters need 3 or 5 control plane nodes for etcd quorum and API server HA.
- **"Worker nodes should be as large as possible."** Fewer large nodes means each node failure impacts more pods. Balance node size against blast radius — many medium nodes are often better than few huge ones.
- **"I can skip configuring kubelet flags."** Defaults work for learning, but production kubelets need tuning: eviction thresholds, max-pods, image garbage collection, and system reserved resources.

## Further Reading

- [kubeadm init documentation](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-init/) --- Official reference for all phases and flags
- [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way) --- Kelsey Hightower's 13-lab manual cluster setup (v1.32.x)
- [PKI certificates and requirements](https://kubernetes.io/docs/setup/best-practices/certificates/) --- Full list of certificates and their purposes
- [TLS bootstrapping](https://kubernetes.io/docs/reference/access-authn-authz/kubelet-tls-bootstrapping/) --- Deep dive into the bootstrap token protocol
- [KillerCoda kubeadm scenarios](https://killercoda.com/kubernetes) --- Interactive browser-based kubeadm exercises
- [KodeKloud CKA course](https://kodekloud.com/courses/certified-kubernetes-administrator-cka/) --- Hands-on labs covering cluster setup


---

*Next: [Managed Kubernetes: EKS, GKE, and AKS](16-managed-k8s.md)*

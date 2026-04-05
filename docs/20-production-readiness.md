# Chapter 20: Production Readiness

A cluster that runs workloads is not the same as a cluster that is ready for production. Production readiness is a checklist of capabilities that, taken together, ensure your cluster is observable, secure, recoverable, and cost-efficient.
## The Production Readiness Checklist

```
PRODUCTION READINESS
────────────────────

  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
  │  Monitoring  │  │   Logging    │  │   Security   │
  │  Prometheus  │  │  Loki / EFK  │  │  RBAC, PSS,  │
  │  Grafana     │  │              │  │  NetworkPol  │
  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
         │                 │                 │
  ┌──────▼───────┐  ┌──────▼───────┐  ┌──────▼───────┐
  │   Backup     │  │   Health     │  │  Resource    │
  │   Velero     │  │   Probes     │  │  Management  │
  │   etcd snap  │  │   PDBs       │  │  QoS, Quotas │
  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘
         │                 │                 │
         └─────────────────┼─────────────────┘
                           │
                    ┌──────▼───────┐
                    │     Cost     │
                    │  Management  │
                    │  Labels,     │
                    │  Kubecost    │
                    └──────────────┘
```

## Monitoring: Prometheus + Grafana

Monitoring answers one question: "Is my system healthy right now, and if not, where is the problem?"

### kube-prometheus-stack

The **kube-prometheus-stack** Helm chart deploys a complete monitoring pipeline:

- **Prometheus**: Scrapes metrics from all Kubernetes components, node exporters, and application pods
- **Grafana**: Dashboards for visualization and alerting
- **Alertmanager**: Routes alerts to Slack, PagerDuty, email, or other channels
- **node-exporter**: DaemonSet that exports node-level metrics (CPU, memory, disk, network)
- **kube-state-metrics**: Exports Kubernetes object state as metrics (pod status, deployment replicas, PVC capacity)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=changeme
```

This single command deploys 5+ components with pre-configured dashboards and alert rules. The default dashboards cover node health, pod resource usage, API server latency, etcd performance, and CoreDNS metrics.

### What to Monitor

| Layer | Key Metrics | Why |
|-------|-------------|-----|
| **Nodes** | CPU utilization, memory utilization, disk I/O, network I/O | Detect resource exhaustion before it causes evictions |
| **Pods** | CPU usage vs request, memory usage vs limit, restart count | Detect misconfigured resource limits and crash loops |
| **API Server** | Request latency (p99), error rate, request count | The API server is the heart of the cluster |
| **etcd** | Disk fsync duration, leader elections, DB size | etcd performance directly affects cluster responsiveness |
| **Application** | Request latency, error rate, throughput (RED metrics) | Your users care about application health, not node health |

### Golden Signals

Monitor the four golden signals for every service:

1. **Latency**: How long requests take (distinguish successful vs failed requests)
2. **Traffic**: How many requests per second
3. **Errors**: How many requests fail
4. **Saturation**: How full is the system (CPU, memory, queue depth)

## Logging: Loki or EFK

Metrics tell you *that* something is wrong. Logs tell you *why*.

### Option 1: Grafana Loki (Recommended)

Loki is a log aggregation system designed for Kubernetes. Unlike Elasticsearch, Loki **indexes only labels, not full text**. This makes it an order of magnitude cheaper to operate while remaining fast for label-based queries (which is how you search logs in Kubernetes: by pod, namespace, container, node).

```bash
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set promtail.enabled=true \
  --set grafana.enabled=false    # Use the Grafana from kube-prometheus-stack
```

Promtail runs as a DaemonSet, reads container logs from `/var/log/pods/`, and ships them to Loki with Kubernetes labels attached.

### Option 2: EFK Stack (Elasticsearch + Fluentd + Kibana)

The traditional choice. Elasticsearch provides full-text search, which is more powerful than Loki's label-based queries. The trade-off is operational complexity: Elasticsearch clusters require significant memory, careful index management, and regular maintenance.

Choose Loki if you want simplicity and cost efficiency. Choose EFK if you need full-text search across log content.

## Security

Kubernetes security is defense in depth: multiple layers, each reducing the attack surface.

### RBAC: Principle of Least Privilege

Every human user, service account, and CI/CD pipeline should have the minimum permissions required for their function. Never use `cluster-admin` for applications.

```yaml
# A Role that allows reading pods and logs in a specific namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: my-app
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
---
# Bind the role to a service account
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pod-reader-binding
  namespace: my-app
subjects:
  - kind: ServiceAccount
    name: my-app-sa
    namespace: my-app
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

Key RBAC principles:

- Use **Roles** (namespaced) over **ClusterRoles** (cluster-wide) whenever possible
- Never grant `*` (all) verbs unless absolutely necessary
- Audit RBAC regularly: `kubectl auth can-i --list --as=system:serviceaccount:my-app:my-app-sa`
- Use `kubectl auth can-i create deployments --as=jane` to test permissions

### NetworkPolicies: Default Deny

By default, every pod can communicate with every other pod --- a compromised pod can reach the entire cluster network.

Start with a **default-deny** policy in every namespace, then explicitly allow the traffic you need:

```yaml
# Default deny all ingress and egress in a namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: my-app
spec:
  podSelector: {}              # Applies to ALL pods in the namespace
  policyTypes:
    - Ingress
    - Egress

---
# Allow the web pods to receive traffic on port 80
# and make DNS queries (port 53) and reach the database
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-web-traffic
  namespace: my-app
spec:
  podSelector:
    matchLabels:
      app: web-app
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
      ports:
        - port: 80
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: database
      ports:
        - port: 5432
    - to:                       # Allow DNS
        - namespaceSelector: {}
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
```

Note: NetworkPolicies require a CNI plugin that supports them (Calico, Cilium, Weave). Flannel does not enforce NetworkPolicies.

### Pod Security Standards

Pod Security Standards (PSS) replace the deprecated PodSecurityPolicy. They define three levels:

| Level | Description | Key Restrictions |
|-------|-------------|-----------------|
| **Privileged** | Unrestricted | None |
| **Baseline** | Minimally restrictive | No hostNetwork, no hostPID, no privileged containers |
| **Restricted** | Heavily restricted | Must run as non-root, drop ALL capabilities (only NET_BIND_SERVICE may be added back), allowPrivilegeEscalation: false, seccomp RuntimeDefault or Localhost |

Apply them at the namespace level:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

Every namespace running application workloads should enforce at least `baseline`. Use `restricted` for workloads that do not need elevated privileges.

### Image Scanning

Scan container images for known vulnerabilities before deploying them. **Trivy** is the most widely used open-source scanner:

```bash
# Scan an image locally
trivy image nginx:1.27.3

# Integrate into CI/CD to fail builds with critical vulnerabilities
trivy image --exit-code 1 --severity CRITICAL my-app:v1.2.0
```

For continuous in-cluster scanning, deploy Trivy Operator, which scans running workloads and reports vulnerabilities as Kubernetes custom resources.

## Backup: Velero + etcd Snapshots

### etcd Snapshots

etcd contains the entire cluster state. Regular snapshots are non-negotiable:

```bash
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

Managed Kubernetes services handle etcd backups automatically. For self-managed clusters, automate this with a CronJob or systemd timer.

### Velero

Velero backs up Kubernetes resources (YAML manifests) and persistent volume data (via CSI snapshots). It can restore entire namespaces or specific resources to the same or a different cluster.

```bash
# Install Velero
velero install --provider aws --bucket my-backup-bucket \
  --secret-file ./credentials-velero \
  --use-volume-snapshots=true \
  --plugins velero/velero-plugin-for-aws:v1.10.0

# Create a backup of a namespace
velero backup create my-app-backup --include-namespaces my-app

# Schedule daily backups with 30-day retention
velero schedule create daily-backup \
  --schedule="0 2 * * *" \
  --include-namespaces my-app \
  --ttl 720h
```

Test your restores regularly. A backup that has never been tested is not a backup --- it is a hope.

## Health Probes: Readiness vs. Liveness vs. Startup

These three probes serve different purposes. Conflating them is one of the most common production mistakes.

| Probe | Purpose | What Happens on Failure | When to Use |
|-------|---------|------------------------|-------------|
| **Readiness** | Is the pod ready to serve traffic? | Removed from Service endpoints (stops receiving traffic) | Always. Check that the app can serve requests. |
| **Liveness** | Is the pod stuck in an unrecoverable state? | Pod is restarted | Only when the app can deadlock or hang. Check a lightweight endpoint. |
| **Startup** | Has the pod finished starting up? | Liveness/readiness probes are not run until startup succeeds | Slow-starting apps (JVM, large model loading). |

**Critical rule: keep readiness and liveness probes different.** The readiness probe should check that the application can serve requests (e.g., can it reach its database?). The liveness probe should check that the application process is not deadlocked (e.g., can it respond to a simple `/healthz` ping?). If you make them the same, a downstream dependency failure (database down) will cause liveness failures, which restarts the pod, which cannot fix a database outage, which creates a restart storm.

```yaml
startupProbe:               # Allow up to 5 minutes for slow startup
  httpGet:
    path: /healthz
    port: 8080
  failureThreshold: 30
  periodSeconds: 10

readinessProbe:              # Check full readiness (dependencies included)
  httpGet:
    path: /ready
    port: 8080
  periodSeconds: 10
  failureThreshold: 3

livenessProbe:               # Check basic aliveness (no dependency checks)
  httpGet:
    path: /healthz
    port: 8080
  periodSeconds: 20
  failureThreshold: 3
```

## PodDisruptionBudgets

When a node is drained (for upgrades, scaling down, or maintenance), Kubernetes evicts all pods on that node. Without a PodDisruptionBudget (PDB), all replicas of a Deployment on that node could be evicted simultaneously, causing downtime.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-app-pdb
spec:
  minAvailable: 2              # At least 2 pods must remain running
  selector:
    matchLabels:
      app: web-app
```

Alternatively, use `maxUnavailable: 1` to allow at most 1 pod to be disrupted at a time. PDBs are respected by `kubectl drain`, cluster autoscaler, and node upgrade processes.

## Resource Management

### LimitRanges

Set default requests and limits for a namespace, so that developers who forget to set them still get reasonable defaults:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: my-app
spec:
  limits:
    - default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      type: Container
```

### ResourceQuotas

Prevent a single namespace from consuming the entire cluster:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: namespace-quota
  namespace: my-app
spec:
  hard:
    requests.cpu: "10"
    requests.memory: 20Gi
    limits.cpu: "20"
    limits.memory: 40Gi
    pods: "50"
    persistentvolumeclaims: "10"
```

### QoS Classes Revisited

Guaranteed QoS (requests = limits) ensures critical pods are evicted last; Burstable QoS (requests < limits) allows efficient sharing for batch workloads. Avoid BestEffort --- see Chapter 18 for detail.

## Cost Management

Kubernetes makes it easy to provision resources and hard to track who is paying for them.

### Labels for Cost Attribution

Apply consistent labels to every resource:

```yaml
metadata:
  labels:
    team: platform
    environment: production
    cost-center: engineering
    app: web-app
```

Cloud providers can filter billing data by Kubernetes labels (if label propagation is enabled in the cloud integration).

### Tools

- **Kubecost**: Open-source cost monitoring. Shows cost per namespace, deployment, pod, and label. Identifies idle resources and right-sizing recommendations.
- **OpenCost**: CNCF project for Kubernetes cost monitoring. Vendor-neutral alternative to Kubecost.

### Spot Instances

Run non-critical, fault-tolerant workloads on spot/preemptible instances to reduce compute costs by 60-90%. Use node affinity and tolerations to separate spot-friendly workloads from those that need stable compute:

```yaml
# Toleration for spot instance taint
tolerations:
  - key: "kubernetes.io/spot"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
```

Combine with PDBs to ensure that spot instance reclamation does not take down all replicas simultaneously.

## Chaos Engineering

Once your cluster is observable, secured, and backed up, test that it actually survives failure.

- **Chaos Mesh**: CNCF project. Injects pod failures, network latency, disk I/O stress, and time skew.
- **Litmus**: Another CNCF chaos engineering project with a library of pre-built experiments.
- **Manual chaos**: `kubectl delete pod <random-pod>`, `kubectl drain node <random-node>`, kill a container runtime on a node. Start simple before adopting frameworks.

The goal is not to break things for fun. The goal is to verify that your monitoring catches the failure, your alerts fire, your PDBs prevent cascading outages, and your team knows how to respond.

## The Complete Checklist

Before declaring a cluster production-ready, verify:

- [ ] **Monitoring**: kube-prometheus-stack or equivalent deployed and dashboards reviewed
- [ ] **Alerting**: Critical alerts configured (node down, pod CrashLoopBackOff, disk pressure, API server errors)
- [ ] **Logging**: Loki or EFK collecting logs from all namespaces
- [ ] **RBAC**: No unnecessary cluster-admin bindings; service accounts have minimal permissions
- [ ] **NetworkPolicies**: Default-deny in application namespaces with explicit allow rules
- [ ] **Pod Security Standards**: At least `baseline` enforced on all application namespaces
- [ ] **Image scanning**: Trivy or equivalent in CI/CD pipeline
- [ ] **Backup**: Velero or equivalent with scheduled backups and tested restores
- [ ] **Health probes**: Readiness, liveness, and startup probes on all Deployments
- [ ] **PDBs**: PodDisruptionBudgets on all production Deployments
- [ ] **Resource limits**: Requests and limits set on all containers
- [ ] **LimitRanges**: Default limits in every namespace
- [ ] **ResourceQuotas**: Quotas on every namespace
- [ ] **Labels**: Consistent labeling for cost attribution and filtering
- [ ] **etcd backups**: Automated (managed K8s) or scripted (self-managed)
- [ ] **Upgrade plan**: Documented process for upgrading Kubernetes and node OS

## Common Mistakes and Misconceptions

- **"My app works in dev, so it's production-ready."** Production requires health probes, resource requests/limits, PodDisruptionBudgets, anti-affinity rules, graceful shutdown handling, and monitoring. Dev-working is the starting line, not the finish.
- **"Setting replicas to 1 with a PDB is fine."** A PDB with `minAvailable: 1` on a single-replica Deployment blocks all voluntary disruptions (node drains, upgrades). Use at least 2 replicas for anything that needs PDB protection.
- **"Liveness probes should check dependencies."** If your liveness probe checks the database and the database goes down, Kubernetes kills all your pods — making recovery impossible. Liveness checks should only verify the process itself is alive.

## Further Reading

- [kube-prometheus-stack Helm chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) --- The standard monitoring deployment
- [Grafana Loki documentation](https://grafana.com/docs/loki/latest/) --- Log aggregation setup and query language
- [Velero documentation](https://velero.io/docs/) --- Backup and restore for Kubernetes
- [Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/) --- Official PSS reference
- [Trivy](https://aquasecurity.github.io/trivy/) --- Container image vulnerability scanner
- [OpenCost](https://www.opencost.io/) --- CNCF project for Kubernetes cost monitoring and optimization
- [Chaos Mesh](https://chaos-mesh.org/) --- CNCF chaos engineering for Kubernetes
- [CNCF Slack](https://slack.cncf.io/) --- Community channels for Kubernetes operations
- [KubeCon talks playlist](https://www.youtube.com/@cncf/playlists) --- Real-world production Kubernetes talks
- [EKS Best Practices Guide](https://aws.github.io/aws-eks-best-practices/) --- Production checklist specific to EKS
- [GKE hardening guide](https://cloud.google.com/kubernetes-engine/docs/how-to/hardening-your-cluster) --- Security best practices for GKE

---

*This concludes Part 3: From Theory to Practice. You have a running cluster, deployed workloads, and the debugging skills to keep them healthy. Part 4 tackles the next challenge: running applications that cannot simply be restarted and replaced --- databases, queues, and other stateful systems that need stable identity and persistent storage.*

Next: [StatefulSets Deep Dive](21-statefulsets.md)

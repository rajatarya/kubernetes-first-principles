# Appendix D: Troubleshooting Quick Reference

This appendix maps the error messages and symptoms you will encounter in practice to their most common root causes. Organized by where you see the error.

---

## General Debugging Flowchart

```
Pod not working?
       |
       v
  kubectl get pods -n <namespace>
       |
       v
  What status do you see?
       |
       +---> Pending ───────────────────> Check events: kubectl describe pod <pod>
       |                                    +-> "Insufficient cpu/memory" -> Scale up or adjust requests
       |                                    +-> "no nodes match selectors" -> Fix nodeSelector/affinity
       |                                    +-> "persistentvolumeclaim not bound" -> Check PVC
       |
       +---> CrashLoopBackOff ──────────> kubectl logs <pod> --previous
       |                                    +-> OOMKilled? -> Increase memory limits
       |                                    +-> App error? -> Fix application startup
       |                                    +-> Missing config? -> Check ConfigMaps/Secrets
       |
       +---> ImagePullBackOff ──────────> kubectl describe pod <pod>
       |                                    +-> "repository does not exist" -> Fix image name
       |                                    +-> "unauthorized" -> Fix imagePullSecrets
       |                                    +-> "tag not found" -> Fix image tag
       |
       +---> Running but not working ──> kubectl logs <pod> -f
       |                                    +-> Check readiness probe: kubectl describe pod
       |                                    +-> Check service endpoints: kubectl get endpoints
       |                                    +-> Test from inside: kubectl exec -it <pod> -- sh
       |
       +---> Evicted ──────────────────> kubectl describe node <node>
       |                                    +-> Check for DiskPressure / MemoryPressure
       |
       +---> Unknown / NodeLost ───────> kubectl get nodes
                                            +-> Node NotReady? -> SSH to node, check kubelet
```

---

## Pod Status Errors

### `Pending`

**What it means:** The scheduler cannot find a node to place the pod on, or a prerequisite resource is not ready.

**Common causes:**
- No node has enough CPU or memory to satisfy the pod's resource requests.
- `nodeSelector`, `nodeAffinity`, or `tolerations` do not match any available node.
- A referenced PersistentVolumeClaim is not bound.
- Resource quotas in the namespace are exhausted.
- The cluster has no nodes at all (scaling from zero).

**How to diagnose:**
```bash
kubectl describe pod <pod-name> -n <namespace>    # Look at the Events section
kubectl get nodes -o wide                          # Check node status and capacity
kubectl describe node <node-name>                  # Check Allocatable vs Allocated
kubectl get pvc -n <namespace>                     # Check PVC status
kubectl get resourcequota -n <namespace>           # Check quota usage
```

**Fix:**
1. If resource-constrained: lower the pod's resource requests, add nodes, or remove idle workloads.
2. If selector mismatch: correct `nodeSelector`/`nodeAffinity` labels or add labels to nodes.
3. If PVC not bound: ensure a matching PV exists or the StorageClass can dynamically provision one.
4. If quota exceeded: request a quota increase or free capacity in the namespace.

---

### `CrashLoopBackOff`

**What it means:** The container starts, exits with an error, and Kubernetes keeps restarting it with exponential backoff.

**Common causes:**
- Application crashes on startup (uncaught exception, missing dependency).
- Required ConfigMap or Secret is mounted but contains wrong data (wrong key, wrong format).
- `OOMKilled` -- the container exceeds its memory limit on startup.
- Liveness probe is too aggressive and kills the container before it finishes starting.
- Entrypoint or command is misconfigured.

**How to diagnose:**
```bash
kubectl logs <pod-name> -n <namespace> --previous   # Logs from the last crashed container
kubectl describe pod <pod-name> -n <namespace>       # Check Last State, Exit Code, Reason
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.status.containerStatuses[0].lastState}'
```

**Fix:**
1. Read the logs from `--previous` to find the actual error.
2. If `OOMKilled` (exit code 137): increase `resources.limits.memory`.
3. If liveness probe is killing the pod: increase `initialDelaySeconds` and `failureThreshold`.
4. If config is missing: verify ConfigMap/Secret exists and has the expected keys.

---

### `ImagePullBackOff` / `ErrImagePull`

**What it means:** The kubelet cannot pull the container image from the registry.

**Common causes:**
- Image name or tag is misspelled.
- The image tag does not exist (e.g., `latest` was overwritten or a SHA was pruned).
- The registry is private and `imagePullSecrets` are missing or contain invalid credentials.
- The node cannot reach the registry (network/firewall issue).
- Docker Hub rate limits are hit on unauthenticated pulls.

**How to diagnose:**
```bash
kubectl describe pod <pod-name> -n <namespace>       # Read the pull error message
kubectl get pod <pod-name> -n <namespace> -o jsonpath='{.spec.containers[0].image}'
# Verify the image exists:
docker pull <image>                                   # Or: crane manifest <image>
# Check imagePullSecrets:
kubectl get secret <secret-name> -n <namespace> -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

**Fix:**
1. Correct the image name and tag.
2. Create or fix `imagePullSecrets`:
   ```bash
   kubectl create secret docker-registry regcred \
     --docker-server=<registry> \
     --docker-username=<user> \
     --docker-password=<pass> \
     -n <namespace>
   ```
3. If rate-limited: configure a pull-through cache or authenticate to Docker Hub.

---

### `OOMKilled`

**What it means:** The Linux kernel's OOM killer terminated the container because it tried to use more memory than its cgroup limit allows.

**Common causes:**
- Memory limit is set too low for the workload.
- Java application is not configured for container-aware memory (`-XX:MaxRAMPercentage` not set, or old JVM ignoring cgroup limits).
- Memory leak in the application.
- Large file processing or caching loading entire datasets into memory.

**How to diagnose:**
```bash
kubectl describe pod <pod-name> -n <namespace>       # Look for "OOMKilled" in Last State
kubectl top pod <pod-name> -n <namespace>             # Current memory usage
kubectl logs <pod-name> -n <namespace> --previous     # App logs before kill
# On the node:
dmesg | grep -i "oom\|killed"                         # Kernel OOM killer logs
```

**Fix:**
1. Increase `resources.limits.memory` to match the actual needs of the workload.
2. For Java: set `-XX:MaxRAMPercentage=75.0` instead of a fixed `-Xmx`, and ensure JVM version 10+.
3. For memory leaks: profile the application, fix the leak, then right-size the limit.
4. Set `resources.requests.memory` close to `limits.memory` to avoid scheduling on nodes that cannot support the workload.

---

### `CreateContainerConfigError`

**What it means:** The kubelet cannot create the container because a referenced ConfigMap or Secret does not exist.

**Common causes:**
- The ConfigMap or Secret was not created before the pod.
- Typo in the ConfigMap/Secret name in the pod spec.
- The ConfigMap/Secret is in a different namespace (they are namespace-scoped).
- It was accidentally deleted.

**How to diagnose:**
```bash
kubectl describe pod <pod-name> -n <namespace>       # Events will name the missing resource
kubectl get configmap -n <namespace>
kubectl get secret -n <namespace>
```

**Fix:**
1. Create the missing ConfigMap or Secret.
2. Correct any name typos in the pod spec.
3. If it should be optional, set `optional: true` on the `configMapRef`/`secretRef`.

---

### `Init:CrashLoopBackOff`

**What it means:** An init container is repeatedly crashing, preventing the main containers from starting.

**Common causes:**
- The init container is waiting for a service that is not yet available (e.g., database migration init container cannot connect to the DB).
- Script error in the init container command.
- Wrong image or command for the init container.

**How to diagnose:**
```bash
kubectl describe pod <pod-name> -n <namespace>       # Identify which init container is failing
kubectl logs <pod-name> -n <namespace> -c <init-container-name> --previous
```

**Fix:**
1. Check the init container logs for the specific error.
2. Verify the service it depends on is running and reachable.
3. Fix the init container command, image, or configuration.

---

### `Evicted`

**What it means:** The kubelet evicted the pod because the node was under resource pressure (disk, memory, or PID).

**Common causes:**
- Node is under `DiskPressure` (ephemeral storage or container logs filled the disk).
- Node is under `MemoryPressure` (too many pods with `BestEffort` QoS).
- PID exhaustion on the node.

**How to diagnose:**
```bash
kubectl describe pod <pod-name> -n <namespace>       # Shows eviction reason
kubectl describe node <node-name>                     # Check Conditions for pressure
kubectl get pods -n <namespace> --field-selector=status.phase=Failed | grep Evicted
```

**Fix:**
1. Clean up disk usage on the node (prune unused images, clear old logs).
2. Set proper `resources.requests` so BestEffort pods are evicted first.
3. Configure `ephemeral-storage` requests and limits.
4. Set up log rotation and image garbage collection on nodes.

---

## Node Issues

### `NotReady`

**What it means:** The kubelet on the node is not communicating with the API server, so the control plane marks it NotReady.

**Common causes:**
- Kubelet service is not running or has crashed.
- CNI plugin is not installed or is misconfigured (the node cannot report Ready without a working CNI).
- Node is under `DiskPressure` or `MemoryPressure`.
- Network partition between the node and the control plane.
- Expired kubelet client certificate.

**How to diagnose:**
```bash
kubectl describe node <node-name>                     # Check Conditions and Events
kubectl get node <node-name> -o yaml                  # Look at .status.conditions
# SSH to the node:
systemctl status kubelet
journalctl -u kubelet --since "10 minutes ago"
crictl ps                                              # Check container runtime
ls /etc/cni/net.d/                                     # Check CNI configuration
```

**Fix:**
1. Restart kubelet: `systemctl restart kubelet`.
2. If CNI is missing: install or reinstall the CNI plugin (Calico, Cilium, Flannel, etc.).
3. If certificates expired: rotate certificates with `kubeadm certs renew`.
4. If disk pressure: free disk space on the node.

---

### `SchedulingDisabled`

**What it means:** The node has been cordoned -- new pods will not be scheduled onto it.

**Common causes:**
- An administrator ran `kubectl cordon <node>`.
- A node drain is in progress (`kubectl drain`).
- A cluster autoscaler is decommissioning the node.

**How to diagnose:**
```bash
kubectl get nodes                                      # Look for SchedulingDisabled
kubectl describe node <node-name>                      # Check Taints for NoSchedule
```

**Fix:**
1. If the maintenance is complete: `kubectl uncordon <node-name>`.
2. If autoscaler-managed: the node will be removed; no action needed.

---

### `DiskPressure` / `MemoryPressure`

**What it means:** The node's available disk or memory has dropped below the kubelet's eviction threshold.

**Common causes:**
- Container images consuming too much disk.
- Application logs not rotated, filling up the filesystem.
- Too many pods on the node relative to available memory.
- Large emptyDir volumes.

**How to diagnose:**
```bash
kubectl describe node <node-name>                      # Check Conditions section
# SSH to the node:
df -h                                                   # Disk usage
free -m                                                 # Memory usage
crictl images | wc -l                                   # Number of cached images
du -sh /var/log/pods/*                                  # Pod log sizes
```

**Fix:**
1. Disk: prune unused images (`crictl rmi --prune`), enable log rotation, clean `/var/log`.
2. Memory: evict low-priority pods, increase node size, or add more nodes.
3. Configure kubelet garbage collection thresholds in the KubeletConfiguration.

---

## Networking

### `Connection refused` on Service

**What it means:** A TCP connection to the Service IP and port is actively refused, meaning nothing is listening.

**Common causes:**
- No ready endpoints behind the Service (pods are not running or not passing readiness probes).
- The Service `targetPort` does not match the port the application is actually listening on.
- The pod is running but the application inside has not started listening yet.

**How to diagnose:**
```bash
kubectl get endpoints <service-name> -n <namespace>    # Are there any endpoints?
kubectl get pods -n <namespace> -l <selector>           # Are pods running and Ready?
kubectl describe svc <service-name> -n <namespace>      # Check selector and ports
kubectl exec -it <pod> -n <namespace> -- ss -tlnp       # What is the pod listening on?
```

**Fix:**
1. If no endpoints: ensure the Service selector matches the pod labels exactly.
2. If targetPort is wrong: update the Service to match the container's listening port.
3. If pods are not Ready: fix the readiness probe or the underlying application issue.

---

### DNS Resolution Failures

**What it means:** Pods cannot resolve Kubernetes service names or external hostnames.

**Common causes:**
- CoreDNS pods are not running or are crashing.
- The `ndots` setting (default: 5) causes excessive search domain lookups, leading to timeouts.
- Pod's `dnsPolicy` is set to `Default` (uses node DNS) instead of `ClusterFirst`.
- Network policy blocking DNS traffic (UDP/TCP port 53 to `kube-system`).

**How to diagnose:**
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns    # Is CoreDNS running?
kubectl logs -n kube-system -l k8s-app=kube-dns        # CoreDNS errors
# Test from inside a pod:
kubectl exec -it <pod> -n <namespace> -- nslookup kubernetes.default
kubectl exec -it <pod> -n <namespace> -- cat /etc/resolv.conf
```

**Fix:**
1. If CoreDNS is down: check its deployment, resource limits, and node resources.
2. For `ndots` issues: add `dnsConfig` with `ndots: 2` to the pod spec, or use FQDNs (trailing dot).
3. If NetworkPolicy is blocking: allow egress to `kube-system` on port 53.
4. If dnsPolicy is wrong: set `dnsPolicy: ClusterFirst`.

---

### `Service has no endpoints`

**What it means:** The Service exists but has no backing pods, so all traffic to it fails.

**Common causes:**
- The Service's label selector does not match any pod labels (typo or mismatch).
- All matching pods are failing their readiness probes.
- The pods are in a different namespace than expected (selectors are namespace-scoped).

**How to diagnose:**
```bash
kubectl describe svc <service-name> -n <namespace>     # Check Selector
kubectl get endpoints <service-name> -n <namespace>     # Should list pod IPs
kubectl get pods -n <namespace> --show-labels           # Compare labels to selector
kubectl get pods -n <namespace> -l <key>=<value>        # Test the selector directly
```

**Fix:**
1. Align the Service selector with the pod's labels.
2. Fix readiness probes so pods become Ready.
3. Ensure pods are deployed in the correct namespace.

---

### Timeout Connecting Between Pods

**What it means:** TCP connections between pods hang and eventually time out, rather than being refused.

**Common causes:**
- A NetworkPolicy is blocking the traffic.
- The CNI plugin is misconfigured or its pods are crashing.
- IPtables/eBPF rules are stale after a CNI upgrade or node reboot.
- Nodes are in different subnets and inter-node routing is broken.

**How to diagnose:**
```bash
kubectl get networkpolicy -n <namespace>                # Are there policies restricting traffic?
kubectl describe networkpolicy <name> -n <namespace>
kubectl get pods -n kube-system -l k8s-app=calico-node  # Or your CNI's pods
# Test connectivity from inside a pod:
kubectl exec -it <pod> -n <namespace> -- curl -v --connect-timeout 5 <target-svc>:<port>
# On the node:
iptables-save | grep <service-cluster-ip>               # Check kube-proxy rules
```

**Fix:**
1. If NetworkPolicy is blocking: update the policy to allow the required ingress/egress.
2. If CNI is broken: restart CNI pods, or reinstall the CNI plugin.
3. If iptables are stale: restart kube-proxy (`kubectl rollout restart ds/kube-proxy -n kube-system`).
4. Check cloud provider security groups and route tables for inter-node communication.

---

## Storage

### PVC Stuck in `Pending`

**What it means:** The PersistentVolumeClaim cannot be bound to a PersistentVolume.

**Common causes:**
- No PV matches the PVC's `storageClassName`, `accessModes`, or `capacity`.
- The StorageClass does not exist or the provisioner is not installed.
- In multi-zone clusters: the PV is in a different zone than the node running the pod.
- `WaitForFirstConsumer` binding mode means the PVC will not bind until a pod using it is scheduled.

**How to diagnose:**
```bash
kubectl describe pvc <pvc-name> -n <namespace>          # Events explain why it is pending
kubectl get storageclass                                 # Does the StorageClass exist?
kubectl get pv                                           # Are there available PVs?
kubectl get events -n <namespace> --field-selector reason=ProvisioningFailed
```

**Fix:**
1. If no StorageClass: create one or set a default StorageClass.
2. If provisioner is missing: install the CSI driver (e.g., `ebs-csi-driver`, `csi-driver-nfs`).
3. If zone mismatch: use `volumeBindingMode: WaitForFirstConsumer` to bind in the correct zone.
4. If capacity mismatch: create a PV with the required size, or adjust the PVC request.

---

### `FailedMount` / `FailedAttachVolume`

**What it means:** The kubelet cannot mount or attach the volume to the node.

**Common causes:**
- The volume is still attached to another node (common when a pod is rescheduled -- the old node has not detached yet).
- The CSI driver is not installed or its pods are not running.
- The volume does not exist (deleted out of band).
- Filesystem corruption requiring manual `fsck`.
- Exceeded the maximum number of volumes per node (e.g., AWS limit of EBS volumes per instance type).

**How to diagnose:**
```bash
kubectl describe pod <pod-name> -n <namespace>          # Look at Events for mount errors
kubectl get volumeattachments                            # Check if volume is attached elsewhere
kubectl get pods -n kube-system -l app=ebs-csi-node     # Check CSI driver pods
kubectl get pv <pv-name> -o yaml                        # Check volume status
```

**Fix:**
1. If stuck attachment: wait for the `VolumeAttachment` to be cleaned up (up to 6 minutes), or manually delete the `VolumeAttachment` object.
2. If CSI driver is missing: install it.
3. If volume limit reached: use a larger instance type or distribute pods across more nodes.
4. If volume was deleted: recreate it and restore from backup.

---

## Control Plane

### API Server `connection refused`

**What it means:** Clients cannot reach the Kubernetes API server.

**Common causes:**
- The `kube-apiserver` process is not running.
- TLS certificates have expired.
- Firewall or security group is blocking port 6443.
- Load balancer in front of API server is misconfigured or unhealthy.

**How to diagnose:**
```bash
# On a control plane node:
crictl ps | grep kube-apiserver                         # Is the container running?
crictl logs <apiserver-container-id> | tail -50          # API server logs
openssl s_client -connect <api-server>:6443             # Test TLS handshake
curl -k https://<api-server>:6443/healthz               # Health endpoint
journalctl -u kubelet | grep apiserver                  # Kubelet managing static pod?
```

**Fix:**
1. If not running: check static pod manifest at `/etc/kubernetes/manifests/kube-apiserver.yaml`.
2. If certificates expired: `kubeadm certs renew all && systemctl restart kubelet`.
3. If firewall blocking: open port 6443 to the required source IPs.
4. If load balancer: check health check configuration and backend targets.

---

### etcd Errors

**What it means:** The etcd cluster backing the API server is unhealthy.

**Common causes:**
- Disk latency is too high (etcd requires low-latency storage, ideally SSD).
- Quorum lost (majority of etcd members are down).
- Database size has exceeded the space quota (default 2 GB).
- Clock skew between etcd members.

**How to diagnose:**
```bash
# If etcd is accessible:
etcdctl endpoint health --cluster
etcdctl endpoint status --cluster -w table
etcdctl alarm list
# Check disk latency:
etcdctl check perf
# From API server logs:
crictl logs <apiserver-container-id> | grep etcd
```

**Fix:**
1. If disk latency: move etcd to SSD-backed storage, or use dedicated etcd nodes.
2. If quorum lost: restore from snapshot (`etcdctl snapshot restore`).
3. If space quota exceeded: compact and defragment: `etcdctl compact` then `etcdctl defrag`.
4. If alarms triggered: `etcdctl alarm disarm` after resolving the root cause.

---

### `Forbidden` (RBAC)

**What it means:** The authenticated identity does not have permission to perform the requested action.

**Common causes:**
- Missing Role/ClusterRole or RoleBinding/ClusterRoleBinding.
- The binding references the wrong ServiceAccount, user, or group.
- Namespace mismatch: a Role only grants permissions in its own namespace.
- The ServiceAccount token is from a different namespace.

**How to diagnose:**
```bash
kubectl auth can-i <verb> <resource> --as=system:serviceaccount:<ns>:<sa>
kubectl auth can-i <verb> <resource> --as=<user> -n <namespace>
kubectl get rolebinding,clusterrolebinding -A | grep <service-account-name>
kubectl describe clusterrole <role-name>                # What permissions does it grant?
```

**Fix:**
1. Create the missing Role and RoleBinding (or ClusterRole/ClusterRoleBinding for cluster-wide access).
2. Verify the `subjects` in the binding match the actual identity making the request.
3. Use `kubectl auth can-i --list --as=<identity>` to see all permissions for debugging.

---

### Webhook Errors (`failed calling webhook`)

**What it means:** An admission webhook (validating or mutating) is failing, blocking resource creation or updates.

**Common causes:**
- The webhook's backing Service or pod is down.
- The webhook's TLS certificate has expired.
- The webhook was installed with `failurePolicy: Fail` and the service is unreachable.
- The webhook is rejecting the request due to policy (this is intentional, not an error in the webhook itself).

**How to diagnose:**
```bash
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations
kubectl describe validatingwebhookconfiguration <name>   # Check service and failurePolicy
kubectl get pods -n <webhook-namespace>                   # Is the webhook pod running?
kubectl logs -n <webhook-namespace> <webhook-pod>         # Webhook logs
```

**Fix:**
1. If the webhook service is down: restart it or fix its deployment.
2. If certificates expired: renew them (often managed by cert-manager).
3. Emergency bypass: temporarily set `failurePolicy: Ignore` or delete the webhook configuration.
4. To exclude a namespace: add the appropriate `namespaceSelector` to the webhook configuration.

---

## Deployment Issues

### Rollout Stuck

**What it means:** A Deployment rollout is not progressing -- new pods are not becoming Ready or old pods are not being terminated.

**Common causes:**
- New pods are failing (CrashLoopBackOff, ImagePullBackOff, Pending).
- A PodDisruptionBudget is preventing old pods from being evicted.
- Resource quota in the namespace is exhausted (cannot create new ReplicaSet pods).
- The `progressDeadlineSeconds` has not yet been reached (default 600s).

**How to diagnose:**
```bash
kubectl rollout status deployment/<name> -n <namespace>
kubectl describe deployment <name> -n <namespace>        # Check Conditions and Events
kubectl get rs -n <namespace>                             # Compare old vs new ReplicaSet
kubectl get pods -n <namespace> -l <selector>             # What state are the new pods in?
kubectl get pdb -n <namespace>                            # Check PodDisruptionBudgets
kubectl get resourcequota -n <namespace>
```

**Fix:**
1. Fix the underlying pod issue (image, config, resources) then let the rollout continue.
2. If PDB is blocking: temporarily relax the PDB or scale up first.
3. If stuck and unrecoverable: `kubectl rollout undo deployment/<name> -n <namespace>`.
4. If quota exceeded: increase the quota or delete unused resources.

---

### `FailedCreate` on ReplicaSet

**What it means:** The ReplicaSet controller cannot create new pods.

**Common causes:**
- Resource quota in the namespace is fully consumed.
- An admission webhook is rejecting pod creation.
- LimitRange in the namespace is setting constraints the pod spec violates.
- The ServiceAccount referenced by the pod does not exist.

**How to diagnose:**
```bash
kubectl describe rs <replicaset-name> -n <namespace>     # Events will show the error
kubectl get resourcequota -n <namespace> -o yaml          # Compare used vs hard
kubectl get limitrange -n <namespace> -o yaml
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
```

**Fix:**
1. If quota exhausted: increase the quota or reduce resource requests on the pods.
2. If webhook rejecting: check webhook logs to understand the rejection reason.
3. If LimitRange violation: adjust pod resource requests/limits to comply.
4. If ServiceAccount missing: create it or correct the reference.

---

## Useful Commands Cheat Sheet

```bash
# --- Inspecting Resources ---
kubectl get pods -n <ns> -o wide                        # Pod status with node and IP
kubectl describe pod <pod> -n <ns>                      # Full pod details and events
kubectl get events -n <ns> --sort-by='.lastTimestamp'   # Recent events in namespace
kubectl get events -A --field-selector type=Warning     # All warnings cluster-wide

# --- Logs ---
kubectl logs <pod> -n <ns>                              # Current container logs
kubectl logs <pod> -n <ns> --previous                   # Logs from last crashed container
kubectl logs <pod> -n <ns> -c <container>               # Specific container in multi-container pod
kubectl logs -l app=<label> -n <ns> --tail=100          # Logs by label selector

# --- Interactive Debugging ---
kubectl exec -it <pod> -n <ns> -- /bin/sh               # Shell into a running container
kubectl debug node/<node> -it --image=busybox           # Debug node-level issues
kubectl run debug --rm -it --image=nicolaka/netshoot -- bash  # Ephemeral network debug pod

# --- Networking ---
kubectl get endpoints <svc> -n <ns>                     # Service endpoints
kubectl port-forward svc/<svc> 8080:80 -n <ns>         # Forward service port to localhost
kubectl exec <pod> -n <ns> -- nslookup <svc>            # Test DNS resolution from pod

# --- Resource Usage ---
kubectl top nodes                                       # Node CPU and memory usage
kubectl top pods -n <ns> --sort-by=memory               # Pod resource consumption
kubectl top pods -n <ns> --containers                   # Per-container resource usage

# --- Cluster State ---
kubectl get componentstatuses                           # Control plane health (deprecated but useful)
kubectl cluster-info dump | grep -i error               # Dump cluster state and search for errors
kubectl api-resources                                   # All available API resources

# --- Rollouts ---
kubectl rollout status deployment/<name> -n <ns>        # Watch rollout progress
kubectl rollout history deployment/<name> -n <ns>       # Rollout revision history
kubectl rollout undo deployment/<name> -n <ns>          # Roll back to previous revision
```

---

*Back to [Table of Contents](README.md)*

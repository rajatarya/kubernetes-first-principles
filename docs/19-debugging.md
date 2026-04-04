# Chapter 19: Debugging Kubernetes

Kubernetes failures are often opaque. A pod does not start, a service does not route traffic, a node disappears --- and the system gives you a status word and expects you to figure out the rest. This chapter builds a systematic debugging methodology and a reference for the most common failure modes.

## The Debugging Workflow

Every Kubernetes debugging session follows the same escalation path:

```
THE DEBUGGING ESCALATION PATH
──────────────────────────────

  kubectl get        What exists? What state is it in?
       │
       ▼
  kubectl describe   Why is it in that state? What events occurred?
       │
       ▼
  kubectl logs       What did the application say?
       │
       ▼
  kubectl exec       Get inside the container and investigate
       │
       ▼
  kubectl debug      Cannot exec? Use an ephemeral debug container
       │
       ▼
  Node-level debug   SSH to the node, check kubelet logs, check runtime
```

### Step 1: kubectl get --- What Exists?

Start broad and narrow down.

```bash
# Overview of all resources in a namespace
kubectl get all -n my-namespace

# Pods with extra detail
kubectl get pods -n my-namespace -o wide

# Watch pods in real time
kubectl get pods -n my-namespace -w

# Filter by label
kubectl get pods -l app=web-app -o wide
```

The `-o wide` flag shows node placement and pod IPs. The `-w` flag watches for changes in real time --- invaluable for observing rolling updates, scaling events, or crash loops.

### Step 2: kubectl describe --- Why?

`kubectl describe` shows the full history of an object: its current spec, its status, and the **events** that affected it. Events are the single most important debugging data source in Kubernetes.

```bash
kubectl describe pod web-app-7d4f8b6c9-x2z4p
```

The output includes:

- **Status**: The pod's current phase (Pending, Running, Succeeded, Failed, Unknown)
- **Conditions**: Ready, Initialized, ContainersReady, PodScheduled --- each with a reason if false
- **Container state**: Waiting (with reason), Running, or Terminated (with exit code)
- **Events**: Time-ordered log of what happened to this pod

Events decay after 1 hour by default. If you are debugging something that happened hours ago, events may be gone. Use a monitoring system to persist events (more on this in Chapter 20).

### Step 3: kubectl logs --- What Did the Application Say?

```bash
# Current logs
kubectl logs web-app-7d4f8b6c9-x2z4p

# Previous container's logs (after a restart)
kubectl logs web-app-7d4f8b6c9-x2z4p --previous

# Follow logs in real time
kubectl logs web-app-7d4f8b6c9-x2z4p -f

# Logs from a specific container in a multi-container pod
kubectl logs web-app-7d4f8b6c9-x2z4p -c sidecar

# Logs from all pods matching a label
kubectl logs -l app=web-app --all-containers
```

The `--previous` flag is critical for CrashLoopBackOff debugging. The current container has just started (and may have nothing useful in its logs yet), but the previous container's logs show why it crashed.

### Step 4: kubectl exec --- Get Inside

```bash
# Interactive shell
kubectl exec -it web-app-7d4f8b6c9-x2z4p -- /bin/sh

# Run a single command
kubectl exec web-app-7d4f8b6c9-x2z4p -- cat /etc/app/config/config.json

# Check DNS resolution from inside the pod
kubectl exec web-app-7d4f8b6c9-x2z4p -- nslookup my-service

# Check network connectivity
kubectl exec web-app-7d4f8b6c9-x2z4p -- wget -qO- http://my-service:8080/health
```

### Step 5: kubectl debug --- When exec Is Not Enough

Many production images are **distroless** --- they contain only the application binary, with no shell, no `curl`, no debugging tools. You cannot `exec` into something that has no shell.

Ephemeral debug containers solve this. They inject a temporary container into a running pod that shares the pod's network namespace (and optionally its process namespace).

```bash
# Attach a debug container with networking tools
kubectl debug -it web-app-7d4f8b6c9-x2z4p \
  --image=nicolaka/netshoot \
  --target=web

# The --target flag shares the process namespace with the specified container
# You can now see the target container's processes with ps aux
```

The debug container runs alongside the existing containers in the same pod. It shares the network namespace (same IP, same ports) but has its own filesystem with the debugging tools you need. When you exit, the ephemeral container is cleaned up.

You can also debug nodes:

```bash
# Create a debugging pod on a specific node
kubectl debug node/worker-1 -it --image=ubuntu

# This creates a pod with hostPID, hostNetwork, and the node's
# filesystem mounted at /host. You can inspect the node as if
# you had SSH access.
```

## Understanding Pod Status

Pod status words are the first signal in any debugging session. Here is what each one means and how to investigate it.

```
POD LIFECYCLE
─────────────

  Pending ──► Running ──► Succeeded
     │            │
     │            └──► Failed
     │
     └──► (stuck here: scheduling or volume issues)


  Container States:
  Waiting ──► Running ──► Terminated
     │                        │
     │                        └──► (exit code 0 = success)
     │                        └──► (exit code non-zero = error)
     │
     └──► CrashLoopBackOff (repeated Terminated → Waiting cycle)
```

## Status Reference Table

| Status | Likely Cause | Diagnostic Command |
|--------|-------------|-------------------|
| **Pending** (no events) | No node has enough resources | `kubectl describe pod` --- look for "Insufficient cpu/memory" in events |
| **Pending** (FailedScheduling) | Node selector, affinity, or taint preventing scheduling | `kubectl describe pod` --- check node affinity/selector rules and taints |
| **Pending** (volume) | PVC unbound, StorageClass missing, or AZ mismatch | `kubectl get pvc` and `kubectl describe pvc` |
| **ContainerCreating** (stuck) | Image pull in progress, or volume mount failing | `kubectl describe pod` --- check events for pull progress or mount errors |
| **ImagePullBackOff** | Wrong image name, tag does not exist, or registry auth failure | `kubectl describe pod` --- read the exact error. Check image name and `imagePullSecrets` |
| **CrashLoopBackOff** | Container starts and immediately exits | `kubectl logs --previous` --- read the application's error output |
| **CrashLoopBackOff** (exit 1) | Application error (bad config, missing dependency) | `kubectl logs --previous` and check ConfigMap/Secret mounts |
| **CrashLoopBackOff** (exit 137) | OOMKilled --- container exceeded memory limit | `kubectl describe pod` --- look for "OOMKilled". Increase memory limit or fix memory leak |
| **CrashLoopBackOff** (exit 139) | Segfault in the application | `kubectl logs --previous` --- check for native crash logs |
| **Running** but not ready | Readiness probe failing | `kubectl describe pod` --- check readiness probe events |
| **OOMKilled** | Memory limit exceeded | `kubectl describe pod` --- confirm OOMKilled reason. Check `resources.limits.memory` |
| **Evicted** | Node under memory or disk pressure | `kubectl describe pod` --- check eviction reason. `kubectl describe node` --- check conditions |
| **Terminating** (stuck) | Finalizers blocking deletion, or process ignoring SIGTERM | `kubectl get pod -o json \| jq '.metadata.finalizers'` |
| **Unknown** | Kubelet on the node is not reporting | `kubectl get nodes` --- check if the node is NotReady. Investigate the node. |
| **Error** (on Job/CronJob) | Container exited with non-zero exit code | `kubectl logs <pod>` |

## Common Failure Patterns

### Pattern 1: DNS Resolution Failure

**Symptom**: Application logs show connection timeouts or "name not found" errors for service names.

**Diagnosis**:

```bash
# Check if CoreDNS pods are running
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Test DNS from inside a pod
kubectl exec -it debug-pod -- nslookup kubernetes.default
kubectl exec -it debug-pod -- nslookup my-service.my-namespace.svc.cluster.local

# Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns
```

Common causes: CoreDNS pods are not running, the pod's DNS policy is misconfigured, or a NetworkPolicy is blocking DNS traffic (port 53 UDP/TCP to the kube-dns Service).

### Pattern 2: Service Not Routing Traffic

**Symptom**: Requests to a Service ClusterIP time out or return connection refused.

**Diagnosis**:

```bash
# Check if the Service has endpoints
kubectl get endpoints my-service

# If endpoints list is empty:
# 1. Check that pods exist with the right labels
kubectl get pods -l app=web-app
# 2. Check that pods are Ready
kubectl get pods -l app=web-app -o jsonpath='{.items[*].status.conditions}'
# 3. Check that the Service selector matches the pod labels
kubectl get svc my-service -o yaml | grep -A5 selector
```

The most common cause is a **selector mismatch** --- the Service's `spec.selector` labels do not match the pod's `metadata.labels`. This is a silent failure: no error, just no traffic.

### Pattern 3: Node NotReady

**Symptom**: `kubectl get nodes` shows a node in `NotReady` status.

**Diagnosis**:

```bash
# Check node conditions
kubectl describe node worker-1

# Look for conditions:
#   MemoryPressure, DiskPressure, PIDPressure, NetworkUnavailable

# If you can SSH to the node:
# Check kubelet status
systemctl status kubelet
journalctl -u kubelet -n 100

# Check container runtime
systemctl status containerd
crictl ps
```

Common causes: kubelet crashed, container runtime is down, the node ran out of disk space, or network connectivity to the API server was lost.

### Pattern 4: Persistent Volume Claim Stuck in Pending

**Symptom**: PVC stays in Pending state indefinitely.

**Diagnosis**:

```bash
kubectl describe pvc my-claim

# Look for events like:
# - "no persistent volumes available for this claim"
# - "storageclass not found"
# - "waiting for first consumer to be created before binding"
```

Common causes: StorageClass does not exist, the CSI driver is not installed, `WaitForFirstConsumer` volume binding mode is waiting for a pod to be scheduled, or the requested storage exceeds available capacity.

### Pattern 5: Intermittent OOMKills

**Symptom**: Pods restart periodically with exit code 137.

**Diagnosis**:

```bash
# Confirm OOMKill
kubectl describe pod my-pod | grep -A5 "Last State"

# Check current memory usage
kubectl top pod my-pod

# Check the memory limit
kubectl get pod my-pod -o jsonpath='{.spec.containers[0].resources.limits.memory}'
```

The fix is either to increase the memory limit or to fix the memory leak in the application. If `kubectl top` shows memory growing over time without plateauing, suspect a leak. If it grows to a stable level that exceeds the limit, the limit is too low.

## Advanced: Reading Events Cluster-Wide

Events are namespaced objects. To see all events across the cluster:

```bash
# All events in a namespace, sorted by time
kubectl get events -n my-namespace --sort-by='.lastTimestamp'

# All events cluster-wide
kubectl get events --all-namespaces --sort-by='.lastTimestamp'

# Watch for new events in real time
kubectl get events -n my-namespace -w

# Filter events by type (Warning events are usually the interesting ones)
kubectl get events -n my-namespace --field-selector type=Warning
```

Events are the system's audit trail. When something goes wrong, the event stream usually tells you what happened, when, and why --- if you look quickly enough before the events expire.

## Further Reading

- [Kubernetes troubleshooting documentation](https://kubernetes.io/docs/tasks/debug/) --- Official debugging guides for applications, clusters, and services
- [kubectl debug documentation](https://kubernetes.io/docs/tasks/debug/debug-application/debug-running-pod/#ephemeral-container) --- Ephemeral debug container reference
- [Pod lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/) --- Pod phases, conditions, and container states
- [nicolaka/netshoot](https://github.com/nicolaka/netshoot) --- Docker image with network debugging tools for ephemeral containers
- [KillerCoda debugging scenarios](https://killercoda.com/kubernetes) --- Interactive browser-based troubleshooting labs
- [Learnk8s troubleshooting flowchart](https://learnk8s.io/troubleshooting-deployments) --- Visual flowchart for debugging Deployments
- [CNCF Slack #kubernetes-users](https://slack.cncf.io/) --- Community support for Kubernetes debugging

---

*Next: [Production Readiness](20-production-readiness.md)*

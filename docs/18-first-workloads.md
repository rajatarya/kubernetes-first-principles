# Chapter 18: Your First Workloads

This chapter is hands-on. Every YAML example is complete --- you can apply it to a running cluster and observe the result. But this is not a tutorial that asks you to type commands without understanding them. Each exercise explains *what* each field does and *why* it exists.

## Exercise 1: Deployment + Service

A Deployment manages a set of identical pods. A Service provides a stable network endpoint to reach them. Together, they are the fundamental building block of every Kubernetes application.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-app
  namespace: default
  labels:
    app: web-app
spec:
  replicas: 3                    # Run 3 identical pods
  selector:
    matchLabels:
      app: web-app               # The Deployment manages pods with this label
  template:                      # Pod template --- every pod created from this
    metadata:
      labels:
        app: web-app             # Must match selector.matchLabels
    spec:
      containers:
        - name: web
          image: nginx:1.27.3    # Always pin a specific version. Never use :latest.
          ports:
            - containerPort: 80
              protocol: TCP
          resources:
            requests:            # Scheduler uses these for placement decisions
              cpu: 100m          # 100 millicores = 0.1 CPU core
              memory: 128Mi      # 128 mebibytes
            limits:              # Hard ceiling the container cannot exceed
              cpu: 250m
              memory: 256Mi
          readinessProbe:        # Pod is added to Service endpoints only when ready
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:         # Pod is restarted if this fails
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 15
            periodSeconds: 20
```

Key fields explained:

- **`spec.replicas`**: The desired number of pod instances. The Deployment controller continuously reconciles the actual count to match this number.
- **`spec.selector.matchLabels`**: How the Deployment identifies which pods it owns. This must match the pod template labels. If it does not, the API server rejects the Deployment.
- **`spec.template`**: The blueprint for each pod. Every pod created by this Deployment is identical (same image, same resources, same probes).
- **`resources.requests`**: The minimum resources the scheduler guarantees. A pod with 100m CPU requests is guaranteed 0.1 cores. The scheduler will not place the pod on a node that cannot satisfy this request.
- **`resources.limits`**: The maximum resources the container can use. Exceeding CPU limits causes **throttling** (the container is slowed down). Exceeding memory limits causes **OOMKill** (the container is terminated).

Now the Service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-app
  namespace: default
spec:
  type: ClusterIP              # Internal-only. Reachable within the cluster.
  selector:
    app: web-app               # Route traffic to pods with this label
  ports:
    - port: 80                 # The port the Service listens on
      targetPort: 80           # The port on the pod to forward to
      protocol: TCP
```

The Service creates a stable virtual IP (ClusterIP) that load-balances across all pods matching the selector. When pods are created, destroyed, or become unready, the Service automatically updates its endpoints. This decouples clients from the pod lifecycle.

```
SERVICE ROUTING
───────────────

Client Pod                  Service (ClusterIP: 10.96.45.12)
    │                              │
    │  GET http://web-app/         │
    │─────────────────────────────►│
    │                              │
    │                  ┌───────────┼───────────┐
    │                  │           │           │
    │                  ▼           ▼           ▼
    │              Pod 1       Pod 2       Pod 3
    │           10.244.1.5  10.244.2.8  10.244.1.6
    │              :80         :80         :80
    │
    │  kube-proxy maintains iptables/IPVS rules
    │  that distribute traffic across healthy pods
```

Apply both:

```bash
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl get pods -l app=web-app
kubectl get endpoints web-app
```

The `endpoints` command shows which pod IPs are currently backing the Service. Pods that fail their readiness probe are removed from endpoints.

## Exercise 2: Scaling

Scaling a Deployment is a single field change:

```bash
kubectl scale deployment web-app --replicas=5
```

Or declaratively, change `spec.replicas: 5` and `kubectl apply`. The Deployment controller creates 2 new pods. The scheduler places them on nodes with available resources. The Service automatically includes them in its endpoint list once they pass their readiness probe.

Scale down to 2:

```bash
kubectl scale deployment web-app --replicas=2
```

The Deployment controller selects 3 pods for termination. Kubernetes sends SIGTERM, waits for `terminationGracePeriodSeconds` (default 30 seconds), then sends SIGKILL. During this window, the pod is removed from Service endpoints so it stops receiving new traffic.

## Exercise 3: Rolling Updates

Change the image version to trigger a rolling update:

```bash
kubectl set image deployment/web-app web=nginx:1.27.4
```

Or change the image in the YAML and `kubectl apply`. The Deployment controller performs a rolling update controlled by two parameters:

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1          # At most 1 extra pod above desired count
      maxUnavailable: 0    # Zero pods can be unavailable during update
```

```
ROLLING UPDATE (replicas=3, maxSurge=1, maxUnavailable=0)
──────────────────────────────────────────────────────────

Time    Old Pods (v1)    New Pods (v2)    Total Running
────    ─────────────    ─────────────    ─────────────
 t0     [A] [B] [C]                       3 (all v1)
 t1     [A] [B] [C]     [D]creating       3 + 1 surge
 t2     [A] [B] [C]     [D]ready          4 (surge = 1)
 t3     [A] [B]  X      [D]              3 (C terminated)
 t4     [A] [B]         [D] [E]creating   3 + 1 surge
 t5     [A] [B]         [D] [E]ready      4
 t6     [A]  X          [D] [E]           3 (B terminated)
 t7     [A]             [D] [E] [F]creat  3 + 1 surge
 t8     [A]             [D] [E] [F]ready  4
 t9      X              [D] [E] [F]       3 (all v2)
```

**`maxSurge: 1`** means at most 1 extra pod can exist above the desired replica count. This provides capacity during the transition.

**`maxUnavailable: 0`** means every old pod must be replaced by a ready new pod before it is terminated. This ensures zero downtime. The trade-off is that the update requires temporarily running 4 pods (3 desired + 1 surge), which needs extra cluster capacity.

Alternative strategies:

- `maxSurge: 0, maxUnavailable: 1`: No extra pods, but one pod is unavailable during each step. Saves resources, risks reduced capacity.
- `maxSurge: 25%, maxUnavailable: 25%`: The default. Balances speed and availability.

Roll back if something goes wrong:

```bash
kubectl rollout undo deployment/web-app
kubectl rollout status deployment/web-app
kubectl rollout history deployment/web-app
```

## Exercise 4: ConfigMaps and Secrets

Configuration should be separated from container images. ConfigMaps hold non-sensitive configuration. Secrets hold sensitive data (passwords, tokens, certificates).

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-config
data:
  APP_ENV: "production"
  LOG_LEVEL: "info"
  config.json: |
    {
      "database_pool_size": 10,
      "cache_ttl_seconds": 300,
      "feature_flags": {
        "new_dashboard": true
      }
    }
---
apiVersion: v1
kind: Secret
metadata:
  name: web-secrets
type: Opaque
stringData:                    # stringData accepts plain text (base64 encoded on save)
  DATABASE_URL: "postgres://user:pass@db:5432/myapp"
  API_KEY: "sk-abc123secret"
```

**Mount as volumes, not environment variables.** This is a best practice for two reasons:

1. Volume mounts can be updated without restarting the pod (if `subPath` is not used). Environment variables are frozen at container start.
2. Environment variables are exposed in `kubectl describe pod`, process listings, and crash dumps. Volume-mounted files are more contained.

```yaml
# In the Deployment spec.template.spec:
containers:
  - name: web
    image: my-app:v1.2.0
    volumeMounts:
      - name: config-volume
        mountPath: /etc/app/config
        readOnly: true
      - name: secret-volume
        mountPath: /etc/app/secrets
        readOnly: true
volumes:
  - name: config-volume
    configMap:
      name: web-config
  - name: secret-volume
    secret:
      secretName: web-secrets
      defaultMode: 0400         # Read-only by owner
```

The application reads `/etc/app/config/config.json` and `/etc/app/secrets/DATABASE_URL` as files. When the ConfigMap is updated, the kubelet updates the mounted files within 1-2 minutes (the sync period). The application must watch for file changes or be signaled to reload.

Note: Kubernetes Secrets are base64-encoded, not encrypted at rest by default. For actual security, enable encryption at rest (EncryptionConfiguration) or use an external secret store (AWS Secrets Manager, HashiCorp Vault) with the External Secrets Operator.

## Exercise 5: Resource Requests, Limits, and QoS

Understanding the difference between CPU and memory limits is fundamental to running stable workloads.

**CPU is compressible.** When a container exceeds its CPU limit, it is **throttled** --- the kernel's CFS (Completely Fair Scheduler) restricts the container's CPU time. The container runs slower but continues to run. It is never killed for using too much CPU.

**Memory is non-compressible.** When a container exceeds its memory limit, it is **OOMKilled** --- the kernel's OOM killer terminates the process. There is no way to "slow down" memory usage. The container either fits in its limit or it dies.

```
CPU vs MEMORY: WHAT HAPPENS WHEN YOU EXCEED LIMITS
───────────────────────────────────────────────────

CPU (compressible):
  ┌─────────┐     ┌─────────┐     ┌─────────┐
  │ Request │     │ Using   │     │  Limit  │
  │  100m   │ ... │  300m   │ ... │  250m   │
  └─────────┘     └────┬────┘     └─────────┘
                       │
                  Container is THROTTLED.
                  Runs slower. Not killed.
                  CFS quota enforced.

Memory (non-compressible):
  ┌─────────┐     ┌─────────┐     ┌─────────┐
  │ Request │     │ Using   │     │  Limit  │
  │  128Mi  │ ... │  300Mi  │ ... │  256Mi  │
  └─────────┘     └────┬────┘     └─────────┘
                       │
                  Container is OOMKilled.
                  Exit code 137 (128 + SIGKILL=9).
                  Pod restarts (CrashLoopBackOff if repeated).
```

**QoS classes** are assigned automatically based on resource configuration:

| QoS Class | Condition | Eviction Priority |
|-----------|-----------|-------------------|
| **Guaranteed** | Every container has requests == limits for both CPU and memory | Last to be evicted |
| **Burstable** | At least one container has a request or limit set, but they are not all equal | Middle priority |
| **BestEffort** | No requests or limits set on any container | First to be evicted |

When a node runs out of memory, the kubelet evicts pods in order: BestEffort first, then Burstable (sorted by how much they exceed their requests), then Guaranteed (only under extreme pressure). Always set both requests and limits. Setting them equal gives you Guaranteed QoS --- the strongest protection against eviction.

## Exercise 6: Ingress

A Service of type ClusterIP is only reachable inside the cluster. Ingress exposes HTTP/HTTPS routes from outside the cluster to Services inside the cluster.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx       # Which Ingress controller handles this
  tls:
    - hosts:
        - app.example.com
      secretName: app-tls-cert  # Secret containing TLS cert and key
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web-app
                port:
                  number: 80
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-service
                port:
                  number: 8080
```

Ingress requires an **Ingress controller** --- a pod that watches Ingress resources and configures a reverse proxy (typically NGINX, Traefik, or HAProxy). The Ingress resource itself is just configuration; the controller is the data plane that routes traffic.

```
INGRESS TRAFFIC FLOW
────────────────────

Internet
    │
    ▼
Load Balancer (cloud LB or NodePort)
    │
    ▼
Ingress Controller Pod (NGINX)
    │
    ├── Host: app.example.com, Path: /     → Service: web-app:80
    │                                         → Pod 10.244.1.5:80
    │                                         → Pod 10.244.2.8:80
    │
    └── Host: app.example.com, Path: /api  → Service: api-service:8080
                                              → Pod 10.244.1.9:8080
```

Install an Ingress controller (it is not included by default):

```bash
# NGINX Ingress Controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/cloud/deploy.yaml
```

## Putting It All Together

A complete application typically combines all of the above:

```
COMPLETE APPLICATION STACK
──────────────────────────

Ingress (app.example.com)
    │
    ▼
Service (ClusterIP)
    │
    ├──► Pod 1 ──► ConfigMap (config files)
    │              Secret (credentials)
    │              PVC (persistent data)
    │
    ├──► Pod 2 ──► (same mounts)
    │
    └──► Pod 3 ──► (same mounts)
```

Apply resources in dependency order: Namespace, ConfigMap, Secret, PVC, Deployment, Service, Ingress. Or put them all in one file separated by `---` and let `kubectl apply` handle the ordering.

## Further Reading

- [Kubernetes Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/) --- Official Deployment documentation
- [Services documentation](https://kubernetes.io/docs/concepts/services-networking/service/) --- Service types, selectors, and endpoints
- [Ingress documentation](https://kubernetes.io/docs/concepts/services-networking/ingress/) --- Ingress resource specification
- [Resource Management](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) --- Requests, limits, and QoS classes
- [ConfigMap and Secrets](https://kubernetes.io/docs/concepts/configuration/configmap/) --- Configuration management best practices
- [KillerCoda interactive labs](https://killercoda.com/kubernetes) --- Browser-based exercises for Deployments, Services, and Ingress
- [KodeKloud CKAD course](https://kodekloud.com/courses/certified-kubernetes-application-developer-ckad/) --- Hands-on application deployment labs

---

*Next: [Debugging Kubernetes](19-debugging.md)*

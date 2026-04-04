# Chapter 4: The API Model — Declarative State and Reconciliation

## Resources, Objects, Specs, and Status

The Kubernetes API is a **resource-oriented** API. Everything in Kubernetes --- pods, services, deployments, config maps, custom resources --- is a resource with a standard structure:

- **apiVersion**: The API group and version (e.g., `apps/v1`)
- **kind**: The type of resource (e.g., `Deployment`)
- **metadata**: Name, namespace, labels, annotations, resource version, creation timestamp, finalizers, owner references
- **spec**: The **desired state** --- what the user wants
- **status**: The **actual state** --- what the system has observed

This spec/status split is fundamental. The user writes spec; controllers write status. This separation of concerns means that:

1. **The user owns intent.** Only the user (or their tooling) should modify spec. Controllers never modify spec.
2. **Controllers own reality.** Controllers update status to reflect what they have observed and what actions they have taken.
3. **Reconciliation bridges the gap.** The controller's job is to make the real world match spec, and to report the real world in status.

The **resource version** field in metadata is a critical coordination mechanism. It is an opaque string (typically derived from etcd's revision number) that changes every time the object is modified. When a client wants to update an object, it must include the current resource version. If another client has modified the object in the meantime, the resource version will have changed, and the update will fail with a 409 Conflict error. This is **optimistic concurrency control**: clients assume they can make updates without locking, and the system detects and rejects conflicting updates.

## Declarative YAML: Configuration as Data

Kubernetes objects are typically expressed as YAML (or JSON) documents. This is not incidental --- it is a deliberate design choice with deep implications.

By representing desired state as data (YAML files) rather than code (imperative scripts), Kubernetes enables:

- **Version control**: YAML files can be committed to Git, creating a complete history of every change to the cluster's desired state. This is the foundation of GitOps.
- **Code review**: Changes to infrastructure can be reviewed with the same tools and processes used for application code.
- **Diffing**: You can diff two versions of a deployment spec to see exactly what changed.
- **Templating**: Tools like Helm can generate YAML from templates, enabling parameterized deployments.
- **Validation**: YAML can be validated against schemas before being applied, catching errors before they reach the cluster.
- **Dry runs**: `kubectl apply --dry-run=server` sends the YAML to the API server for validation without actually creating resources.

The choice of YAML specifically (rather than JSON, TOML, or a custom DSL) was pragmatic: YAML is human-readable, supports comments (unlike JSON), and was already widely used in the DevOps community (Ansible, Docker Compose). Its verbosity has been criticized, but its universality is a significant advantage.

## Reconciliation Loops: The Engine of Self-Healing

The reconciliation loop is the mechanism by which Kubernetes achieves its declarative guarantees.

Consider what happens when you apply a Deployment object:

```
 kubectl apply                    CONTROL PLANE
     │
     ▼
┌──────────┐  store   ┌──────┐
│API Server │────────►│ etcd │
└────┬──┬───┘         └──────┘
     │  │
     │  │ watch
     │  ▼
     │ ┌────────────────────┐  create    ┌────────────┐
     │ │ Deployment         │──────────►│ ReplicaSet │
     │ │ Controller         │           └─────┬──────┘
     │ └────────────────────┘                 │
     │                                        │ watch
     │                                        ▼
     │                          ┌────────────────────┐  create   ┌─────┐
     │                          │ ReplicaSet         │─────────►│ Pod │
     │                          │ Controller         │          │ Pod │
     │                          └────────────────────┘          │ Pod │
     │                                                          └──┬──┘
     │  watch                                                      │
     ▼                                                             │
┌──────────────┐  bind pod ──► node                                │
│  Scheduler   │───────────────────────────────────────────────────┘
└──────────────┘                           │
                                           │ watch
                                           ▼
                              ┌────────────────────┐
                              │ Kubelet (on node)  │
                              │  → containerd      │
                              │  → start container │
                              └────────────────────┘
```

The following sequence diagram shows the temporal flow --- notice that every component communicates only through the API server:

```
DEPLOYMENT CREATION: SEQUENCE OF EVENTS
────────────────────────────────────────

  User          API Server       etcd        Deployment    ReplicaSet    Scheduler     Kubelet      Endpoint
 (kubectl)                                   Controller    Controller                  (per node)   Controller
    │               │              │              │              │            │             │             │
    │  POST /apis/  │              │              │              │            │             │             │
    │  apps/v1/     │              │              │              │            │             │             │
    │  deployments  │              │              │              │            │             │             │
    ├──────────────▶│              │              │              │            │             │             │
    │               │  store       │              │              │            │             │             │
    │               │  Deployment  │              │              │            │             │             │
    │               ├─────────────▶│              │              │            │             │             │
    │   201 Created │              │              │              │            │             │             │
    │◀──────────────┤              │              │              │            │             │             │
    │               │              │  watch:      │              │            │             │             │
    │               │              │  new Deploy  │              │            │             │             │
    │               │              ├─────────────▶│              │            │             │             │
    │               │              │              │              │            │             │             │
    │               │  create      │  compare:    │              │            │             │             │
    │               │  ReplicaSet  │  0 RS exist  │              │            │             │             │
    │               │◀─────────────┤  need 1      │              │            │             │             │
    │               │  store RS    │              │              │            │             │             │
    │               ├─────────────▶│              │              │            │             │             │
    │               │              │              │  watch:      │            │             │             │
    │               │              │              │  new RS      │            │             │             │
    │               │              │              ├─────────────▶│            │             │             │
    │               │              │              │              │            │             │             │
    │               │  create      │              │  compare:    │            │             │             │
    │               │  3 Pods      │              │  0 pods,     │            │             │             │
    │               │◀─────────────┤──────────────┤  need 3      │            │             │             │
    │               │  store Pods  │              │              │            │             │             │
    │               ├─────────────▶│              │              │            │             │             │
    │               │              │              │              │  watch:    │             │             │
    │               │              │              │              │  3 unbound │             │             │
    │               │              │              │              │  Pods      │             │             │
    │               │              │              │              ├───────────▶│             │             │
    │               │              │              │              │            │             │             │
    │               │  update Pod  │              │              │  assign    │             │             │
    │               │  .spec.      │              │              │  nodeName  │             │             │
    │               │  nodeName    │              │              │  per Pod   │             │             │
    │               │◀─────────────┤──────────────┤──────────────┤────────────┤             │             │
    │               ├─────────────▶│              │              │            │             │             │
    │               │              │              │              │            │  watch:     │             │
    │               │              │              │              │            │  Pod bound  │             │
    │               │              │              │              │            │  to my node │             │
    │               │              │              │              │            ├────────────▶│             │
    │               │              │              │              │            │             │             │
    │               │              │              │              │            │  start      │             │
    │               │              │              │              │            │  containers │             │
    │               │              │              │              │            │  via CRI    │             │
    │               │              │              │              │            │             │             │
    │               │  update Pod  │              │              │            │  report     │             │
    │               │  .status     │              │              │            │  status:    │             │
    │               │  (Running)   │              │              │            │  Running,IP │             │
    │               │◀─────────────┤──────────────┤──────────────┤────────────┤─────────────┤             │
    │               ├─────────────▶│              │              │            │             │             │
    │               │              │              │              │            │             │  watch:     │
    │               │              │              │              │            │             │  Pod Ready  │
    │               │              │              │              │            │             ├────────────▶│
    │               │              │              │              │            │             │             │
    │               │  update      │              │              │            │             │  add Pod IP │
    │               │  Endpoints   │              │              │            │             │  to Service │
    │               │◀─────────────┤──────────────┤──────────────┤────────────┤─────────────┤─────────────┤
    │               ├─────────────▶│              │              │            │             │             │
    │               │              │              │              │            │             │             │
```

Here's the same flow in words:

1. The **API server** validates the Deployment and stores it in etcd.
2. The **Deployment controller** observes the new Deployment. It compares the desired state (e.g., 3 replicas of nginx:1.21) to the actual state (no ReplicaSets exist yet). It creates a new ReplicaSet object.
3. The **ReplicaSet controller** observes the new ReplicaSet. It compares the desired state (3 pods) to the actual state (0 pods). It creates 3 Pod objects.
4. The **Scheduler** observes the 3 unscheduled Pods. For each, it selects a node and updates the Pod's `spec.nodeName`.
5. The **Kubelet** on each selected node observes the Pod assigned to it. It calls the container runtime to start the containers.
6. The **Kubelet** reports the pod's status (running, IP address, etc.) back to the API server.
7. The **Endpoint controller** observes the running Pods and updates the Endpoints object for any matching Services.

Notice how many controllers are involved, each doing a small, independent job, communicating only through the API server. If any controller crashes, it simply restarts and resumes from the current state. If a pod crashes, the ReplicaSet controller detects that the actual count (2) differs from the desired count (3) and creates a replacement. This is self-healing through reconciliation.

## Labels and Selectors: The Soft Linking Mechanism

Kubernetes objects are connected not by hard references (like foreign keys in a relational database) but by **labels and selectors**. A label is a key-value pair attached to an object's metadata (e.g., `app: nginx`, `env: production`). A selector is a query that matches objects by their labels (e.g., `app=nginx,env=production`).

This soft linking is a deliberate design choice:

- **Loose coupling**: A Service does not reference specific Pods by name. It references a label selector, and any Pod matching that selector is included. This means Pods can be created, destroyed, and replaced without updating the Service.
- **Flexibility**: Labels can represent any dimension: application name, version, environment, team, cost center. Selectors can combine dimensions.
- **Composition**: Multiple resources can select the same Pods. A Service, a NetworkPolicy, and a PodDisruptionBudget can all independently select the same set of Pods using the same or different labels.

The label/selector model is inspired by the way tagging works in cloud infrastructure and the way CSS selectors work in web development: you define properties on objects and use queries to match them, rather than building explicit relationship graphs.

## Custom Resource Definitions: Extending the API

One of Kubernetes' most powerful features is the ability to **extend the API with custom resources**. A Custom Resource Definition (CRD) tells the API server about a new type of object --- say, `PostgresCluster` --- including its schema, its API group, and its versions. Once the CRD is installed, users can create, read, update, and delete `PostgresCluster` objects just like built-in resources.

But a CRD alone is just data storage. The magic happens when you pair a CRD with a **custom controller** that watches for `PostgresCluster` objects and reconciles them --- creating the underlying StatefulSets, Services, ConfigMaps, PersistentVolumeClaims, and other resources needed to run an actual PostgreSQL cluster. This combination of CRD + controller is the **Operator pattern**.

CRDs are Kubernetes' answer to the extensibility problem: how do you allow the platform to manage new types of resources without modifying Kubernetes itself? By making the API server a **generic, extensible state store** with a standard interface, Kubernetes enables an ecosystem of operators that teach the system how to manage everything from databases to message queues to machine learning pipelines.

This extensibility was a lesson from Borg, whose fixed API required modifying the system itself to support new workload types. Kubernetes' CRD mechanism democratizes this: anyone can extend the API without forking the project.

## Common Mistakes and Misconceptions

- **"kubectl apply and kubectl create are the same."** `kubectl create` is imperative and fails if the resource already exists. `kubectl apply` is declarative and merges your manifest with the existing resource, making it safe to run repeatedly. In production, always use `apply` for reproducible, idempotent deployments.

- **"I should use kubectl edit in production."** Imperative edits bypass GitOps workflows, code review, and audit trails. Changes made with `kubectl edit` are not tracked in version control and cannot be reproduced. Always use declarative YAML stored in Git and applied through a pipeline.

- **"All Kubernetes resources are namespaced."** Many important resources are cluster-scoped: Nodes, PersistentVolumes, ClusterRoles, ClusterRoleBindings, and Namespaces themselves. Understanding which resources are namespaced and which are cluster-scoped is essential for RBAC and multi-tenancy.

- **"Deleting a resource is instant."** Finalizers can block deletion indefinitely until a controller completes cleanup logic. Pods have a graceful termination period (default 30 seconds) during which they receive SIGTERM before being killed. A resource in "Terminating" state may remain for an extended time.

## Further Reading

- [Kubernetes API Conventions](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md) -- The definitive guide to how Kubernetes API resources are structured, including naming, versioning, spec/status separation, and metadata conventions.
- [Kubernetes API Machinery (apimachinery)](https://github.com/kubernetes/apimachinery) -- The Go library underpinning the Kubernetes API: Group-Version-Resource (GVR), Group-Version-Kind (GVK), runtime.Object, scheme registration, and serialization.
- [Writing Controllers -- Official Kubernetes Sample Controller](https://github.com/kubernetes/sample-controller) -- A minimal but complete example of writing a custom controller using client-go, demonstrating informers, work queues, and the reconciliation loop.
- [client-go Examples](https://github.com/kubernetes/client-go/tree/master/examples) -- Practical examples of interacting with the Kubernetes API from Go: creating resources, setting up watches, using dynamic clients, and leader election.
- [Michael Hausenblas & Stefan Schimanski -- "Programming Kubernetes" (O'Reilly)](https://www.oreilly.com/library/view/programming-kubernetes/9781492047094/) -- The most comprehensive book on the Kubernetes API machinery, custom resources, and controller development patterns.
- [Stefan Schimanski & Antoine Pelisse -- "Deep Dive Into API Machinery" (KubeCon 2019)](https://www.youtube.com/watch?v=qTm-g3vtVOE) --- Detailed walkthrough of API versioning, conversion webhooks, and the request lifecycle.
- [Kubernetes Documentation -- Custom Resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/) -- Official docs on CRDs, structural schemas, validation, versioning, and conversion webhooks for extending the API.

---

Next: [The Networking Model](05-networking.md)

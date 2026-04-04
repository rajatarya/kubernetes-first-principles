# Appendix A: Glossary

This appendix provides a quick-reference glossary for terms used throughout the book. Entries are organized alphabetically with cross-references to the chapter where each concept is covered in depth.

---

**Admission Controller** — A plugin that intercepts requests to the Kubernetes API server after authentication and authorization but before the object is persisted, used to validate or mutate resources. (see [Chapter 39](39-api-internals.md))

**Affinity** — A set of rules that constrain which nodes a Pod can be scheduled on, based on labels on nodes or other Pods. (see [Chapter 33](33-resource-tuning.md))

**API Group** — A logical grouping of related Kubernetes API resources (e.g., `apps`, `batch`, `networking.k8s.io`), enabling independent versioning and extension. (see [Chapter 4](04-api-model.md))

**API Server (kube-apiserver)** — The central management component of the Kubernetes control plane that exposes the Kubernetes API, validates requests, and persists state to etcd. (see [Chapter 3](03-architecture.md))

**ArgoCD** — A declarative, GitOps-based continuous delivery tool for Kubernetes that synchronizes cluster state with Git repositories. (see [Chapter 6](06-ecosystem.md))

**Backstage** — An open-source developer portal framework, originally from Spotify, used to build internal developer platforms with service catalogs and templates. (see [Chapter 35](35-platform-engineering.md))

**Cloud Controller Manager** — A control plane component that embeds cloud-specific control logic, allowing Kubernetes to interact with the underlying cloud provider's APIs for nodes, routes, and load balancers. (see [Chapter 17](17-cloud-integration.md))

**Cluster Autoscaler** — A component that automatically adjusts the number of nodes in a cluster based on pending Pod resource requests and node utilization. (see [Chapter 32](32-node-scaling.md))

**ClusterIP** — The default Service type that exposes a Service on a cluster-internal virtual IP, reachable only from within the cluster. (see [Chapter 5](05-networking.md))

**ClusterRole** — An RBAC resource that defines a set of permissions across all namespaces or for cluster-scoped resources. (see [Chapter 25](25-rbac.md))

**ClusterRoleBinding** — An RBAC resource that grants the permissions defined in a ClusterRole to a user, group, or ServiceAccount cluster-wide. (see [Chapter 25](25-rbac.md))

**CNI (Container Network Interface)** — A specification and set of plugins for configuring networking in Linux containers, used by Kubernetes to set up Pod networking. (see [Chapter 13](13-networking-evolution.md))

**ConfigMap** — A Kubernetes object used to store non-confidential configuration data as key-value pairs, which can be consumed by Pods as environment variables or mounted files. (see [Chapter 18](18-first-workloads.md))

**containerd** — An industry-standard container runtime that manages the complete container lifecycle on a host, commonly used as the runtime in Kubernetes nodes. (see [Chapter 10](10-container-runtimes.md))

**Container Runtime** — The software responsible for running containers on a node, such as containerd or CRI-O. (see [Chapter 10](10-container-runtimes.md))

**Controller** — A control loop that watches the state of the cluster through the API server and makes changes to move the current state toward the desired state. (see [Chapter 38](38-operators.md))

**Controller Manager (kube-controller-manager)** — A control plane component that runs the core set of built-in controllers (ReplicaSet, Deployment, etc.) as a single process. (see [Chapter 3](03-architecture.md))

**CoreDNS** — The default cluster DNS server in Kubernetes, providing service discovery via DNS for Services and Pods. (see [Chapter 5](05-networking.md))

**CRD (Custom Resource Definition)** — An extension mechanism that allows users to define their own resource types in the Kubernetes API without modifying the API server. (see [Chapter 4](04-api-model.md))

**CRI (Container Runtime Interface)** — A plugin interface that enables the kubelet to use different container runtimes without needing to recompile. (see [Chapter 10](10-container-runtimes.md))

**CRI-O** — A lightweight container runtime purpose-built for Kubernetes, implementing the CRI specification. (see [Chapter 10](10-container-runtimes.md))

**CronJob** — A Kubernetes resource that creates Jobs on a recurring schedule defined using cron syntax. (see [Chapter 24](24-jobs.md))

**Crossplane** — An open-source framework that extends Kubernetes to provision and manage cloud infrastructure and services using CRDs and controllers. (see [Chapter 36](36-crossplane.md))

**CSI (Container Storage Interface)** — A standard interface for exposing block and file storage systems to container orchestrators like Kubernetes. (see [Chapter 23](23-storage-patterns.md))

**DaemonSet** — A resource that ensures a copy of a Pod runs on every (or a selected subset of) node in the cluster, commonly used for logging agents and monitoring. (see [Chapter 18](18-first-workloads.md))

**Deployment** — A resource that provides declarative updates for Pods and ReplicaSets, supporting rolling updates and rollbacks. (see [Chapter 18](18-first-workloads.md))

**Device Plugin** — A kubelet framework that allows hardware vendors to advertise specialized resources (GPUs, FPGAs, etc.) to the Kubernetes scheduler without modifying core code. (see [Chapter 41](41-gpu-ml.md))

**Digest** — A content-addressable identifier (usually a SHA-256 hash) that uniquely identifies a specific container image, providing an immutable reference. (see [Chapter 10](10-container-runtimes.md))

**DRA (Dynamic Resource Allocation)** — A Kubernetes framework for requesting and sharing specialized hardware resources (GPUs, accelerators) with fine-grained allocation semantics beyond the device plugin model. (see [Chapter 41](41-gpu-ml.md))

**Edge-triggered** — A reconciliation approach where the controller reacts only when a change event occurs, as opposed to level-triggered reconciliation. (see [Chapter 38](38-operators.md))

**Endpoint** — A network address (IP and port) that represents a single backend for a Service, historically tracked via Endpoints objects. (see [Chapter 5](05-networking.md))

**EndpointSlice** — A scalable replacement for the Endpoints resource that splits endpoint information across multiple objects to reduce API server and etcd load. (see [Chapter 13](13-networking-evolution.md))

**etcd** — A consistent, distributed key-value store used as the primary datastore for all Kubernetes cluster state and configuration. (see [Chapter 3](03-architecture.md))

**ExternalName** — A Service type that maps a Service to an external DNS name, acting as a CNAME alias without proxying. (see [Chapter 5](05-networking.md))

**Finalizer** — A metadata key on a Kubernetes object that prevents deletion until a controller has performed its cleanup logic and removed the finalizer. (see [Chapter 39](39-api-internals.md))

**Flux** — A GitOps toolkit for Kubernetes that keeps clusters in sync with configuration stored in Git repositories. (see [Chapter 6](06-ecosystem.md))

**Gateway API** — A next-generation Kubernetes API for modeling service networking, designed to be expressive, extensible, and role-oriented as a successor to Ingress. (see [Chapter 13](13-networking-evolution.md))

**Grafana** — An open-source observability platform for visualizing metrics, logs, and traces, commonly used alongside Prometheus in Kubernetes monitoring stacks. (see [Chapter 45](45-observability.md))

**GVR (Group/Version/Resource)** — The three-part coordinate system (API group, version, resource name) used to uniquely identify any resource type in the Kubernetes API. (see [Chapter 4](04-api-model.md))

**Helm** — A package manager for Kubernetes that uses templated charts to define, install, and upgrade applications. (see [Chapter 12](12-package-management.md))

**HPA (Horizontal Pod Autoscaler)** — A controller that automatically scales the number of Pod replicas based on observed CPU, memory, or custom metrics. (see [Chapter 30](30-hpa.md))

**Image** — A lightweight, standalone, executable package that includes everything needed to run a piece of software: code, runtime, libraries, and settings. (see [Chapter 10](10-container-runtimes.md))

**Informer** — A client-side caching mechanism in client-go that watches API server resources and maintains a local cache to reduce API server load. (see [Chapter 39](39-api-internals.md))

**Ingress** — A Kubernetes resource that manages external HTTP/HTTPS access to Services, providing load balancing, TLS termination, and name-based virtual hosting. (see [Chapter 5](05-networking.md))

**Ingress Controller** — A controller that fulfills Ingress resources by configuring a load balancer or reverse proxy (e.g., NGINX, Envoy, Traefik). (see [Chapter 13](13-networking-evolution.md))

**Init Container** — A specialized container that runs to completion before any app containers start in a Pod, used for setup tasks like waiting for dependencies or populating shared volumes. (see [Chapter 18](18-first-workloads.md))

**Job** — A Kubernetes resource that creates one or more Pods and ensures a specified number of them successfully terminate, used for batch and one-off tasks. (see [Chapter 24](24-jobs.md))

**Karpenter** — A node provisioning tool that automatically launches right-sized compute nodes in response to unschedulable Pods, offering faster and more flexible scaling than Cluster Autoscaler. (see [Chapter 32](32-node-scaling.md))

**KServe** — A Kubernetes-native platform for serving machine learning models with support for autoscaling, canary rollouts, and multi-framework inference. (see [Chapter 42](42-llm-infrastructure.md))

**kube-proxy** — A network component running on each node that maintains network rules for Service traffic forwarding using iptables, IPVS, or eBPF. (see [Chapter 3](03-architecture.md))

**Kubeflow** — An open-source machine learning platform for Kubernetes that provides tools for ML pipelines, training, tuning, and serving. (see [Chapter 41](41-gpu-ml.md))

**kubelet** — The primary node agent that runs on every node, responsible for ensuring that containers described in PodSpecs are running and healthy. (see [Chapter 3](03-architecture.md))

**KubeRay** — A Kubernetes operator for deploying and managing Ray clusters, commonly used for distributed ML training and inference workloads. (see [Chapter 42](42-llm-infrastructure.md))

**Kustomize** — A template-free configuration management tool built into kubectl that uses overlays to customize Kubernetes manifests for different environments. (see [Chapter 12](12-package-management.md))

**Kyverno** — A Kubernetes-native policy engine that validates, mutates, and generates configurations using policies defined as Kubernetes resources. (see [Chapter 29](29-pod-security.md))

**Label** — A key-value pair attached to Kubernetes objects used for organizing and selecting subsets of resources. (see [Chapter 4](04-api-model.md))

**LeaderWorkerSet** — A Kubernetes API for deploying multi-node distributed workloads with leader-worker topology, commonly used for distributed ML training. (see [Chapter 42](42-llm-infrastructure.md))

**Level-triggered** — A reconciliation approach where the controller continuously compares desired state to actual state and acts on the difference, regardless of what events occurred. (see [Chapter 38](38-operators.md))

**Liveness Probe** — A periodic check that determines whether a container is still running; if it fails, the kubelet restarts the container. (see [Chapter 20](20-production-readiness.md))

**LoadBalancer** — A Service type that exposes the Service externally using a cloud provider's load balancer, automatically provisioning an external IP. (see [Chapter 5](05-networking.md))

**MIG (Multi-Instance GPU)** — An NVIDIA technology that partitions a single GPU into multiple isolated instances, each with dedicated compute, memory, and bandwidth. (see [Chapter 41](41-gpu-ml.md))

**Namespace** — A virtual partition within a Kubernetes cluster that provides scope for resource names and a mechanism for applying policies and resource quotas. (see [Chapter 37](37-multi-tenancy.md))

**NetworkPolicy** — A resource that specifies how groups of Pods are allowed to communicate with each other and with external endpoints, acting as a firewall for Pod traffic. (see [Chapter 26](26-network-policies.md))

**Node** — A worker machine (virtual or physical) in Kubernetes that runs Pods, managed by the control plane. (see [Chapter 3](03-architecture.md))

**NodePool** — A Karpenter resource that defines a set of constraints and instance types for provisioning nodes, replacing the older Provisioner resource. (see [Chapter 32](32-node-scaling.md))

**NodePort** — A Service type that exposes a Service on a static port on every node's IP, making it accessible from outside the cluster. (see [Chapter 5](05-networking.md))

**OCI (Open Container Initiative)** — A set of industry standards for container image formats and runtimes, ensuring interoperability across container tools. (see [Chapter 10](10-container-runtimes.md))

**OPA/Gatekeeper** — Open Policy Agent integrated with Kubernetes via the Gatekeeper project, providing policy enforcement through admission control using the Rego policy language. (see [Chapter 29](29-pod-security.md))

**OpenTelemetry** — A vendor-neutral observability framework for generating, collecting, and exporting telemetry data (traces, metrics, logs) from applications. (see [Chapter 45](45-observability.md))

**Operator** — A pattern that combines a CRD with a custom controller to encode operational knowledge for managing complex applications on Kubernetes. (see [Chapter 38](38-operators.md))

**Owner Reference** — A metadata field on a Kubernetes object that identifies its parent object, enabling garbage collection when the parent is deleted. (see [Chapter 39](39-api-internals.md))

**PersistentVolume (PV)** — A cluster-level storage resource provisioned by an administrator or dynamically via a StorageClass, representing a piece of networked storage. (see [Chapter 23](23-storage-patterns.md))

**PersistentVolumeClaim (PVC)** — A user's request for storage that binds to an available PersistentVolume, abstracting the underlying storage implementation. (see [Chapter 23](23-storage-patterns.md))

**Pod** — The smallest deployable unit in Kubernetes, consisting of one or more containers that share networking and storage and are co-scheduled on the same node. (see [Chapter 3](03-architecture.md))

**Pod Security Standards** — A set of three built-in security profiles (Privileged, Baseline, Restricted) enforced at the namespace level to control Pod security contexts. (see [Chapter 29](29-pod-security.md))

**PodDisruptionBudget (PDB)** — A resource that limits the number of Pods of a replicated application that can be voluntarily disrupted at the same time, ensuring availability during maintenance. (see [Chapter 20](20-production-readiness.md))

**Priority Class** — A resource that defines a priority value for Pods, influencing scheduling order and preemption decisions when cluster resources are scarce. (see [Chapter 33](33-resource-tuning.md))

**Prometheus** — An open-source monitoring and alerting toolkit that collects metrics via a pull model and stores them in a time-series database, widely used in Kubernetes environments. (see [Chapter 45](45-observability.md))

**RBAC (Role-Based Access Control)** — The Kubernetes authorization mechanism that regulates access to resources based on the roles assigned to users or service accounts. (see [Chapter 25](25-rbac.md))

**Readiness Probe** — A periodic check that determines whether a container is ready to accept traffic; failing containers are removed from Service endpoints. (see [Chapter 20](20-production-readiness.md))

**Reconciliation Loop** — The core control pattern in Kubernetes where a controller continuously observes the current state, compares it with the desired state, and takes action to converge them. (see [Chapter 38](38-operators.md))

**Registry** — A service that stores and distributes container images, such as Docker Hub, GitHub Container Registry, or a private registry. (see [Chapter 10](10-container-runtimes.md))

**ReplicaSet** — A resource that ensures a specified number of identical Pod replicas are running at any given time, typically managed by a Deployment. (see [Chapter 18](18-first-workloads.md))

**Resource Quota** — A constraint that limits the aggregate resource consumption (CPU, memory, object count) within a Namespace. (see [Chapter 37](37-multi-tenancy.md))

**Role** — An RBAC resource that defines a set of permissions within a specific Namespace. (see [Chapter 25](25-rbac.md))

**RoleBinding** — An RBAC resource that grants the permissions defined in a Role to a user, group, or ServiceAccount within a specific Namespace. (see [Chapter 25](25-rbac.md))

**runc** — The reference implementation of the OCI runtime specification, a low-level container runtime that spawns and runs containers. (see [Chapter 10](10-container-runtimes.md))

**SBOM (Software Bill of Materials)** — A formal inventory of all components, libraries, and dependencies in a software artifact, used for supply chain security and vulnerability tracking. (see [Chapter 27](27-supply-chain.md))

**Scheduler (kube-scheduler)** — A control plane component that assigns newly created Pods to nodes based on resource requirements, constraints, affinity rules, and scheduling policies. (see [Chapter 3](03-architecture.md))

**Secret** — A Kubernetes object used to store sensitive information such as passwords, tokens, and TLS certificates, encoded in base64. (see [Chapter 28](28-secrets.md))

**Selector** — A query expression that uses labels to filter and identify a set of Kubernetes objects. (see [Chapter 4](04-api-model.md))

**Service** — An abstraction that defines a stable network endpoint (virtual IP and DNS name) for accessing a set of Pods selected by labels. (see [Chapter 5](05-networking.md))

**Service Mesh** — An infrastructure layer that manages service-to-service communication with features like mutual TLS, traffic management, and observability (e.g., Istio, Linkerd). (see [Chapter 13](13-networking-evolution.md))

**ServiceAccount** — A Kubernetes identity assigned to Pods that enables them to authenticate with the API server and other services. (see [Chapter 25](25-rbac.md))

**Sidecar** — A secondary container that runs alongside the main application container within a Pod, providing supporting functionality like logging, proxying, or configuration. (see [Chapter 18](18-first-workloads.md))

**Sigstore** — An open-source project providing tools (Cosign, Fulcio, Rekor) for signing, verifying, and protecting the software supply chain for container images. (see [Chapter 27](27-supply-chain.md))

**StatefulSet** — A resource for managing stateful applications that require stable network identities, persistent storage, and ordered deployment and scaling. (see [Chapter 21](21-statefulsets.md))

**StorageClass** — A resource that defines a class of storage with a provisioner and parameters, enabling dynamic provisioning of PersistentVolumes. (see [Chapter 23](23-storage-patterns.md))

**Taint** — A property applied to a node that repels Pods unless those Pods have a matching Toleration, used to reserve nodes for specific workloads. (see [Chapter 33](33-resource-tuning.md))

**Tag** — A human-readable label (e.g., `v1.2.3`, `latest`) applied to a container image in a registry, which can be overwritten and is therefore mutable. (see [Chapter 10](10-container-runtimes.md))

**Toleration** — A Pod-level property that allows the Pod to be scheduled onto a node with a matching Taint. (see [Chapter 33](33-resource-tuning.md))

**Topology Spread Constraints** — Rules that control how Pods are distributed across failure domains (zones, nodes, etc.) to improve availability and resource utilization. (see [Chapter 33](33-resource-tuning.md))

**Velero** — An open-source tool for backing up, restoring, and migrating Kubernetes cluster resources and persistent volumes. (see [Chapter 43](43-disaster-recovery.md))

**vLLM** — A high-throughput, memory-efficient inference engine for large language models that uses PagedAttention for optimized GPU memory management. (see [Chapter 42](42-llm-infrastructure.md))

**VPA (Vertical Pod Autoscaler)** — A component that automatically adjusts the CPU and memory resource requests of Pods based on historical usage patterns. (see [Chapter 31](31-vpa.md))

**Watch** — An API mechanism that allows clients to receive streaming notifications of changes to Kubernetes resources, enabling reactive controllers. (see [Chapter 39](39-api-internals.md))

**Webhook** — An HTTP callback used in Kubernetes for admission control (validating or mutating webhooks) and for extending API server behavior. (see [Chapter 39](39-api-internals.md))

---

*Back to [Table of Contents](README.md)*

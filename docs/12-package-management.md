# Chapter 12: Package Management and GitOps

## The YAML Explosion

Every Kubernetes resource is defined by a YAML manifest. A simple web application requires, at minimum: a Deployment (to run the pods), a Service (to expose them), a ConfigMap (for configuration), a Secret (for credentials), an Ingress (for external access), a ServiceAccount (for identity), and resource quotas. That is seven YAML files for a single application. A real production application typically requires 15-30 manifests when you include HorizontalPodAutoscalers, PodDisruptionBudgets, NetworkPolicies, PersistentVolumeClaims, and RBAC rules.

```
The YAML Explosion: One Application's Manifests

  Minimal App (7 files)              Production App (15-30 files)
  ┌─────────────────────┐            ┌─────────────────────────────────┐
  │ deployment.yaml     │ Pods       │ deployment.yaml                 │
  │ service.yaml        │ Network    │ service.yaml                    │
  │ configmap.yaml      │ Config     │ configmap.yaml                  │
  │ secret.yaml         │ Creds      │ secret.yaml                     │
  │ ingress.yaml        │ External   │ ingress.yaml                    │
  │ serviceaccount.yaml │ Identity   │ serviceaccount.yaml             │
  │ resourcequota.yaml  │ Limits     │ resourcequota.yaml              │
  └─────────────────────┘            │─────────────────────────────────│
          7 files                    │ hpa.yaml              Scaling   │
             │                       │ pdb.yaml              Uptime    │
             │  "Just add           │ networkpolicy.yaml    Security  │
             │   production          │ pvc.yaml              Storage   │
             │   concerns..."        │ role.yaml             RBAC      │
             │                       │ rolebinding.yaml      RBAC      │
             ▼                       │ limitrange.yaml       Limits    │
     ┌───────────────┐               │ podsecuritypolicy.yaml Safety  │
     │  × 3 envs     │               │ prometheus-rules.yaml  Observe │
     │  (dev/stg/prd)│               │ grafana-dashboard.json Observe │
     └───────────────┘               └─────────────────────────────────┘
             │                                   15-20 files
             ▼                                       │
     ┌───────────────┐                               ▼
     │  7 × 3 = 21   │                      ┌───────────────┐
     │  files minimum │                      │  × 3 envs     │
     └───────────────┘                       │  (dev/stg/prd)│
             │                               └───────────────┘
             │  "But each env differs:                │
             │   replicas, limits,                    ▼
             │   image tags, configs..."     ┌───────────────────┐
             ▼                               │  20 × 3 = 60      │
     ┌────────────────────┐                  │  files to maintain │
     │  21-90 YAML files  │                  └───────────────────┘
     │  for ONE service   │
     └────────────────────┘
```

Now multiply by environments. Most organizations maintain at least three --- development, staging, and production --- with small differences between them: different replica counts, different resource limits, different image tags, different configuration values. If you manage this with raw YAML files, you either maintain three copies of every manifest (tripling the maintenance burden and guaranteeing drift) or you build some ad-hoc templating system with `sed` and environment variables (fragile and error-prone).

This is the **YAML explosion problem**, and it is the root cause behind every tool discussed in this chapter.

## Helm v2: The Package Manager with a Fatal Flaw

**Helm** was introduced in 2016 as "the package manager for Kubernetes," explicitly modeled on apt, yum, and Homebrew. The core abstraction was the **Chart** --- a collection of templated YAML files, a `values.yaml` file containing default parameters, and metadata describing the package.

Helm Charts solved two problems simultaneously:

**Distribution.** A complex application like Prometheus (which requires 10+ Kubernetes resources) could be packaged as a single Chart and installed with one command. Charts could be stored in repositories and versioned. The ecosystem effect was powerful: instead of every user figuring out how to deploy Prometheus on Kubernetes, one person wrote a Chart and everyone benefited.

**Parameterization.** Charts used Go templates to inject values into YAML manifests. A Deployment's replica count might be templated as `{{ .Values.replicaCount }}`, allowing users to override it without modifying the Chart. This addressed the multi-environment problem: you could install the same Chart with different values files for dev, staging, and production.

But Helm v2 had a critical architectural flaw: **Tiller**.

### Tiller: The Security Nightmare

Tiller was a server-side component that ran inside the Kubernetes cluster. When you ran `helm install`, your local Helm client sent the rendered manifests to Tiller, which then applied them to the cluster. Tiller stored release state (which Charts were installed, at which versions, with which values) as ConfigMaps in the cluster.

```
Helm v2 Architecture

  Developer Machine                 Kubernetes Cluster
  ┌──────────────┐                 ┌──────────────────────────────┐
  │  helm CLI    │  gRPC           │                              │
  │              │────────────────>│  Tiller (Deployment)         │
  │  Chart +     │                 │    - cluster-admin access    │
  │  values.yaml │                 │    - renders templates       │
  └──────────────┘                 │    - applies to API server   │
                                   │    - stores state in         │
                                   │      ConfigMaps              │
                                   │                              │
                                   │  Problem: Tiller has         │
                                   │  GOD MODE access to the      │
                                   │  entire cluster              │
                                   └──────────────────────────────┘
```

The problem was that Tiller required **cluster-admin privileges** by default. It needed broad access because it had to create any type of resource in any namespace on behalf of any user. This meant:

- **Any user who could talk to Tiller had effective cluster-admin access.** Tiller did not enforce per-user RBAC. If developer A had permission to deploy only to namespace "team-a," they could use Tiller to deploy anything anywhere, because Tiller itself had cluster-admin access.
- **Tiller was a single point of attack.** Compromise Tiller, and you had full control of the cluster. Tiller's gRPC port was often accessible from any pod in the cluster without authentication.
- **Multi-tenant clusters were unsafe.** Helm v2 was fundamentally incompatible with the principle of least privilege. You could not safely use Helm v2 in a cluster shared by multiple teams with different access levels.

The security community raised alarms repeatedly. Workarounds existed (running one Tiller per namespace, using TLS for the gRPC connection), but they were complex and undermined Helm's ease-of-use promise.

## Helm v3: The Tiller Excision

Helm v3, released in November 2019, removed Tiller entirely. The new architecture was **client-only**: the Helm CLI connected directly to the Kubernetes API server, using the user's own kubeconfig credentials. The user's RBAC permissions determined what Helm could do. If a user only had access to namespace "team-a," Helm would only be able to deploy to namespace "team-a."

Release state moved from ConfigMaps to **Kubernetes Secrets**, stored in the namespace of the release. This was both more secure (Secrets can be encrypted at rest) and more natural (the release metadata lived alongside the release resources).

Helm v3 also added:

- **JSON Schema validation**: Chart authors could define schemas for their values.yaml, catching configuration errors before rendering
- **OCI registry support**: Charts could be stored in container registries alongside images, unifying artifact management
- **Library charts**: reusable chart fragments that could be imported by other charts, reducing duplication
- **Three-way merge for upgrades**: comparing the old manifest, the live cluster state, and the new manifest, enabling safer upgrades when resources had been manually modified

The removal of Tiller was driven by a principle that applies broadly in systems design: **do not bypass the access control layer**. Tiller existed because it was architecturally convenient to have a server-side component that could apply resources. But convenience created a massive security hole. Helm v3 demonstrated that you could achieve the same functionality without a privileged intermediary, simply by having the client talk directly to the API server.

## Kustomize: Template-Free Customization

**Kustomize**, developed by Google and released in 2018, took a fundamentally different approach to the YAML problem. Where Helm used Go templates to parameterize YAML, Kustomize used **overlay-based patching**. No templating language. No `{{ }}` syntax. No Tiller. No client-side rendering. Just plain YAML, composed and patched using a declarative overlay system.

The core idea was simple. You start with a **base** --- a set of plain, valid Kubernetes YAML files that represent your application. Then you create **overlays** --- directories that contain patches describing how to modify the base for a specific environment. An overlay might change the replica count for production, add resource limits for staging, or change the image tag for development.

```
Kustomize Directory Structure

  base/
  ├── kustomization.yaml       # Lists resources
  ├── deployment.yaml           # Plain, valid Kubernetes YAML
  ├── service.yaml              # No templates, no {{ }}
  └── configmap.yaml

  overlays/
  ├── dev/
  │   ├── kustomization.yaml   # References base + patches
  │   └── replica-patch.yaml   # "Change replicas to 1"
  ├── staging/
  │   ├── kustomization.yaml
  │   └── resource-patch.yaml  # "Add resource limits"
  └── prod/
      ├── kustomization.yaml
      ├── replica-patch.yaml   # "Change replicas to 5"
      └── hpa.yaml             # "Add HorizontalPodAutoscaler"
```

Kustomize's key advantage was **diffability**. Because the base files were plain YAML and the patches were plain YAML, you could `diff` any two environments and see exactly what was different. With Helm templates, understanding the difference between two rendered outputs required rendering both and diffing the result --- a lossy process that made code review difficult.

Kustomize was integrated into kubectl itself (`kubectl apply -k ./overlay/prod/`), meaning it required no additional tooling. This made it attractive for organizations that wanted to minimize their dependency footprint.

### Helm vs. Kustomize: Complementary, Not Competing

The community often framed Helm and Kustomize as competitors, but they solve different problems.

**Helm excels at third-party package distribution.** If you want to install Prometheus, PostgreSQL, or NGINX Ingress Controller on your cluster, Helm Charts are the standard distribution mechanism. The Chart author encapsulates the complexity of deploying the application, and you customize it through values. You would not want to maintain your own YAML files for every third-party application you use.

**Kustomize excels at managing your own manifests across environments.** If you are deploying your own application and need to manage small differences between dev, staging, and production, Kustomize's overlay model is simpler and more transparent than Helm templates.

Many organizations use both: Helm for third-party software, Kustomize for their own applications. Some even use Kustomize to patch Helm-rendered output, combining both tools in a pipeline.

## The GitOps Revolution

Helm and Kustomize solved the problem of parameterizing and organizing YAML. But they left a deeper problem unaddressed: **how does the YAML get applied to the cluster?**

The traditional workflow was: a developer modifies manifests, runs `kubectl apply`, and the cluster state changes. This approach has several serious deficiencies:

- **No audit trail.** Who applied what, when? kubectl does not maintain a log. You can check the Kubernetes audit log if it is enabled, but correlating API server events to human actions is difficult.
- **No rollback mechanism.** If a `kubectl apply` causes a problem, reverting requires knowing what the previous state was and manually applying it.
- **No access control beyond RBAC.** Anyone with kubectl access and appropriate RBAC permissions can modify the cluster. There is no approval workflow, no review process, no gate.
- **Drift.** If someone manually modifies a resource in the cluster (a "hot fix"), the cluster state diverges from the YAML files in the repository. Over time, the repository becomes a lie --- it no longer represents what is actually running.

**GitOps** addresses all of these problems by applying a single principle: **Git is the single source of truth for the desired state of the cluster.**

```
GitOps: The Reconciliation Loop

  ┌──────────┐     push      ┌──────────┐
  │Developer │──────────────>│  Git Repo │
  │          │               │  (source  │
  └──────────┘               │  of truth)│
                             └─────┬─────┘
                                   │ watch
                                   │
                             ┌─────▼──────────────────────┐
                             │  GitOps Controller          │
                             │  (ArgoCD / Flux)            │
                             │                             │
                             │  1. Watch Git for changes   │
                             │  2. Compare Git state to    │
                             │     cluster state           │
                             │  3. Reconcile: apply diff   │
                             │     to make cluster match   │
                             │     Git                     │
                             └─────┬──────────────────────┘
                                   │ apply
                                   │
                             ┌─────▼─────┐
                             │ Kubernetes│
                             │ Cluster   │
                             └───────────┘

  Rollback = git revert
  Audit    = git log
  Review   = pull request
  Access   = Git permissions
```

The idea is that a controller running inside the cluster watches a Git repository. When the repository changes (new commit, merged pull request), the controller compares the desired state in Git to the actual state in the cluster and reconciles any differences. This is the **Kubernetes reconciliation pattern applied to deployment itself** --- the same pattern that the Deployment controller uses to reconcile desired and actual pod counts, now applied at the level of the entire cluster configuration.

### ArgoCD

**ArgoCD**, created by Intuit in 2018 and donated to the CNCF, is the most widely adopted GitOps tool. ArgoCD runs as a set of controllers in the cluster and provides a web UI, CLI, and API for managing applications. An ArgoCD "Application" resource defines the mapping: this Git repository, this path, this branch should be deployed to this cluster, this namespace.

ArgoCD supports Helm Charts, Kustomize overlays, plain YAML directories, and Jsonnet as input formats. It provides real-time sync status visualization, showing which resources are in sync with Git and which have drifted. It supports multi-cluster management, RBAC, SSO integration, and automated sync policies.

### Flux

**Flux**, created by Weaveworks in 2017 (and rebuilt as Flux v2 using the GitOps Toolkit), takes a more Kubernetes-native approach. Flux is a set of Custom Resource Definitions (CRDs) and controllers: a GitRepository resource tells Flux where to watch, a Kustomization resource tells Flux how to render and apply the manifests, and a HelmRelease resource tells Flux how to manage Helm releases.

Flux v2 was designed to be composable: each controller does one thing, and they communicate through Kubernetes resources. This makes Flux extensible (you can add image automation controllers, notification controllers, etc.) but also means there are more pieces to understand and configure.

If you manage multiple clusters (dev, staging, production, or multiple production regions), GitOps ensures they are configured from the same source. Promoting a change from staging to production is a Git merge, not a series of manual kubectl commands against different clusters.

## Common Mistakes and Misconceptions

- **"Helm charts are always safe to install."** Helm charts can contain arbitrary Kubernetes resources including ClusterRoles and webhooks. Always review chart templates before installing, especially from unknown sources.
- **"Kustomize replaces Helm."** They solve different problems. Helm templates generate YAML; Kustomize patches existing YAML. Many teams use both: Helm for third-party charts, Kustomize for environment overlays.
- **"Putting all configuration in values.yaml is good practice."** Over-parameterizing Helm charts makes them harder to maintain than raw YAML. Only expose values that actually change between environments.

## Further Reading

- [Helm documentation](https://helm.sh/docs/) -- Official reference for Helm, covering chart structure, templating, release management, and the Helm SDK. Start with the "Chart Developer Guide" for understanding how charts are built.
- [Kustomize documentation](https://kubectl.docs.kubernetes.io/references/kustomize/) -- The template-free customization tool built into kubectl. The "Examples" section demonstrates the overlay pattern for managing environment-specific configurations.
- [Helm Chart Best Practices Guide](https://helm.sh/docs/chart_best_practices/) -- Official guidelines for writing production-quality Helm charts, covering values design, template conventions, labels, and dependency management.
- [Artifact Hub](https://artifacthub.io/) -- The CNCF's central repository for discovering Helm charts, OPA policies, and other Kubernetes packages. Browse to understand the breadth of the ecosystem and how charts are published and versioned.
- ["Helm vs Kustomize" (Harness)](https://www.harness.io/blog/helm-vs-kustomize) -- A practical comparison of the two dominant approaches, covering strengths, weaknesses, when to use each, and how to combine them.
- [cdk8s documentation](https://cdk8s.io/docs/latest/) -- AWS's framework for defining Kubernetes manifests using general-purpose programming languages (TypeScript, Python, Go, Java). Represents the "code over YAML" approach to configuration.
- ["Stop Using Helm" and the counterarguments (archived)](https://web.archive.org/web/2024/https://blog.container-solutions.com/stop-using-helm) -- A provocative critique of Helm's templating approach, useful for understanding the trade-offs that led to alternatives like Kustomize and cdk8s.

---

**Next:** [Chapter 13: The Networking Stack Evolution](13-networking-evolution.md)

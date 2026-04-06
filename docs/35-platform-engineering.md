# Chapter 35: Building Internal Developer Platforms

Kubernetes gives you the building blocks of a platform. It does not give you a platform. A raw Kubernetes cluster presents developers with 60+ resource types, YAML manifests that regularly exceed 200 lines, and a debugging experience that requires understanding networking, storage, scheduling, and Linux internals. Platform engineering is the discipline of assembling these building blocks into something a product developer can use without a week of onboarding.

This is not an abstraction for its own sake. It is a response to a measurable problem: developer cognitive load. When deploying a service requires editing Kubernetes manifests, Terraform modules, CI pipelines, monitoring dashboards, and alerting rules across multiple repositories, developers spend more time on infrastructure plumbing than on the product they are building. Platform engineering inverts this by providing opinionated, pre-built paths that handle the infrastructure automatically.

## The Platform Layers

An internal developer platform is a stack of tools, each handling a layer of the infrastructure problem. The typical production stack looks like this:

| Layer | Purpose | Typical Tools |
|-------|---------|---------------|
| **Developer Interface** | Service catalog, scaffolding, docs, API registry, golden paths | Backstage |
| **Delivery & Deployment** | GitOps continuous delivery, CI pipelines | ArgoCD / Flux, Tekton / GitHub Actions |
| **Infrastructure Provisioning** | Cloud resources as code | Crossplane (CRDs), Terraform (HCL) |
| **Container Platform** | Scheduling, networking, service discovery, autoscaling | Kubernetes |
| **Observability** | Metrics, logs, traces, alerting | Prometheus + Grafana, Loki, Tempo, PagerDuty |

Each layer serves a distinct purpose, and the platform team's job is to integrate them so that developers interact primarily with the top layer.

## Backstage: The Developer Portal

Backstage, originally built at Spotify and now a CNCF incubating project, is the most widely adopted developer portal. It provides:

**Service catalog.** Every service, library, website, and infrastructure component registered in a single searchable catalog. Each entry tracks ownership, dependencies, documentation links, API definitions, CI/CD status, and deployment targets.

**Software templates.** Scaffolding that creates a new service with all the boilerplate pre-configured: repository, CI pipeline, Kubernetes manifests, monitoring dashboards, and Backstage catalog entry. A developer clicks "Create New Service," fills in a form, and gets a production-ready repository in minutes.

**TechDocs.** Documentation generated from Markdown files in the service's repository and rendered in Backstage. This solves the "where do I find docs?" problem by making documentation discoverable alongside the service catalog.

**Plugin ecosystem.** Backstage is extensible via plugins. The Kubernetes plugin shows pod status, deployment history, and logs. The ArgoCD plugin shows sync status. The PagerDuty plugin shows on-call schedules and incidents. This consolidation means developers check one portal instead of switching between five tools.

```yaml
# backstage catalog-info.yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: checkout-service
  description: Handles order checkout and payment processing
  annotations:
    backstage.io/techdocs-ref: dir:.
    argocd/app-name: checkout-service
    pagerduty.com/service-id: P123ABC
  tags:
    - python
    - grpc
spec:
  type: service
  lifecycle: production
  owner: team-payments
  system: commerce-platform
  dependsOn:
    - component:payment-gateway
    - resource:orders-database
  providesApis:
    - checkout-api
```

## Golden Paths

A golden path is a pre-built, opinionated, end-to-end workflow for a common task. It is not a mandate --- developers can deviate --- but it is the supported, documented, well-tested way to do something.

**Examples of golden paths:**

- **Deploy a new microservice:** Use the Backstage template. It creates a repo with Dockerfile, Helm chart, ArgoCD Application, Prometheus ServiceMonitor, and Grafana dashboard. Merge to main triggers CI, which builds the image and updates the Helm values. ArgoCD syncs to the cluster.

- **Add a PostgreSQL database:** File a Crossplane Claim (see Chapter 36). The platform provisions an RDS instance, creates a Kubernetes Secret with credentials, and injects the connection string into the service via environment variables.

- **Scale for a traffic event:** Set the HPA target metric and max replicas in the Helm values file. The platform handles the rest --- HPA, node autoscaling, and monitoring adjustments are pre-configured.

The key property of a golden path is that it requires zero Kubernetes knowledge from the developer. They fill in business-level inputs (service name, language, database size) and the platform handles the infrastructure mapping.

## The Platform Team

Platform engineering is a product discipline, not an infrastructure discipline. The platform team builds a product whose users are developers. This means:

**Measure adoption, not features.** A platform with 50 features that nobody uses is worse than one with 5 features that everyone uses. Track what percentage of services use the golden paths, how long it takes to go from "new service idea" to "running in production," and how many support tickets the platform team receives.

**Treat the platform as an internal product.** Have a roadmap, gather user feedback, prioritize ruthlessly. The most successful platform teams run internal betas, have documentation budgets, and deprecate features deliberately.

**Provide escape hatches.** Golden paths should be the default, not a prison. When a team needs something non-standard (a GPU workload, a non-HTTP service, a custom CRD), the platform should not block them. The platform reduces friction for the 90% case; the 10% case gets manual support.

## Anti-Patterns

**Leaky abstractions.** If the platform hides Kubernetes but developers still need to debug Kubernetes when things go wrong, the abstraction has not reduced cognitive load --- it has added a layer. Good platforms either make the underlying system invisible (developers never need to know it is Kubernetes) or transparent (developers can drill down when they choose to).

**Ignoring the developer experience.** A platform that requires developers to learn a new DSL, install three CLI tools, and read 40 pages of documentation has failed. The best platforms feel like they were designed by someone who has deployed a service in anger.

**No migration path.** Organizations that build v1 of the platform without a plan for migrating existing services end up running two platforms indefinitely. Design for migration from the start.

## A Minimal Starting Stack

For teams beginning their platform engineering journey, the minimal viable stack is:

1. **Kubernetes** (managed: EKS, GKE, or AKS)
2. **ArgoCD** for GitOps deployment
3. **Helm** for templating with sensible defaults
4. **Prometheus + Grafana** for monitoring (or a managed equivalent)
5. **A software template** (even a shell script that generates a repo from a template)

Add Backstage when you have 10+ services and the catalog becomes valuable. Add Crossplane when you need self-service cloud resources. Add Tekton or a CI system when GitHub Actions is insufficient.

The goal is to make the most common developer workflows --- deploy, observe, debug, rollback --- take less than 5 minutes and require no Kubernetes-specific knowledge.

## Common Mistakes and Misconceptions

- **"A platform team should build everything from scratch."** The best platforms compose existing tools (ArgoCD, Crossplane, Backstage) with thin glue layers. Building custom versions of solved problems wastes years and creates maintenance burdens.
- **"If we build it, developers will use it."** Platforms succeed when they're easier than the alternative. If your platform is harder than `kubectl apply`, developers will bypass it. Invest in developer experience and documentation.
- **"Platform engineering is just DevOps renamed."** DevOps is a culture of shared responsibility. Platform engineering builds self-service products (internal developer platforms) that embed operational best practices. The platform is the product; developers are the customers.

## Further Reading

- [Backstage Documentation](https://backstage.io/docs/) --- Official Backstage guides
- [CNCF Platforms White Paper](https://tag-app-delivery.cncf.io/whitepapers/platforms/) --- Principles of cloud-native platforms
- [Team Topologies](https://teamtopologies.com/) --- Organizational patterns for platform teams
- [Platform Engineering on Kubernetes](https://www.manning.com/books/platform-engineering-on-kubernetes) --- Comprehensive book on the topic

---

*Next: [Crossplane](36-crossplane.md) --- Managing cloud infrastructure as Kubernetes CRDs with the universal control plane.*

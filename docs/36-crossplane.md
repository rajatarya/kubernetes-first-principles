# Chapter 36: Crossplane: Infrastructure as CRDs

Crossplane extends Kubernetes' reconciliation engine to any cloud resource --- databases, storage buckets, DNS records, IAM roles --- by representing each as a Kubernetes Custom Resource.

## The Architecture

Crossplane installs as a set of controllers in your Kubernetes cluster. It extends the API server with CRDs that represent cloud resources, then reconciles those CRDs against the actual cloud state via provider plugins.

```
CROSSPLANE RESOURCE FLOW
──────────────────────────

  Developer writes:                    Crossplane reconciles:
  ┌──────────────────┐
  │ Claim (XC)       │     ┌──────────────────────────────────┐
  │                  │     │                                  │
  │ "I need a        │────▶│  Composite Resource (XR)         │
  │  PostgreSQL DB,  │     │  (cluster-scoped, created by     │
  │  medium size"    │     │   Crossplane from Claim)         │
  │                  │     │                                  │
  └──────────────────┘     └──────────────┬───────────────────┘
                                          │
                           Composition    │  maps XR to
                           (template)     │  managed resources
                                          │
                    ┌─────────────────────▼──────────────────┐
                    │                                         │
          ┌────────▼────────┐  ┌────────────────┐  ┌────────▼────────┐
          │ Managed Resource│  │ Managed Resource│  │ Managed Resource│
          │                 │  │                 │  │                 │
          │ RDS Instance    │  │ Subnet Group    │  │ Security Group  │
          │ (provider-aws)  │  │ (provider-aws)  │  │ (provider-aws)  │
          └────────┬────────┘  └────────┬────────┘  └────────┬────────┘
                   │                    │                     │
                   ▼                    ▼                     ▼
          ┌──────────────────────────────────────────────────────┐
          │                    AWS API                            │
          │                                                      │
          │  Actual RDS instance, subnet group, security group   │
          │  created and continuously reconciled                 │
          └──────────────────────────────────────────────────────┘
```

## Core Concepts

### Providers

A Provider is a Crossplane package that installs CRDs and controllers for a specific cloud platform or service. `provider-aws` adds CRDs for RDS, S3, IAM, VPC, and hundreds of other AWS resources. `provider-gcp`, `provider-azure`, `provider-helm`, and `provider-kubernetes` do the same for their respective domains.

Providers authenticate to the cloud API using credentials stored in Kubernetes Secrets or via IRSA/Workload Identity.

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws
spec:
  package: xpkg.upbound.io/upbound/provider-family-aws:v1.17.0
```

### Managed Resources

A Managed Resource is a 1:1 representation of a cloud resource. One Managed Resource maps to exactly one external resource. The Crossplane controller for that resource type continuously reconciles: if the resource does not exist, create it. If it exists but has drifted from the spec, update it. If the Managed Resource is deleted, delete the cloud resource.

```yaml
apiVersion: rds.aws.upbound.io/v1beta2
kind: Instance
metadata:
  name: my-database
spec:
  forProvider:
    region: us-east-1
    instanceClass: db.t3.medium
    engine: postgres
    engineVersion: "15"
    allocatedStorage: 20
    masterUsername: admin
    masterPasswordSecretRef:
      name: db-password
      namespace: crossplane-system
      key: password
  providerConfigRef:
    name: aws-provider
```

This is the lowest-level Crossplane abstraction. Platform teams rarely expose Managed Resources directly to developers --- they are too detailed and cloud-specific.

### Composite Resource Definitions (XRDs)

An XRD defines a new **custom API** --- a higher-level abstraction that hides cloud-specific details. Think of it as defining a new Kubernetes resource type. The XRD specifies the schema (what fields developers can set) and optionally offers a namespaced Claim variant.

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqls.database.example.org
spec:
  group: database.example.org
  names:
    kind: XPostgreSQL
    plural: xpostgresqls
  claimNames:
    kind: PostgreSQL
    plural: postgresqls
  versions:
    - name: v1alpha1
      served: true
      revalidation: Strict
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                size:
                  type: string
                  enum: ["small", "medium", "large"]
                version:
                  type: string
                  default: "15"
              required:
                - size
```

This XRD creates two new resource types: `XPostgreSQL` (cluster-scoped composite resource) and `PostgreSQL` (namespaced claim). Developers only interact with the claim.

### Compositions

A Composition is the template that maps a Composite Resource to one or more Managed Resources. It is where the platform team encodes organizational opinions: which instance types correspond to "small," "medium," and "large," what security groups to attach, what backup policies to apply.

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: postgresql-aws
spec:
  compositeTypeRef:
    apiVersion: database.example.org/v1alpha1
    kind: XPostgreSQL
  resources:
    - name: rds-instance
      base:
        apiVersion: rds.aws.upbound.io/v1beta2
        kind: Instance
        spec:
          forProvider:
            region: us-east-1
            engine: postgres
            publiclyAccessible: false
            storageEncrypted: true
            backupRetentionPeriod: 7
      patches:
        - type: FromCompositeFieldPath
          fromFieldPath: spec.version
          toFieldPath: spec.forProvider.engineVersion
        - type: FromCompositeFieldPath
          fromFieldPath: spec.size
          toFieldPath: spec.forProvider.instanceClass
          transforms:
            - type: map
              map:
                small: db.t3.small
                medium: db.t3.medium
                large: db.r6g.xlarge
```

### Claims

A Claim is the developer-facing interface. It is namespaced (unlike the Composite Resource), so it integrates naturally with team namespaces and RBAC. When a developer creates a Claim, Crossplane creates the corresponding Composite Resource, which the Composition expands into Managed Resources.

```yaml
apiVersion: database.example.org/v1alpha1
kind: PostgreSQL
metadata:
  name: orders-db
  namespace: checkout-team
spec:
  size: medium
  version: "15"
```

Three lines of meaningful configuration. The developer does not need to know about RDS instance classes, security groups, subnet groups, or parameter groups. The platform team has encoded all of those decisions in the Composition.

## Crossplane vs Terraform

Both Crossplane and Terraform manage cloud infrastructure declaratively. The differences are architectural:

| Aspect | Crossplane | Terraform |
|---|---|---|
| **Execution model** | Continuous reconciliation | On-demand apply |
| **State storage** | Kubernetes etcd (CRDs) | State files (S3, local, etc.) |
| **Drift detection** | Automatic, continuous | Manual (`terraform plan`) |
| **Drift correction** | Automatic | Manual (`terraform apply`) |
| **Developer interface** | kubectl, Kubernetes RBAC | CLI, separate auth |
| **Composition** | XRDs + Compositions (CRDs) | Modules (HCL) |
| **Ecosystem** | Growing, CRD-based providers | Massive, mature provider ecosystem |
| **Secret handling** | Kubernetes Secrets, native | State file (secrets in plain text) |

**Crossplane's advantage:** Continuous reconciliation means drift is detected and corrected automatically. If someone manually changes an RDS instance's configuration via the AWS console, Crossplane will notice and revert it on the next reconciliation cycle (typically 1--10 minutes). Terraform only detects drift when someone runs `terraform plan`.

**Terraform's advantage:** Maturity, ecosystem breadth, and the `terraform plan` workflow that lets teams review changes before applying them. Crossplane's reconciliation model means changes to a Composition apply immediately to all resources that use it --- there is no "plan" step.

**In practice,** many organizations use both: Terraform for foundational infrastructure (VPCs, IAM, Kubernetes clusters) managed by a platform team with manual review, and Crossplane for application-level resources (databases, caches, queues) managed self-service by development teams.

## The Universal Control Plane Vision

Crossplane's long-term vision is the "universal control plane" --- a single Kubernetes API server that manages everything: containers, cloud resources, SaaS services, and internal tooling. Instead of developers learning kubectl for Kubernetes, the AWS console for cloud resources, and a CI tool's web interface for pipelines, they interact with a single API that accepts declarative manifests for all of it.

Provider coverage is broad but not total. Complex multi-resource dependencies (create VPC, then subnet, then security group, then RDS instance) require careful ordering in Compositions. Error messages from failed cloud API calls can be opaque. But the trajectory is clear: the Kubernetes resource model is becoming the universal interface for infrastructure management, and Crossplane is the primary vehicle for that expansion.

## Common Mistakes and Misconceptions

- **"Crossplane replaces Terraform."** See the comparison table above. Many organizations use both: Terraform for foundational infrastructure, Crossplane for application-level self-service.
- **"Compositions apply changes immediately with no review."** This is actually true and often a surprise. Unlike Terraform's plan/apply workflow, changing a Composition affects all resources using it immediately. Use Composition revisions and staged rollouts.
- **"Crossplane providers cover every cloud resource."** Coverage is broad but not complete. Check the provider's CRD list before committing to Crossplane for a specific resource. Some niche services may need Terraform or direct API calls.

## Further Reading

- [Crossplane Documentation](https://docs.crossplane.io/) --- Official guides and reference
- [Upbound Marketplace](https://marketplace.upbound.io/) --- Provider and configuration packages
- [Crossplane Getting Started](https://docs.crossplane.io/latest/getting-started/) --- Official introduction and tutorials
- [Crossplane Concepts](https://docs.crossplane.io/latest/concepts/) --- Compositions, XRDs, Claims, and Providers

---

*Next: [Multi-Tenancy](37-multi-tenancy.md) --- Namespace isolation, hierarchical namespaces, vCluster, and when soft boundaries are not enough.*

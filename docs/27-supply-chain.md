# Chapter 27: Supply Chain Security

A container image passes through source code, build systems, registries, and your cluster --- each step is an opportunity for compromise. Supply chain security verifies that nothing was tampered with along the way.

This is not a theoretical concern. The SolarWinds attack (2020) injected malicious code into a build pipeline. The Codecov breach (2021) modified a bash uploader to exfiltrate credentials. The xz utils backdoor (2024) hid a sophisticated compromise in a compression library used by SSH. Kubernetes clusters are particularly exposed because they pull images from external registries on every deployment, and a single compromised base image can propagate to hundreds of workloads.

## The Problem in Layers

```
THE SOFTWARE SUPPLY CHAIN
──────────────────────────

  Source Code ──▶ Build System ──▶ Registry ──▶ Cluster
       │              │              │             │
       ▼              ▼              ▼             ▼
  Was the code     Was the build   Was the       Is the image
  reviewed?        tampered with?  image          allowed to
  Who authored     Was the build   modified       run? Was it
  this commit?     reproducible?   in transit     signed? Is it
                                   or at rest?    from a trusted
                                                  registry?

  ATTACK SURFACE AT EACH STAGE:
  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────────┐
  │ Typo-   │  │ Build   │  │ Registry│  │ Deployment  │
  │ squatted│  │ system  │  │ compro- │  │ of unsigned │
  │ deps    │  │ compro- │  │ mised   │  │ or outdated │
  │         │  │ mised   │  │         │  │ images      │
  └─────────┘  └─────────┘  └─────────┘  └─────────────┘
```

## Image Signing with Sigstore/Cosign

Sigstore is the dominant open-source project for signing and verifying container images. Its key innovation is **keyless signing** --- you do not need to manage long-lived signing keys. Instead, you prove your identity through an existing OIDC provider (GitHub Actions, Google, Microsoft), and Sigstore issues a short-lived certificate tied to that identity.

### The Keyless Signing Flow

```
SIGSTORE KEYLESS SIGNING PIPELINE
───────────────────────────────────

  Developer / CI Pipeline
       │
       │ 1. Request identity token (OIDC)
       ▼
  ┌────────────┐
  │  OIDC      │  GitHub Actions, Google, etc.
  │  Provider   │  Issues JWT with identity claims
  └─────┬──────┘
        │ 2. Present OIDC token
        ▼
  ┌────────────┐
  │  Fulcio    │  Sigstore's certificate authority
  │  (CA)      │  Verifies OIDC token
  │            │  Issues short-lived X.509 cert
  │            │  (valid ~20 minutes)
  └─────┬──────┘
        │ 3. Ephemeral certificate + private key
        ▼
  ┌────────────┐
  │  Cosign    │  Signs the image digest using
  │  (client)  │  the ephemeral private key
  │            │  Pushes signature to registry
  └─────┬──────┘
        │ 4. Record signing event
        ▼
  ┌────────────┐
  │  Rekor     │  Sigstore's transparency log
  │  (log)     │  Immutable, append-only record
  │            │  Proves signing happened at
  │            │  a specific time with a
  │            │  specific identity
  └────────────┘

  VERIFICATION:
  cosign verify checks:
  ✓ Signature matches image digest
  ✓ Certificate was issued by Fulcio
  ✓ Certificate identity matches expected signer
  ✓ Signing event exists in Rekor transparency log
```

### Cosign in Practice

```bash
# Sign an image (keyless, in CI)
cosign sign ghcr.io/myorg/myapp@sha256:abc123...

# Verify an image
cosign verify \
  --certificate-identity=https://github.com/myorg/myapp/.github/workflows/build.yml@refs/heads/main \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  ghcr.io/myorg/myapp@sha256:abc123...

# Sign with a key pair (traditional, for air-gapped environments)
cosign generate-key-pair
cosign sign --key cosign.key ghcr.io/myorg/myapp@sha256:abc123...
cosign verify --key cosign.pub ghcr.io/myorg/myapp@sha256:abc123...
```

### Notation / Notary v2

Notation (the CNCF's Notary v2 project) takes a traditional PKI approach. You manage your own signing keys and certificates, sign images using the `notation` CLI, and store signatures as OCI artifacts alongside the image in the registry.

Notation is the right choice when your organization already has a PKI infrastructure, when you need to comply with regulations that require specific key management practices, or when you operate in air-gapped environments where Sigstore's online services (Fulcio, Rekor) are not reachable.

| Feature | Cosign (Sigstore) | Notation (Notary v2) |
|---------|-------------------|----------------------|
| **Key management** | Keyless (OIDC) or key-pair | Key-pair with PKI |
| **Certificate authority** | Fulcio (public) | Your own CA |
| **Transparency log** | Rekor (public) | None (optional) |
| **Air-gapped support** | Requires key-pair mode | Native |
| **Ecosystem adoption** | Wider (GitHub, GCP, AWS) | Growing (Azure ACR native) |
| **Signature storage** | OCI registry | OCI registry |

## Admission Control: Enforcing Policy at Deploy Time

Signing images is useless unless you verify signatures before deployment. This is the job of admission controllers --- webhook-based components that intercept API requests and enforce policies before objects are created.

### OPA Gatekeeper vs Kyverno

| Feature | OPA Gatekeeper | Kyverno |
|---------|---------------|---------|
| **Policy language** | Rego (purpose-built, steep learning curve) | YAML (Kubernetes-native, familiar) |
| **Mutation** | Supported (via assign/modify) | Native (mutate rules in policy) |
| **Generation** | Not supported | Native (generate resources from policy) |
| **Image verification** | Via external data or custom Rego | Built-in `verifyImages` rule |
| **Validation** | Core strength | Core strength |
| **Audit mode** | Built-in (audit violations without blocking) | Built-in (audit/enforce modes) |
| **Learning curve** | High (Rego is a new language) | Low (YAML-native) |
| **Community** | Mature, CNCF Graduated | Fast-growing, CNCF Incubating |
| **Policy library** | Gatekeeper Library | Kyverno Policies |

For image verification specifically, Kyverno has a significant advantage: signature verification is a first-class feature, not something you bolt on with Rego functions.

```yaml
# Kyverno policy: require Cosign signature from trusted identity
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "ghcr.io/myorg/*"
          attestors:
            - entries:
                - keyless:
                    issuer: "https://token.actions.githubusercontent.com"
                    subject: "https://github.com/myorg/*"
                    rekor:
                      url: "https://rekor.sigstore.dev"
```

## SBOM: Software Bill of Materials

An SBOM is a machine-readable inventory of every component in a container image --- every package and dependency. It answers the question: "When the next Log4Shell happens, are we affected?"

**Generation tools:**

- **Trivy** --- Generates SBOMs as part of its scanning workflow. Supports SPDX and CycloneDX formats. Can scan container images, filesystems, and Git repositories.
- **Syft** --- Anchore's dedicated SBOM generator. Deeper catalog of package types. Outputs SPDX, CycloneDX, and its own JSON format.

**Formats:**

- **SPDX** --- Linux Foundation standard. Widely adopted for compliance. Verbose.
- **CycloneDX** --- OWASP standard. More focused on security use cases. Lighter.

```bash
# Generate SBOM with Trivy
trivy image --format cyclonedx --output sbom.json ghcr.io/myorg/myapp:latest

# Generate SBOM with Syft
syft ghcr.io/myorg/myapp:latest -o spdx-json > sbom.spdx.json

# Attach SBOM to image with Cosign
cosign attach sbom --sbom sbom.json ghcr.io/myorg/myapp@sha256:abc123...
```

## Image Scanning

Scanning should happen in CI, in the registry, and at admission time (via Kyverno/Gatekeeper).

## The SLSA Framework

SLSA (Supply-chain Levels for Software Artifacts, pronounced "salsa") is a framework from Google that defines increasingly rigorous levels of supply chain integrity.

| Level | Name | Requirements |
|-------|------|-------------|
| **0** | No guarantees | No SLSA compliance |
| **1** | Provenance exists | Build process generates provenance metadata documenting how the artifact was built |
| **2** | Hosted build | Build runs on a hosted service (not a developer laptop). Provenance is signed. |
| **3** | Hardened builds | Build service is hardened against tampering. Provenance is non-forgeable. Build is isolated. Source is version-controlled. |

GitHub Actions with reusable workflows can achieve SLSA Level 3 using the `slsa-framework/slsa-github-generator` action, which produces signed provenance attestations.

## Restricting Image Registries

A fundamental control: only allow images from registries you trust.

```yaml
# Kyverno: restrict to approved registries
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-registries
spec:
  validationFailureAction: Enforce
  rules:
    - name: allowed-registries
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Images must come from approved registries."
        pattern:
          spec:
            containers:
              - image: "ghcr.io/myorg/* | registry.internal.company.com/*"
            initContainers:
              - image: "ghcr.io/myorg/* | registry.internal.company.com/*"
```

## Putting It Together: The Secure Pipeline

```
END-TO-END SUPPLY CHAIN SECURITY
──────────────────────────────────

  ┌─────────────┐
  │ Source Code  │  Signed commits, code review,
  │             │  dependency scanning (Dependabot)
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  CI Build   │  SLSA Level 2+: hosted, signed provenance
  │  (GitHub    │  Trivy scan: fail on CRITICAL
  │   Actions)  │  SBOM generation (Syft/Trivy)
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  Sign &     │  Cosign keyless sign
  │  Attest     │  Attach SBOM attestation
  │             │  Record in Rekor transparency log
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  Registry   │  Continuous scanning
  │  (GHCR/ECR) │  Image retention policy
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  Admission  │  Kyverno/Gatekeeper:
  │  Control    │  ✓ Signature verified
  │             │  ✓ Registry allowed
  │             │  ✓ No critical CVEs
  │             │  ✓ SBOM attached
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  Runtime    │  Pod Security Standards
  │  Cluster    │  Network Policies
  │             │  Runtime monitoring (Falco)
  └─────────────┘
```

## Common Mistakes and Misconceptions

- **"I scan images once and they're secure."** New CVEs are discovered daily. Images that were clean yesterday may have critical vulnerabilities today. Continuous scanning in the registry (not just at build time) is essential.
- **"Using official base images means no vulnerabilities."** Even official images contain OS packages with CVEs. Use distroless or scratch-based images to minimize attack surface. Regularly rebuild images to pick up base image patches.
- **"Image signing is enough."** Signing proves provenance but not safety. A signed image can still contain vulnerabilities. Signing + scanning + admission policy (Kyverno/Gatekeeper) together form the chain.

## Further Reading

- [Sigstore documentation](https://docs.sigstore.dev/) --- Cosign, Fulcio, Rekor
- [Kyverno image verification](https://kyverno.io/docs/writing-policies/verify-images/) --- Policy examples
- [SLSA framework](https://slsa.dev/) --- Levels and requirements
- [Trivy documentation](https://aquasecurity.github.io/trivy/) --- Scanning and SBOM generation
- [Notation documentation](https://notaryproject.dev/) --- Notary v2

---

*Next: [Secrets Management](28-secrets.md) --- Encryption at rest, KMS integration, and external secrets operators.*

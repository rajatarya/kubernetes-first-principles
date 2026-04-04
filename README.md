# Kubernetes from First Principles

**Why It Works the Way It Does**

Most Kubernetes resources teach you how to write YAML. This book teaches you why the YAML looks the way it does. 45 chapters covering architecture, security, scaling, platform engineering, and GPU/ML infrastructure --- each traced from the original design problem through the ecosystem's evolution to today's best practice. Written for engineers who know Linux, networking, and how systems work, and want to understand Kubernetes the way they think.

## Start Reading

**[Start here: Table of Contents](docs/00-README.md)**

## What's Inside

| Part | Chapters | Topic |
|------|----------|-------|
| **1. First Principles** | 1-9 | Why Kubernetes exists, its architecture, the API model, networking, and design philosophy |
| **2. Tooling Evolution** | 10-14 | Container runtimes (Docker to containerd), kubeadm history, Helm, GitOps, version history |
| **3. Theory to Practice** | 15-20 | Cluster setup, managed K8s (EKS/GKE/AKS), cloud integration, first workloads, debugging |
| **4. Stateful Workloads** | 21-24 | StatefulSets, databases on K8s, storage patterns, Jobs and CronJobs |
| **5. Security** | 25-29 | RBAC, NetworkPolicies, supply chain, secrets management, Pod Security Standards |
| **6. Scaling** | 30-33 | HPA, VPA, Karpenter, CPU throttling, resource tuning |
| **7. Platform Engineering** | 34-37 | Multi-cluster, Crossplane, internal developer platforms, multi-tenancy |
| **8. Advanced Topics** | 38-45 | Writing operators, API internals, etcd ops, **GPU/ML workloads**, **LLM infrastructure**, DR, cost, observability |
| **Appendices** | A-E | Glossary, mental models, decision trees, troubleshooting quick reference, architecture evolution timeline |

## Who This Is For

- Infrastructure engineers who want to understand Kubernetes deeply, not just follow tutorials
- AI/ML engineers running GPU workloads on Kubernetes (chapters 41-42 go especially deep)
- Platform engineers building internal developer platforms
- Anyone who has used Kubernetes but doesn't feel they truly *understand* it

## What Makes This Different

Every architectural decision is traced back to the problem it solves. Every tool is explained in the context of what existed before it and why it was insufficient. The goal is to build intuition deep enough that you could have designed something similar given the same constraints.

## The Companion Cluster

This repository also includes a working `install.sh` bootstrap script for setting up a 3-node Kubernetes cluster on Ubuntu 22.04 EC2 instances using kubeadm. The script was iteratively debugged during the same session that produced the book --- every error in the troubleshooting section was a real error we encountered.

See the [cluster setup guide](docs/15-cluster-setup.md) for the full walkthrough, or just run:

```bash
# On each Ubuntu 22.04 node:
sudo bash install.sh

# Then on the control plane:
sudo kubeadm init --apiserver-advertise-address=<IP> --pod-network-cidr=10.244.0.0/16
```

## How This Was Made

This book was generated over a weekend (April 3-4, 2026) through a collaboration between a human and Claude Code (Anthropic's Claude Opus 4.6). Research agents gathered material from official Kubernetes documentation, CNCF project pages, cloud provider docs, and academic papers. Writing agents produced the chapters in parallel, followed by editorial passes for coherence, conciseness, and link verification.

See the [Colophon](docs/COLOPHON.md) for the full story, including the exact prompts used to generate each part.

## Contributing

Found an error? A broken link? A concept that could be explained better? Pull requests are welcome.

## License

MIT License. See [LICENSE](LICENSE) for details.

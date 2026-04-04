# Colophon

## How This Book Was Made

This book was written in a single evening session on April 3-4, 2026, through a conversation between a human (Rajat Arya) and Claude Code (Anthropic's Claude Opus 4.6 with 1M context). The entire process — from "help me set up a Kubernetes cluster on EC2" to a published 80,000-word, 45-chapter textbook — happened in one continuous conversation.

## The Process

The book emerged organically from a hands-on Kubernetes learning session. Rajat was setting up a 3-node Kubernetes cluster on AWS EC2 from scratch using `kubeadm`. As we worked through real problems (containerd CRI disabled, SystemdCgroup mismatch, etcd crash loops, missing CNI plugins, API server CrashLoopBackOff), we documented what we learned. That documentation grew into Part 1 (First Principles), then expanded into a full curriculum.

### Generation Method

1. **Research phase**: For each part, specialized research agents were dispatched to search the web (via Actionbook browser automation), read official Kubernetes documentation, blog posts, cloud provider docs, CNCF project pages, and academic papers. Research agents ran in parallel — up to 4 simultaneously — to gather material for different topics.

2. **Writing phase**: Writing agents received the research findings along with detailed chapter outlines specifying what to cover, what tone to use, and what diagrams to include. Writers also ran in parallel — up to 5 simultaneously — each producing 4-8 chapters.

3. **Coherence pass**: A review agent read every chapter, verified all "Next:" links, added cross-references between chapters, wrote part transition paragraphs, and checked tone consistency.

4. **Link verification**: All external URLs were tested for accessibility.

### The Prompts

The book was generated through a series of natural-language prompts. Here are the key ones that shaped each part:

**Part 1 (First Principles, chapters 1-9):**
> "I need to understand how Kubernetes and its ecosystem fit into the modern deployment landscape — but from first principles. I see an infinite number of resources online describing how to use k8s, but I don't see any real information on where it comes from, why it was architected this way, and what problems it seeks to solve."

**Parts 2-3 (Tooling Evolution + Practice, chapters 10-20):**
> "Make a part 2 that includes tool ecosystem history and evolution. Has there always been kubeadm, kubelet, etc? And then part 3 can cover getting started with modern Kubernetes, including setting up a cluster from scratch, using public cloud kubernetes offerings, understanding how Kubernetes networking and storage map to public cloud VM offerings, and provide a more practical hands-on way to connect the theory to practice."

**Parts 4-8 (Stateful, Security, Scaling, Platform, Advanced, chapters 21-45):**
> "I want _all_ of these. I also want the collection of individual topics. It is especially important that I understand the GPU workloads and AI/ML on Kubernetes. Go in as much depth as possible. I need all of these topics to understand the infrastructure at my work."

### Guiding Constraints

These instructions were consistent across all parts:

- **"Focus on WHY decisions were made, not HOW to use the tools."** — This shaped the entire tone. Every chapter explains the reasoning behind design decisions rather than just listing commands.
- **"I know Linux, I know the computer pretty well, and I know networking pretty well."** — This set the audience level. The book doesn't explain what a process is or how TCP works, but it does explain why Kubernetes chose a flat networking model over Docker's port-mapping.
- **"Liberally draw diagrams"** — Every chapter includes ASCII diagrams illustrating architecture, data flow, or concept relationships.
- **"Same tone as part 1"** — The first-principles, textbook-quality tone was established in Part 1 and maintained throughout by referencing the existing chapters as style guides.

## Tools Used

- **Claude Code** (Anthropic Claude Opus 4.6, 1M context) — conversation orchestration, research coordination, writing, and editing
- **Actionbook Browser** — web research automation for gathering source material
- **GitHub CLI (`gh`)** — repository creation and publishing

## The Companion Cluster

The `install.sh` script in this repository is a real, working bootstrap script that was iteratively debugged during the conversation. It went through several revisions:
- v1: Based on an outdated reference script, used deprecated `apt-key`, installed full Docker engine, had wrong CNI plugin version
- v2: Fixed containerd CRI config, added SystemdCgroup, switched to containerd-only (no Docker engine), updated to modern keyring approach
- v3: Fixed CNI plugin version (v1.6.1 didn't exist, updated to v1.9.1), added `conntrack` dependency

Every error documented in the troubleshooting sections of the README and Chapter 15 was a real error encountered during the session.

## Accuracy and Limitations

- **Research was conducted on April 3-4, 2026.** Version numbers, feature statuses, and ecosystem information reflect this date. Kubernetes evolves rapidly — verify versions before following any specific instructions.
- **The AI-generated content was guided by web research** from official documentation, CNCF project pages, and reputable technical blogs. However, AI can hallucinate details. When in doubt, consult the official Kubernetes documentation at https://kubernetes.io/docs/.
- **External links were verified at publication time** but may break as pages move or are removed.
- **The book reflects one learning path.** There are many valid ways to learn Kubernetes. This path emphasizes first-principles understanding over hands-on tutorials, which suits some learners better than others.

## License

This work is published under the MIT License. See [LICENSE](../LICENSE) for details.

## Contributing

Found an error? A broken link? A concept that could be explained better? Contributions are welcome via pull requests.

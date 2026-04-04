# Chapter 7: Key Design Principles

Kubernetes' design reflects a set of principles that are worth making explicit, as they explain many of the system's characteristics.

## Declarative Over Imperative

As discussed extensively in previous chapters, Kubernetes favors declaring desired state over issuing commands. This principle pervades every level of the system, from the API (objects have spec and status, not a command queue) to the controllers (which reconcile rather than execute) to the tooling (kubectl apply rather than kubectl run).

## Control Loops Over Orchestration

As the official documentation states: "Kubernetes is not a mere orchestration system. Orchestration means executing a defined workflow: first do A, then B, then C. Kubernetes comprises a set of independent, composable control processes that continuously drive the current state towards the desired state."

This distinction is subtle but important. An orchestration system is fragile: if step B fails, the entire workflow may need to be restarted or manually intervened. A control-loop system is robust: each controller independently makes progress, and failures in one controller do not block others.

## API-Centric Design

Everything in Kubernetes is an API object. Every component communicates through the API server. There are no hidden side channels, no direct component-to-component communication. This means:

- The API is the complete description of the system's state.
- Any behavior can be observed by watching the API.
- Any component can be replaced by one that speaks the same API.
- The system can be extended by adding new API types (CRDs) and controllers.

## Portability and Vendor Neutrality

Kubernetes was designed from the start to run anywhere: on any cloud provider, on bare metal, on a laptop. This is achieved through abstraction layers (CRI for container runtimes, CNI for networking, CSI for storage) that isolate Kubernetes from the underlying infrastructure. The goal is to prevent vendor lock-in and enable workload portability.

## Extensibility as a First-Class Concern

Kubernetes does not try to solve every problem itself. Instead, it provides extension points at every level: CRDs for custom API types, admission webhooks for custom validation and mutation, custom schedulers, custom controllers, CNI/CRI/CSI plugins. This extensibility is what enables the vast Kubernetes ecosystem.

## The Level-Triggered vs. Edge-Triggered Distinction

Kubernetes controllers are designed to be **level-triggered**, not **edge-triggered**. An edge-triggered system reacts to changes (events): "a pod was deleted." A level-triggered system reacts to state: "the desired count is 3, but the actual count is 2."

The level-triggered approach is more robust because it handles missed events gracefully. If a controller misses the "pod deleted" event (because it was restarting or the watch was disconnected), it will still notice that the actual count is wrong on its next reconciliation and take corrective action. Edge-triggered systems require reliable event delivery; level-triggered systems only require eventual state observation.

This is why Kubernetes controllers are built around Informers that maintain a cached copy of the current state, rather than simple event handlers. The Informer's cache represents the current level, and the controller reconciles against it.

> **Level-Triggered Design**: Kubernetes controllers react to the current state of the world ("there are 2 pods but 3 desired"), not to individual events ("a pod was deleted"). This makes them robust against missed events, disconnections, and restarts. If a controller misses an event, it will still observe the state discrepancy on its next reconciliation cycle and take corrective action.

## Further Reading

- [Level Triggering and Reconciliation in Kubernetes (Hackernoon)](https://hackernoon.com/level-triggering-and-reconciliation-in-kubernetes-1f17fe30333d) -- Essential article explaining why Kubernetes controllers are level-triggered rather than edge-triggered, and how this design choice makes the system resilient to missed events.
- [Kubernetes Enhancement Proposals (KEPs)](https://github.com/kubernetes/enhancements/tree/master/keps) -- The formal process for proposing, discussing, and tracking significant changes to Kubernetes; reading KEPs is the best way to understand the reasoning behind design decisions.
- [Kubernetes Design Proposals Archive](https://github.com/kubernetes/design-proposals-archive) -- Historical archive of early Kubernetes design documents that shaped the API, controllers, and extensibility model before the KEP process was established.
- [James Urquhart, "Flow Architectures" (O'Reilly, 2021)](https://www.oreilly.com/library/view/flow-architectures/9781492075882/) -- Explores event-driven and declarative flow-based systems, providing broader context for why Kubernetes' reconciliation-based approach is part of a larger trend in distributed system design.
- [Kubernetes API Conventions](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-architecture/api-conventions.md) -- The official guide to Kubernetes API design: spec vs. status, metadata conventions, and the principles that make the API consistent and extensible.
- [The Kubernetes Resource Model (Brian Grant, KubeCon)](https://www.youtube.com/watch?v=o1EvMfLHAVE) -- Talk by one of Kubernetes' principal architects explaining the declarative resource model and why it was designed the way it was.

---

Next: [Why Kubernetes Won](08-why-k8s-won.md)

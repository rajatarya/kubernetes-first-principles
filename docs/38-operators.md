# Chapter 38: Writing Controllers and Operators

Kubernetes ships with roughly thirty built-in controllers --- the Deployment controller, the ReplicaSet controller, the Job controller, and so on. Each one watches a particular resource type, compares the desired state in the spec with the actual state in the cluster, and takes action to close the gap. This reconciliation pattern is the engine that makes Kubernetes declarative.

An **operator** is simply a custom controller that encodes domain-specific operational knowledge for a particular application. The Deployment controller knows how to roll out generic pods; a PostgreSQL operator knows how to initialize replicas, manage failover, and orchestrate backups. The extension mechanism is the same --- only the knowledge embedded in the reconciliation logic differs.

This chapter covers how to build operators using the standard Go toolchain: the controller-runtime library and its scaffolding tool, Kubebuilder.

## The Reconcile Loop

Every controller follows the same fundamental pattern. The control plane delivers a **reconcile request** --- essentially a namespace/name pair --- and the controller's job is to make reality match the desired state for that object. The loop looks like this:

```
THE RECONCILE LOOP
───────────────────

  ┌──────────────────────────────────────────────────────────────┐
  │                      Work Queue                              │
  │  ┌──────────┐  ┌──────────┐  ┌──────────┐                   │
  │  │ ns/name  │  │ ns/name  │  │ ns/name  │  ...               │
  │  └────┬─────┘  └──────────┘  └──────────┘                   │
  └───────┼──────────────────────────────────────────────────────┘
          │
          ▼
  ┌───────────────┐
  │  1. FETCH     │  Get the primary resource by ns/name.
  │               │  If not found (deleted) → cleanup → return.
  └───────┬───────┘
          │
          ▼
  ┌───────────────┐
  │  2. LIST      │  List owned/related child resources
  │               │  (Deployments, Services, ConfigMaps, etc.)
  └───────┬───────┘
          │
          ▼
  ┌───────────────┐
  │  3. COMPARE   │  Diff desired state (from spec) against
  │               │  actual state (from listed resources).
  └───────┬───────┘
          │
          ▼
  ┌───────────────┐
  │  4. ACT       │  Create missing resources.
  │               │  Update drifted resources.
  │               │  Delete obsolete resources.
  └───────┬───────┘
          │
          ▼
  ┌───────────────┐
  │  5. STATUS    │  Update the status subresource of the
  │               │  primary resource (conditions, counts, etc.)
  └───────┬───────┘
          │
          ▼
  ┌───────────────┐
  │  6. RETURN    │  Return a Result:
  │               │    error       → requeue with backoff
  │               │    RequeueAfter → requeue after duration
  │               │    empty       → done (terminal)
  └───────────────┘
```

## Kubebuilder Scaffolding

Kubebuilder generates the boilerplate so you can focus on the reconciliation logic. A typical workflow:

```bash
# Initialize a new project
kubebuilder init --domain example.com --repo github.com/example/myoperator

# Create an API (CRD + controller)
kubebuilder create api --group apps --version v1alpha1 --kind MyApp

# Create a webhook (optional)
kubebuilder create webhook --group apps --version v1alpha1 --kind MyApp \
  --defaulting --programmatic-validation
```

This generates a directory structure with `api/v1alpha1/myapp_types.go` (your CRD schema), `internal/controller/myapp_controller.go` (your Reconcile function), and the wiring to register everything with the manager.

## The Reconcile Function Skeleton

Here is the canonical structure in Go using controller-runtime:

```go
package controller

import (
    "context"
    "fmt"
    "time"

    appsv1 "k8s.io/api/apps/v1"
    corev1 "k8s.io/api/core/v1"
    "k8s.io/apimachinery/pkg/api/errors"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
    "k8s.io/apimachinery/pkg/runtime"
    ctrl "sigs.k8s.io/controller-runtime"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/controller-runtime/pkg/log"

    myappv1 "github.com/example/myoperator/api/v1alpha1"
)

type MyAppReconciler struct {
    client.Client
    Scheme *runtime.Scheme
}

func (r *MyAppReconciler) Reconcile(ctx context.Context,
    req ctrl.Request) (ctrl.Result, error) {

    logger := log.FromContext(ctx)

    // ── Step 1: Fetch the primary resource ──────────────────
    var app myappv1.MyApp
    if err := r.Get(ctx, req.NamespacedName, &app); err != nil {
        if errors.IsNotFound(err) {
            logger.Info("MyApp deleted, nothing to do")
            return ctrl.Result{}, nil
        }
        return ctrl.Result{}, err // requeue with backoff
    }

    // ── Step 2: List owned child resources ──────────────────
    var childDeploys appsv1.DeploymentList
    if err := r.List(ctx, &childDeploys,
        client.InNamespace(req.Namespace),
        // NOTE: This field selector requires a custom index. You must register it
        // in SetupWithManager using mgr.GetFieldIndexer().IndexField() — it does
        // not work out of the box. See the controller-runtime documentation for
        // how to set up custom field indexes.
        client.MatchingFields{"metadata.ownerReferences.uid": string(app.UID)},
    ); err != nil {
        return ctrl.Result{}, err
    }

    // ── Step 3: Compare desired vs actual ───────────────────
    desiredReplicas := app.Spec.Replicas
    if len(childDeploys.Items) == 0 {
        // ── Step 4a: Create ─────────────────────────────────
        deploy := r.buildDeployment(&app)
        if err := ctrl.SetControllerReference(&app, deploy, r.Scheme); err != nil {
            return ctrl.Result{}, err
        }
        if err := r.Create(ctx, deploy); err != nil {
            return ctrl.Result{}, err
        }
        logger.Info("Created Deployment", "replicas", desiredReplicas)
    } else {
        // ── Step 4b: Update if drifted ──────────────────────
        existing := &childDeploys.Items[0]
        if *existing.Spec.Replicas != desiredReplicas {
            existing.Spec.Replicas = &desiredReplicas
            if err := r.Update(ctx, existing); err != nil {
                return ctrl.Result{}, err
            }
        }
    }

    // ── Step 5: Update status ───────────────────────────────
    if len(childDeploys.Items) > 0 {
        app.Status.ReadyReplicas = childDeploys.Items[0].Status.ReadyReplicas
    }
    app.Status.Phase = "Running"
    if err := r.Status().Update(ctx, &app); err != nil {
        return ctrl.Result{}, err
    }

    // ── Step 6: Return result ───────────────────────────────
    return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
}
```

Notice that the status update uses `r.Status().Update()` --- this hits the `/status` subresource, which has a separate authorization check and does not modify the spec. This separation is deliberate: it prevents a controller that only needs to report status from accidentally mutating the desired state.

## Watches and Predicates

A controller must tell the manager which objects to watch. The `SetupWithManager` method configures this:

```go
func (r *MyAppReconciler) SetupWithManager(mgr ctrl.Manager) error {
    return ctrl.NewControllerManagedBy(mgr).
        For(&myappv1.MyApp{}).              // primary resource
        Owns(&appsv1.Deployment{}).          // child resource
        Owns(&corev1.Service{}).             // another child
        WithEventFilter(predicate.GenerationChangedPredicate{}).
        Complete(r)
}
```

**`.For()`** registers a watch on the primary resource. When a MyApp object is created, updated, or deleted, a reconcile request is enqueued.

**`.Owns()`** registers a watch on child resources and automatically maps events back to the owning parent. If someone manually edits a Deployment owned by your MyApp, the controller will reconcile the parent MyApp --- and correct the drift.

**Predicates** filter which events actually trigger reconciliation. `GenerationChangedPredicate` skips status-only updates (since `.metadata.generation` only increments on spec changes). You can write custom predicates for arbitrary filtering:

```go
withAnnotation := predicate.NewPredicateFuncs(func(obj client.Object) bool {
    return obj.GetAnnotations()["myapp.example.com/managed"] == "true"
})
```

## Requeue Logic

The return value of `Reconcile` controls what happens next:

| Return Value | Behavior |
|---|---|
| `ctrl.Result{}, nil` | Terminal. No requeue. The controller is done until the next watch event. |
| `ctrl.Result{}, err` | Immediate requeue with exponential backoff (default 5ms → 1000s). |
| `ctrl.Result{Requeue: true}, nil` | Immediate requeue (no backoff). Use sparingly. |
| `ctrl.Result{RequeueAfter: 30s}, nil` | Scheduled requeue. Useful for polling external systems. |

The exponential backoff on error is critical. Without it, a controller that encounters a persistent error (like a missing dependency) would hammer the API server in a tight loop. The backoff gives transient errors time to resolve and limits the blast radius of permanent failures.

## Concurrency and Idempotency

By default, a controller processes one reconcile request at a time. You can increase parallelism:

```go
ctrl.NewControllerManagedBy(mgr).
    WithOptions(controller.Options{MaxConcurrentReconciles: 5}).
    Complete(r)
```

But this means two reconcile calls for different objects may run simultaneously. Your Reconcile function **must be idempotent** --- calling it twice with the same input must produce the same result. It must also be safe for concurrent execution across different keys. Never rely on in-memory state between reconciliations; always read from the API server.

## Leader Election

In production, operators typically run with two or more replicas for availability. Only one replica should be actively reconciling at any time. controller-runtime supports leader election out of the box:

```go
mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
    LeaderElection:   true,
    LeaderElectionID: "myapp-operator-lock",
})
```

Leader election uses a Lease object in the cluster. The active leader renews the lease periodically. If it fails to renew (crash, network partition), another replica acquires the lease and begins reconciling. The transition typically takes 15--30 seconds depending on configuration.

## Webhook Development

Kubebuilder scaffolds two types of admission webhooks:

**Mutating (Defaulting) webhooks** modify incoming objects before they are persisted. Use these to inject default values, add labels, or set fields the user omitted:

```go
func (r *MyApp) Default() {
    if r.Spec.Replicas == 0 {
        r.Spec.Replicas = 3
    }
    if r.Spec.Image == "" {
        r.Spec.Image = "myapp:latest"
    }
}
```

**Validating webhooks** reject invalid objects. They run after mutating webhooks and return an error if the object violates business rules:

```go
func (r *MyApp) ValidateCreate() (admission.Warnings, error) {
    if r.Spec.Replicas > 100 {
        return nil, fmt.Errorf("replicas cannot exceed 100")
    }
    return nil, nil
}
```

Webhooks require TLS certificates. In production, use cert-manager to automate certificate provisioning and rotation.

## The Operator Maturity Model

The Operator Framework defines five maturity levels. Most operators in the wild sit at Level 1 or 2. Reaching Level 5 is rare and typically reserved for complex stateful systems.

```
OPERATOR MATURITY MODEL
────────────────────────

  Level 5 │  AUTO PILOT
           │  Automatic scaling, tuning, anomaly detection.
           │  Horizontal/vertical scaling based on load.
           │  Self-healing beyond simple restart.
           │
  Level 4 │  DEEP INSIGHTS
           │  Expose metrics, alerts, log processing.
           │  Grafana dashboards, SLO tracking.
           │  Workload-specific telemetry.
           │
  Level 3 │  FULL LIFECYCLE
           │  Automated backup/restore.
           │  Version upgrades with data migration.
           │  Configuration tuning.
           │
  Level 2 │  SEAMLESS UPGRADES
           │  Patch and minor version upgrades.
           │  Operand configuration changes.
           │  No downtime during upgrades.
           │
  Level 1 │  BASIC INSTALL
           │  Automated deployment and configuration.
           │  Operator manages basic provisioning.
           │
           └──────────────────────────────────────────────
             Increasing automation and operational knowledge
```

Start at Level 1. Level 3 is the inflection point where automated backup and upgrades pay off. Level 5 (auto-pilot) is rare; CockroachDB and ECK are examples.

## Putting It All Together

1. **Start with the API.** Design your CRD spec and status carefully. They are a contract with your users. Changing them later requires conversion webhooks and migration paths.

2. **Keep Reconcile idempotent.** If you create a resource, check whether it already exists first. If you update, compare before patching. Never assume the world has not changed between your List and your Create.

3. **Use owner references.** They give you garbage collection for free and enable the `.Owns()` watch pattern. When the parent is deleted, all owned children are cleaned up automatically.

4. **Separate spec from status.** Always use the status subresource. Never let the controller modify the spec.

5. **Test with envtest.** controller-runtime includes an integration test harness that spins up a real API server and etcd without needing a full cluster. Use it.

6. **Think about failure modes.** What happens when the API server is unreachable? When a child resource is stuck terminating? When two operators fight over the same resource? The answers should be in your code, not in a runbook.

## Common Mistakes and Misconceptions

- **"Every application needs an Operator."** Operators are for stateful, complex applications that need operational automation (databases, message queues). A stateless web service managed by a Deployment does not need an Operator.
- **"Writing an Operator is straightforward."** Operators encode operational expertise in code. The happy path is simple, but handling every failure mode (partial updates, resource conflicts, cascading failures) correctly takes significant engineering effort.
- **"Operators are always better than Helm charts."** Helm charts are simpler: apply once, done. Use Operators when you need active reconciliation; use Helm when install-time configuration is sufficient.
- **"All Operators on OperatorHub are production-quality."** OperatorHub lists community and vendor operators with varying maturity levels. Check the capability level (basic install through full lifecycle) and community adoption before deploying to production.

## Further Reading

- [Operator pattern](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/) --- the official Kubernetes documentation explaining the operator concept, when to use one, and how operators extend the API.
- [Operator SDK documentation](https://sdk.operatorframework.io/docs/) --- the full guide for building operators with the Operator SDK, covering Go, Ansible, and Helm-based operators.
- [The Kubebuilder Book](https://book.kubebuilder.io/) --- a comprehensive tutorial that walks through building a controller from scratch using kubebuilder, including CRD design, webhook configuration, and testing.
- [OperatorHub.io](https://operatorhub.io/) --- a catalog of community and vendor operators you can install in your cluster, useful for understanding what problems operators solve in practice.
- [Introducing Operators](https://web.archive.org/web/2024/https://coreos.com/blog/introducing-operators.html) --- the original CoreOS blog post by Brandon Philips that coined the term "operator" and explained the motivation behind encoding operations knowledge in software.
- [controller-runtime documentation](https://pkg.go.dev/sigs.k8s.io/controller-runtime) --- API reference for the Go library that underpins both kubebuilder and Operator SDK, covering the Manager, Controller, Reconciler, and client interfaces.
- [Programming Kubernetes (O'Reilly)](https://www.oreilly.com/library/view/programming-kubernetes/9781492047094/) --- a book by Michael Hausenblas and Stefan Schimanski that covers the Kubernetes API machinery, custom resources, and operator development in depth.

---

**Next:** [The Kubernetes API Internals](39-api-internals.md) --- how requests flow through admission, what aggregated API servers are, and how API priority and fairness protects the control plane.

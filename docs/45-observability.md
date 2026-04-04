# Chapter 45: Observability with OpenTelemetry

Running a Kubernetes cluster without observability is like driving at night with the headlights off. You know you are moving, but you cannot see what is ahead, you cannot explain what just happened, and when something goes wrong, your only diagnostic tool is hope.

Observability is the ability to understand the internal state of a system by examining its external outputs. In a Kubernetes environment, those outputs are **metrics** (numerical measurements over time), **logs** (discrete events with context), and **traces** (the path of a request through multiple services). These are the three pillars, and OpenTelemetry is the open standard that unifies how they are collected, processed, and exported.

## The Three Pillars

**Metrics** answer "what is happening right now and how does it compare to the past?" CPU utilization, request latency percentiles, error rates, queue depths. Metrics are cheap to store, fast to query, and excellent for dashboards and alerting. They are terrible for debugging specific requests.

**Logs** answer "what happened in this specific component at this specific time?" A stack trace, a SQL query that failed, a configuration value that was loaded. Logs are rich in context but expensive to store and slow to search at scale. They are excellent for debugging but terrible for detecting trends.

**Traces** answer "what was the path of this specific request through the system?" A user clicks checkout, which calls the cart service, which calls inventory, which calls the database. A trace captures the timing and outcome of each hop. Traces are essential for debugging latency in distributed systems and nearly useless for anything else.

No single pillar is sufficient. Effective observability requires all three, correlated so you can move from a metric anomaly to the relevant traces to the specific log lines that explain the root cause.

## OpenTelemetry Architecture

OpenTelemetry (OTel) provides a vendor-neutral framework for instrumentation, collection, and export of telemetry data. The key components are:

- **SDKs:** Language-specific libraries that instrument applications (auto-instrumentation or manual)
- **Collector:** A standalone binary that receives, processes, and exports telemetry data
- **Protocol (OTLP):** The wire format for transmitting telemetry between components

### Collector Deployment Patterns

The Collector is the workhorse of the OTel pipeline. How you deploy it determines the reliability, scalability, and cost of your observability stack.

```
OTEL COLLECTOR DEPLOYMENT PATTERNS
────────────────────────────────────

  PATTERN 1: DAEMONSET / AGENT (most common, ~81% of deployments)
  ┌──────────────────────────────────────────────────────────────┐
  │  Node 1                    Node 2                            │
  │  ┌───────┐ ┌───────┐     ┌───────┐ ┌───────┐               │
  │  │ App A │ │ App B │     │ App C │ │ App D │               │
  │  └───┬───┘ └───┬───┘     └───┬───┘ └───┬───┘               │
  │      │         │              │         │                    │
  │      ▼         ▼              ▼         ▼                    │
  │  ┌──────────────────┐   ┌──────────────────┐                │
  │  │  OTel Collector  │   │  OTel Collector  │                │
  │  │  (DaemonSet)     │   │  (DaemonSet)     │                │
  │  └────────┬─────────┘   └────────┬─────────┘                │
  └───────────┼──────────────────────┼───────────────────────────┘
              │                      │
              ▼                      ▼
        ┌──────────────────────────────────┐
        │         Backends                  │
        │  (Prometheus/Mimir, Loki, Tempo)  │
        └──────────────────────────────────┘

  PATTERN 2: SIDECAR
  ┌──────────────────┐
  │  Pod             │
  │  ┌─────┐ ┌─────┐│     Per-pod collector.
  │  │ App │→│OTel ││     High isolation.
  │  └─────┘ └──┬──┘│     High resource overhead.
  └─────────────┼───┘
                ▼
            Backend

  PATTERN 3: GATEWAY
  ┌───────┐ ┌───────┐ ┌───────┐
  │ App A │ │ App B │ │ App C │
  └───┬───┘ └───┬───┘ └───┬───┘
      │         │         │
      └────────┬┘─────────┘
               ▼
  ┌──────────────────────────┐
  │   OTel Collector Gateway │     Centralized collector.
  │   (Deployment, scaled)   │     Single point for processing.
  │   (load-balanced)        │     Easier to manage, SPOF risk.
  └────────────┬─────────────┘
               ▼
           Backend
```

**DaemonSet (Agent)** is the recommended pattern for most clusters. Each node runs a collector pod that receives telemetry from all application pods on that node via localhost. This minimizes network hops, provides natural load distribution, and fails gracefully (a collector crash affects only one node).

**Sidecar** provides the strongest isolation --- each application pod has its own collector. Use this when different applications require different collection configurations or when you need strict resource accounting per application. The cost is significant: every pod runs an additional container.

**Gateway** centralizes collection into a single deployment. Use this as a second tier behind agents (agent → gateway → backend) for cross-cutting processing like tail sampling, enrichment, or routing to multiple backends. Do not use a gateway as the sole collector tier --- it creates a single point of failure.

The production pattern most teams arrive at is **Agent + Gateway**: DaemonSet collectors on every node forward to a gateway deployment that handles sampling and export.

## The LGTM Stack

The most widely adopted open-source backend stack for Kubernetes observability is LGTM:

| Component | Signal | Role |
|---|---|---|
| **L**oki | Logs | Log aggregation. Indexes labels, not content. Cheap at scale. |
| **G**rafana | All | Visualization and dashboarding. Unified query interface. |
| **T**empo | Traces | Distributed tracing backend. Object-storage-based. |
| **M**imir | Metrics | Long-term metrics storage. Horizontally scalable Prometheus. |

This stack is entirely open source (all Grafana Labs projects under AGPLv3) and can be self-hosted or consumed as Grafana Cloud. The key advantage over alternatives is the tight integration --- Grafana can correlate a metric spike to traces to logs without leaving the UI.

```
THE LGTM STACK
────────────────

  Applications
       │
       ▼
  ┌──────────────────────────┐
  │   OTel Collector Agent   │
  │   (DaemonSet)            │
  └────┬─────────┬──────┬────┘
       │         │      │
  metrics    traces   logs
       │         │      │
       ▼         ▼      ▼
  ┌────────┐ ┌──────┐ ┌──────┐
  │ Mimir  │ │Tempo │ │ Loki │
  │(metrics)│ │(trace)│ │(logs)│
  └────┬───┘ └──┬───┘ └──┬───┘
       │        │        │
       └────────┼────────┘
                │
                ▼
         ┌───────────┐
         │  Grafana  │
         │  (query,  │
         │  visualize,│
         │  alert)   │
         └───────────┘
```

## The OpenTelemetry Operator

The OTel Operator is a Kubernetes operator that manages OTel Collectors and provides **auto-instrumentation** for application pods.

### Auto-Instrumentation

Instead of modifying application code to import OTel SDKs, you annotate pods and the operator injects the instrumentation automatically:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-service
  annotations:
    instrumentation.opentelemetry.io/inject-java: "true"
spec:
  template:
    spec:
      containers:
        - name: checkout
          image: myapp/checkout:v1.2.3
```

The operator supports auto-instrumentation for:

- **Java** --- via a Java agent injected as an init container
- **Python** --- via the `opentelemetry-instrument` wrapper
- **.NET** --- via the .NET startup hook
- **Node.js** --- via the `@opentelemetry/auto-instrumentations-node` package
- **Go** --- via eBPF-based instrumentation (more limited than other languages)

Auto-instrumentation captures HTTP requests, database queries, gRPC calls, and messaging operations without any code changes. It is the fastest path to distributed tracing in an existing application.

### Instrumentation Resource

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: default-instrumentation
  namespace: production
spec:
  exporter:
    endpoint: http://otel-collector.observability:4317
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_traceidratio
    argument: "0.1"          # sample 10% of traces
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:latest
  python:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-python:latest
```

## Signal Correlation

The power of observability comes from connecting the three signal types. When a metric alert fires for high latency on the checkout service, you want to click through to the traces that show which downstream call is slow, and then to the log lines from that specific call.

This requires **consistent identifiers** across signals:

- **Trace context propagation:** Every HTTP or gRPC call propagates `traceparent` headers (W3C Trace Context standard). The OTel SDKs handle this automatically.
- **Trace ID in logs:** Configure your logging library to include the trace ID and span ID in every log line. This allows Grafana to jump from a trace to the exact log lines produced during that span.
- **Exemplars in metrics:** Prometheus exemplars attach a trace ID to a specific metric observation, so you can click from a latency histogram bucket to a representative trace.

```
SIGNAL CORRELATION FLOW
─────────────────────────

  Grafana Dashboard
  ┌──────────────────────────────────────────────────┐
  │  Checkout Latency p99 = 1.2s  [▲ spike at 14:23]│
  │                                    │             │
  │  Click exemplar ──────────────────▶│             │
  │                                    ▼             │
  │  Trace: abc123                                   │
  │  ├── checkout-svc    200ms                       │
  │  ├── inventory-svc   150ms                       │
  │  └── payment-svc     850ms  ◄── slow!            │
  │                        │                         │
  │  Click span ───────────▶                         │
  │                        ▼                         │
  │  Logs for payment-svc, traceID=abc123:           │
  │  14:23:01 WARN  Connection pool exhausted        │
  │  14:23:01 ERROR Timeout waiting for DB connection │
  └──────────────────────────────────────────────────┘
```

Without correlation, you have three independent systems. With it, you have a single diagnostic workflow that can trace a user-visible symptom to its root cause in minutes.

## Production Lessons

Teams that have deployed OTel in production at scale converge on a common set of lessons:

### Version-Lock Everything

The OTel ecosystem moves fast. The Operator, Collector, and auto-instrumentation images must be compatible. Pin all three to tested versions and upgrade them together:

```yaml
# Do not use "latest" in production
operator: ghcr.io/open-telemetry/opentelemetry-operator:v0.96.0
collector: otel/opentelemetry-collector-contrib:0.96.0
java-agent: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.1.0
```

### Memory Requirements

OTel Collectors buffer data in memory. Under load, a DaemonSet collector can easily consume 1--2 GB of memory. Gateway collectors handling high-cardinality traces may need 4 GB or more. Size your collector pods with appropriate requests and limits, and set `memory_limiter` processor as the first processor in your pipeline:

```yaml
processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 1500
    spike_limit_mib: 500
```

### Start with Traces, Not Metrics

If you already have Prometheus for metrics, adding OTel for traces provides the most incremental value. Auto-instrumentation gives you distributed tracing with zero code changes. Migrating metrics to OTel can come later (and for many teams, Prometheus remains the better choice for metrics).

### Sampling is Essential

Collecting 100% of traces is prohibitively expensive at scale. Use tail sampling at the gateway tier to keep:

- All error traces
- All slow traces (above a latency threshold)
- A random sample of normal traces (1--10%)

This captures the traces you actually need for debugging while keeping storage costs manageable.

### Target Allocator for Prometheus Scraping

If you use the OTel Collector to scrape Prometheus endpoints (replacing Prometheus itself), the **Target Allocator** distributes scrape targets across collector replicas. Without it, every collector scrapes every target, duplicating data. The Target Allocator requires careful resource provisioning --- plan for 4 GB+ nodes in the allocator pool.

## What to Monitor About Your Monitoring

Observability infrastructure is itself a system that can fail. Monitor:

- Collector memory and CPU usage (alert before OOM)
- Export failures (collector cannot reach backend)
- Queue depth (data backing up faster than it can be exported)
- Span drop rate (how much data is being discarded)
- Backend ingestion rate and storage growth

An observability system that silently drops data during the incident you need to debug is worse than no observability at all, because it gives you confidence that is not warranted.

---

**Back to:** [Table of Contents (README.md)](README.md)

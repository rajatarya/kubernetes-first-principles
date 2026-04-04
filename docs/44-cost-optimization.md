# Chapter 44: Cost Optimization

Kubernetes makes it easy to deploy applications and hard to understand what they cost. A developer requests 2 CPU cores and 4 GB of memory for a service that uses 0.3 cores and 800 MB at peak. Multiply that by hundreds of services across dozens of namespaces, and you arrive at the industry average: **only 13% of requested CPU is actually used**. The rest is reserved but idle, burning money on cloud provider invoices.

## The Cost Problem

The disconnect between requested and used resources exists because of a rational incentive: nobody wants their service to be OOM-killed or CPU-throttled, so everyone over-provisions.

```
THE RESOURCE EFFICIENCY GAP
─────────────────────────────

  Requested CPU                   Actual CPU Used
  ┌──────────────────────────┐   ┌──────────────────────────┐
  │██████████████████████████│   │███░░░░░░░░░░░░░░░░░░░░░░│
  │██████████████████████████│   │███░░░░░░░░░░░░░░░░░░░░░░│
  │██████████████████████████│   │███░░░░░░░░░░░░░░░░░░░░░░│
  │         100 cores        │   │  13 cores   87 wasted    │
  └──────────────────────────┘   └──────────────────────────┘

  ██ = Allocated/Used    ░░ = Allocated but Idle

  Industry average: 13% CPU utilization of requested resources
  Typical savings from right-sizing: 30-50%
```

This is not a Kubernetes problem per se --- the same over-provisioning existed in the VM world. But Kubernetes makes it both more visible (you can measure it) and more actionable (you can change it without reprovisioning hardware).

## Right-Sizing with VPA and Goldilocks

The **Vertical Pod Autoscaler (VPA)** observes actual resource usage over time and recommends (or automatically sets) CPU and memory requests. In recommendation mode, it does not change anything --- it just tells you what the values should be.

**Goldilocks** (from Fairwind) wraps VPA in a dashboard that shows recommendations for every deployment in a namespace. It creates a VPA object in recommendation mode for each deployment and surfaces the results in a web UI.

```bash
# Install Goldilocks
helm install goldilocks fairwinds-stable/goldilocks --namespace goldilocks

# Enable for a namespace
kubectl label namespace production goldilocks.fairwinds.com/enabled=true
```

After a few days of observation, Goldilocks will show you something like:

| Deployment | Current Request | Recommended | Monthly Savings |
|---|---|---|---|
| api-server | 2 CPU / 4 Gi | 500m CPU / 1 Gi | $340 |
| worker | 4 CPU / 8 Gi | 1.5 CPU / 3 Gi | $520 |
| frontend | 1 CPU / 2 Gi | 200m CPU / 512 Mi | $180 |
| cache | 2 CPU / 16 Gi | 500m CPU / 12 Gi | $85 |

Typical savings from right-sizing are **30--50%** of compute cost. This is the lowest-effort, highest-impact optimization available.

**Caution:** Do not blindly apply VPA recommendations. Review them in the context of peak load, seasonal patterns, and latency requirements. A recommendation based on two weeks of low traffic will not survive Black Friday.

## Spot and Preemptible Instances

Cloud providers sell unused capacity at steep discounts --- 60--90% off on-demand pricing. The trade-off is that the instances can be reclaimed with as little as 30 seconds notice (AWS Spot) or 2 minutes (GCP Preemptible/Spot).

Kubernetes makes spot instances practical because it was designed for failure. Pods are ephemeral. Deployments replace terminated pods automatically. The key is ensuring your workloads can tolerate interruption.

### Karpenter and Spot

Karpenter excels at spot instance management. It can:

- Diversify across many instance types to reduce interruption probability
- Automatically replace interrupted nodes
- Mix spot and on-demand in a single NodePool via `capacity-type` weights
- Consolidate workloads onto fewer nodes as demand decreases

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot-workers
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: node.kubernetes.io/instance-type
          operator: In
          values: ["m5.xlarge", "m5a.xlarge", "m6i.xlarge",
                   "m6a.xlarge", "c5.xlarge", "c6i.xlarge"]
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
  limits:
    cpu: "200"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 60s
```

**Best practice:** Run control plane workloads (monitoring, CI, databases) on on-demand instances. Run stateless application workloads (web servers, API handlers, batch jobs) on spot. The cost savings typically range from **60--90%** for the spot-eligible portion of your fleet.

## Cost Attribution with Kubecost and OpenCost

You cannot optimize what you cannot measure. Kubecost and OpenCost provide cost attribution --- breaking down cluster costs by namespace, deployment, label, or any other dimension.

**OpenCost** is the open-source standard for Kubernetes cost monitoring, donated to the CNCF by Kubecost. It calculates costs by:

1. Querying cloud provider pricing APIs for node costs
2. Allocating node costs to pods based on resource requests (and optionally usage)
3. Adding persistent volume and network costs
4. Aggregating by any Kubernetes metadata (namespace, label, annotation)

### Chargeback via Labels

The foundation of cost attribution is consistent labeling. Every workload should carry labels that identify its owner and purpose:

```yaml
metadata:
  labels:
    app.kubernetes.io/name: checkout-service
    app.kubernetes.io/part-of: ecommerce
    cost-center: "CC-4521"
    team: payments
    environment: production
```

With these labels, you can generate reports like:

| Team | Namespace | Monthly Cost | CPU Efficiency | Memory Efficiency |
|---|---|---|---|---|
| Payments | payments-prod | $4,200 | 22% | 45% |
| Search | search-prod | $8,100 | 31% | 52% |
| ML | ml-training | $12,500 | 78% | 65% |
| Platform | monitoring | $2,300 | 15% | 40% |

The ML team has high efficiency because GPU workloads tend to saturate resources. The platform team has low efficiency because monitoring tools are sized for peak incident load. Context matters --- not every namespace should target the same efficiency percentage.

## Cluster Consolidation

### Karpenter Consolidation

Karpenter's consolidation feature continuously evaluates whether workloads can be packed onto fewer or cheaper nodes:

- **WhenEmpty:** Remove nodes that have no non-daemonset pods.
- **WhenEmptyOrUnderutilized:** Also replace nodes when their workloads could fit on other existing nodes or on a single cheaper node.

This is particularly powerful in clusters with variable load. During off-peak hours, Karpenter consolidates workloads onto fewer nodes and terminates the empties. During peak, it scales back out.

### kube-green for Off-Hours

Many development and staging environments are used only during business hours. **kube-green** scales workloads to zero during off-hours:

```yaml
apiVersion: kube-green.com/v1alpha1
kind: SleepInfo
metadata:
  name: working-hours
  namespace: development
spec:
  weekdays: "1-5"
  sleepAt: "20:00"
  wakeUpAt: "08:00"
  timeZone: "America/New_York"
  suspendDeployments: true
  suspendStatefulSets: true
  suspendCronJobs: true
```

If your development cluster costs $10,000/month and is used 10 hours a day, 5 days a week, kube-green can reduce that to roughly $3,000/month --- a **70% savings** with zero impact on developer productivity.

## Unused Resource Detection

Waste hides in plain sight. Common sources of orphaned cost:

- **Unattached PersistentVolumes:** PVCs deleted but PVs retained due to `Retain` reclaim policy. Cloud disks still billing.
- **Idle load balancers:** Services of type LoadBalancer that no longer receive traffic.
- **Orphaned node groups:** Managed node groups or ASGs with minimum size > 0 but no workloads scheduled.
- **Oversized namespaces:** Test namespaces that were never cleaned up.
- **Unused ConfigMaps and Secrets:** Resources referenced by nothing.

Tools like `kubectl-cost` (from Kubecost), `pluto` (for deprecated APIs), and custom scripts that compare resource references against actual usage can surface these.

## Optimization Strategy Comparison

| Strategy | Effort | Typical Savings | Risk |
|---|---|---|---|
| Right-sizing (VPA/Goldilocks) | Low | 30--50% | Under-provisioning causes latency/OOM |
| Spot/Preemptible instances | Medium | 60--90% of eligible workloads | Interruption, requires fault tolerance |
| Off-hours scaling (kube-green) | Low | 50--70% for non-prod | Forgot to wake up before a demo |
| Cluster consolidation (Karpenter) | Medium | 20--40% | Consolidation churn, scheduling delays |
| Unused resource cleanup | Low | 5--15% | Accidentally deleting needed resources |
| Reserved instances / savings plans | Low | 30--40% vs on-demand | Lock-in, less flexibility |
| Namespace resource quotas | Low | Preventive (caps waste) | Blocks legitimate scaling |

The highest-ROI strategy for most organizations is to start with right-sizing (immediate, low-risk, high-impact) and then layer on spot instances for eligible workloads. Together, these two strategies alone typically reduce compute costs by 50--70%.

## Building a Cost-Aware Culture

Tools and automation are necessary but not sufficient. Cost optimization sticks only when teams have visibility and accountability:

1. **Dashboard visibility.** Put cost dashboards where developers already look --- Grafana, Backstage, Slack summaries. If people have to seek out cost data, they will not.

2. **Cost in the deploy pipeline.** Show the cost impact of resource request changes in pull request comments. "This change increases monthly cost for checkout-service by $120."

3. **Team-level budgets.** Allocate cloud budgets to teams, not just to the organization. When a team sees that their namespace costs $8,000/month, they start asking whether that staging environment with 16 replicas is really necessary.

4. **Regular review cadence.** Monthly cost reviews at the team level, quarterly at the organization level. Celebrate wins (a team that cut costs 40% through right-sizing) and investigate anomalies (a namespace that doubled in cost with no traffic increase).

The goal is not to minimize cost --- it is to maximize the value per dollar.

## Common Mistakes and Misconceptions

- **"Kubernetes saves money."** Kubernetes adds overhead: control plane costs, monitoring, engineer expertise, and operational complexity. It saves money at scale through bin-packing and automation, but small deployments often cost more than VMs.
- **"Spot instances are always 60-90% cheaper."** Spot pricing is dynamic. Popular instance types in busy regions may offer small discounts. Diversify across instance families and AZs. Karpenter handles this automatically.
- **"Right-sizing is a one-time task."** Application resource needs change with code changes, traffic patterns, and data growth. Continuous monitoring with VPA recommendations or tools like Kubecost is necessary to prevent drift.

## Further Reading

- [OpenCost Documentation](https://www.opencost.io/docs) --- the CNCF open-source standard for real-time Kubernetes cost monitoring with allocation by namespace, label, and deployment.
- [OpenCost Project](https://www.opencost.io/) --- the CNCF sandbox project for Kubernetes cost monitoring, providing a vendor-neutral open-source specification and implementation for cost allocation.
- [FinOps Foundation](https://www.finops.org/) --- the industry body defining FinOps practices, frameworks, and maturity models for managing cloud costs across engineering and finance teams.
- [AWS: Best Practices for EC2 Spot Instances](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-best-practices.html) --- AWS guidance on diversifying instance types, handling interruptions, and using Spot with EKS node groups and Karpenter.
- [GKE Cost Optimization Guide](https://cloud.google.com/kubernetes-engine/docs/best-practices/cost-optimization) --- Google's recommendations for GKE right-sizing, cluster autoscaling, committed use discounts, and Spot VMs.
- [Kubernetes Documentation: Resource Management for Pods and Containers](https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/) --- the official reference for requests, limits, QoS classes, and LimitRanges that form the foundation of cost control.
- [Goldilocks by Fairwind](https://github.com/FairwindsOps/goldilocks) --- an open-source tool that runs VPA in recommendation mode and presents a dashboard of right-sizing suggestions per workload.

---

**Next:** [Observability with OpenTelemetry](45-observability.md) --- making sure you can see what is happening inside all these workloads.

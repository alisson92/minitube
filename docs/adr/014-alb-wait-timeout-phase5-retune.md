# 014 — Retuning the ALB wait budget after Phase 5's concurrent load

## Status

Accepted

## Context

`terraform apply` of `envs/lab` failed at `null_resource.wait_for_alb`
(`terraform/envs/lab/cloudfront.tf`) with "timed out waiting for ALB
'minitube-app' to be provisioned by aws-load-balancer-controller". A
second run of `apply`, right afterward, passed with no code change at
all — a symptom of insufficient margin in the wait budget, not a logic
bug.

`null_resource.wait_for_alb` and its poll via `aws elbv2 describe-load-balancers`
already existed since [ADR 010](010-lbc-orphan-cleanup-and-alb-wait.md), with
a **5-minute** budget (30 attempts × 10s), calibrated in a session
before Phase 5 with a sample of only 2 real runs (2min01s and
2min11s). At that point, `helm_release.argocd_apps` bootstrapped 5
Applications: `app`, `platform`, `aws-load-balancer-controller`,
`external-dns`, and `cert-manager`.

Since then, [ADR 011](011-observability-stack.md) (Phase 5 —
observability) added 3 more Applications to the **same**
`helm_release.argocd_apps`: `ebs-csi-driver`, `kube-prometheus-stack`
(Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics), and
`loki`. The 8 Applications now sync concurrently on ArgoCD,
competing for CPU, memory, and image-pull bandwidth on the same 3 fixed
`t3.medium` nodes (`eks_node_desired_size = var.eks_node_min_size =
var.eks_node_max_size = 3`, no Cluster Autoscaler/Karpenter) -- exactly
while `aws-load-balancer-controller` also needs to come up, complete
*leader election*, and only then reconcile `gitops/app/`'s `Ingress` to
provision the ALB. ADR 010's 5-minute budget was never revisited after
this increase in concurrent load introduced by ADR 011 -- the
root cause is this retuning gap, not a failure of the poll mechanism
itself (which remains correct: `depends_on` alone doesn't wait for
in-cluster reconciliation, it only orders API calls).

## Decisions

### 1. Budget raised from 5min to 15min (900s)

Without a second round of real measurements (the goal here is to give
enough margin for the observed variance, not to recalibrate through
extensive sampling), 900s was chosen as 3x the previous budget --
enough slack for the current bootstrap concurrency without leaving
`apply` stuck for a disproportionate time if the problem is something
else (e.g., a genuinely broken `aws-load-balancer-controller`). A 15-minute
timeout at this point is still a small fraction of a full `apply` of an
environment from scratch.

### 2. Loop rewritten by elapsed time, with progress logging

The `for i in $(seq 1 30)` (fixed attempt count) became a `while`
loop over elapsed seconds (`deadline_seconds=900`, `interval_seconds=10`).
Easier to retune in the future (a single value in seconds, rather than a
count of attempts × interval), and each iteration now emits a `stderr`
line with the elapsed time -- prevents `apply` from going completely
silent for up to 15 minutes, in line with the observable-solutions
principle (`docs/engineering-standards.md`).

**Discarded alternative:** keeping the fixed attempt count and just
increasing the number. Rejected as less readable (the total budget stays
implicit in the multiplication of two numbers) and for not naturally
opening room for the progress log.

## Consequences

- `terraform/envs/lab/cloudfront.tf`: `null_resource.wait_for_alb`'s script
  rewritten (900s budget, elapsed-time loop, progress logging);
  the resource's comment now references this ADR in addition to 010.
- Real functional validation (whether the new budget actually eliminates
  the intermittency) depends on the environment's next full `apply` cycle --
  not run in this session, which fixed the code with the previous
  cycle's `destroy` already in progress. If a future session observes a new
  timeout even with the 900s, that's a sign the cause is no longer just time
  margin (revert to the hypothesis of a real problem in
  `aws-load-balancer-controller`, not just budget retuning).
- 2nd calibration of the same mechanism since ADR 010 -- if a 3rd
  happens, consider replacing the AWS API poll with an observable
  condition directly in the cluster (e.g., waiting on the `Ingress`'s
  `status.loadBalancer` via `kubectl`), which reflects the real
  reconciliation instead of inferring through an external proxy.

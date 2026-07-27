# 015 — Automating the cleanup of the orphaned metrics-server APIService on destroy

## Status

Accepted

## Context

Repetition of the symptom already documented in [`docs/runbooks/run-the-project.md`](../runbooks/run-the-project.md)
(section "If `destroy` hangs on `kubernetes_namespace_v1.argocd`/`.platform`"):
`terraform destroy` of `envs/lab` got stuck on `kubernetes_namespace_v1.argocd`
and `kubernetes_namespace_v1.platform` for 5+ minutes, ending in
`Error: context deadline exceeded`, right after `helm uninstall` of
`argocd-apps` (which pruned the `metrics-server` Application).

Root cause (already diagnosed in the session that produced the runbook, now fixed
in code): destroying `helm_release.argocd_apps` removes the `metrics-server`
Application from ArgoCD, which in turn uninstalls the chart -- but the
`APIService` `v1beta1.metrics.k8s.io` (a cluster-scoped API registration, created
by the chart, managed neither by Terraform nor directly by ArgoCD)
survives, pointing to a backend that no longer exists. As long as this broken
`APIService` exists, the entire cluster's API discovery fails
(`DiscoveryFailed: metrics.k8s.io/v1beta1: stale GroupVersion discovery`), and
Kubernetes's namespace-finalization controller -- which depends on this
complete discovery -- hangs for **any** namespace in termination, not
just the metrics-server's own. This blocks the two namespaces managed directly
by Terraform (`kubernetes_namespace_v1.argocd`/`.platform`, needed
since decision 12 of [ADR 011](011-observability-stack.md) for
`kubernetes_secret_v1.grafana_admin`).

Until this session, the fix was only documented as a manual playbook: run
`kubectl delete apiservice v1beta1.metrics.k8s.io`, then re-run
`terraform destroy`. Functional, but violates the goal of `destroy` running
from start to finish in a single execution with no human intervention (the same
goal already pursued by [ADR 010](010-lbc-orphan-cleanup-and-alb-wait.md) for
`apply`).

## Decisions

### 1. `null_resource` with `provisioner "local-exec" { when = destroy }`

Added `null_resource.cleanup_stale_metrics_apiservice`
(`terraform/envs/lab/argocd.tf`), whose destroy-time provisioner runs
`aws eks update-kubeconfig` (generating an ephemeral kubeconfig in `mktemp`,
never touching `~/.kube/config` -- important because the operator's machine's
default context points at a local Kind cluster, not this project's EKS)
followed by `kubectl delete apiservice v1beta1.metrics.k8s.io
--ignore-not-found`.

**Why AWS CLI + kubectl via `local-exec`, not the `kubernetes` provider:**
destroy-time provisioners can only reference the resource's own
attributes (`self`) -- they cannot reference other resources/data sources directly,
because there's no guarantee about their state at that point in the destroy. That's why
`cluster_name` and `aws_region` are passed via the `null_resource`'s own
`triggers` and read as `self.triggers.*` inside the script, instead of
interpolating `module.eks.cluster_name`/`var.aws_region` directly in the command (which
Terraform would reject: "Invalid reference from destroy provisioner").
A `data "kubernetes_..."` wouldn't work either -- the `kubernetes` provider doesn't
expose a declarative way to delete a resource it never created itself.

### 2. Ordering: after `argocd_apps`, before the namespaces

`helm_release.argocd_apps` gained `null_resource.cleanup_stale_metrics_apiservice`
in its `depends_on`, and the `null_resource` itself has
`depends_on = [kubernetes_namespace_v1.argocd, kubernetes_namespace_v1.platform]`.
Since `destroy` inverts the dependency order (whoever depends is destroyed
first), this forces the sequence: `argocd_apps` destroyed first (the
`metrics-server` Application is pruned, the `APIService` is left orphaned) → the
`null_resource` destroyed next (runs the cleanup, exactly when the
`APIService` is already orphaned but before any namespace tries to finalize)
→ the two namespaces destroyed last, now without the broken API
discovery in the way.

**Discarded alternative:** adding the cleanup as a destroy provisioner directly
on `kubernetes_namespace_v1.argocd`/`.platform` themselves.
Rejected because a dedicated `null_resource` makes the ordering explicit and
reusable (a single resource covers both namespaces), instead of
duplicating the same script in two places with the same race condition
between them.

### 3. `docs/runbooks/run-the-project.md` updated, not removed

The manual playbook section was kept, but rewritten to note that the
cleanup is now automatic (referencing this ADR) -- useful as a fallback
diagnostic in case the `null_resource` itself fails for some reason (e.g.,
`aws`/`kubectl` missing from `PATH`, or a root cause different from the
already-known one).

## Consequences

- `terraform/envs/lab/argocd.tf`: new `resource "null_resource"
  "cleanup_stale_metrics_apiservice"`; `helm_release.argocd_apps` gains this
  additional dependency.
- `docs/runbooks/run-the-project.md`: manual playbook section updated
  to reflect the automation, kept as a documented fallback.
- **Does not retroactively cover a `destroy` already in progress/stuck at the exact
  moment this fix was written** -- the `null_resource` only comes into
  play once it exists in the state (i.e., after an
  `apply` that creates it, even as a no-op). To unblock an execution already
  stuck at the namespaces with `helm_release.argocd_apps` already destroyed (out of
  state), the most direct option is `terraform apply -target=null_resource.cleanup_stale_metrics_apiservice`
  followed by a normal `terraform destroy` -- not the old manual playbook.
  Only from the next complete `apply`→`destroy` cycle from scratch does the
  automation cover the scenario end to end without this extra step.
- Real functional validation (that the automation actually eliminates the
  `context deadline exceeded`) not yet run in this session -- to be
  recorded as a future update once a complete cycle confirms it.

# 016 — Active poll instead of the fixed `time_sleep` for access entry propagation

## Status

Accepted

## Context

A `terraform apply` of `envs/lab`, recreating the environment from scratch to validate the fixes from ADRs 014/015, failed right after the node group finished:

```
kubernetes_namespace_v1.argocd: Creating...
kubernetes_namespace_v1.platform: Creating...
Error: Unauthorized
```

`terraform state list` confirmed that `module.eks.time_sleep.operator_access_propagation` was already in the state (i.e., the 30s had already run and completed successfully) when the error happened right afterward — ruling out the obvious hypothesis of "the sleep never even ran."

**Root cause:** the same race already documented in decision 2 of [ADR 009](009-eks-access-entries-and-api-edge-routing.md): `CreateAccessEntry`/`AssociateAccessPolicy` return success from the AWS API in ~1s, but the EKS control plane's *authorizer* takes a **variable** amount of extra time to actually recognize the new principal — with no `describe`/wait exposed by the AWS API to confirm this propagation. ADR 009 chose a fixed 30s for this wait, an estimate ("a few extra seconds") with no real sampling. Just as the fixed budget for `wait_for_alb` (ADR 010) needed retuning in ADR 014 earlier in this same session, the 30s proved insufficient this time — the same bug class: a fixed, arbitrary value for an AWS propagation delay that isn't constant. (The error showed up as `401 Unauthorized` instead of the original `403 Forbidden` from ADR 009 — a plausible variation of which EKS authentication/authorization layer rejects first, same underlying cause.)

## Decision

Instead of just raising the fixed value (the same short-term remedy already used twice in this session for `wait_for_alb`), `time_sleep.operator_access_propagation` was **replaced** with `null_resource.wait_for_operator_access` (`terraform/modules/eks/main.tf`), whose `provisioner "local-exec"` actually verifies that access works before releasing the following resources: it generates an ephemeral kubeconfig via `aws eks update-kubeconfig` (never touching the operator's default kubeconfig) and loops on `kubectl get namespace kube-system`, with a 120s budget (5s interval) and progress logging to `stderr` — the same poll-with-deadline-and-log pattern already established in `null_resource.wait_for_alb` (ADR 014) and `null_resource.cleanup_stale_metrics_apiservice` (ADR 015).

**Why poll instead of just raising the number, this time:** the two previous cases (ALB, APIService) wait for an external resource whose creation/removal is binary and observable via `describe`/`get`. This case has the same shape — "does access work or not" is a question answerable directly (`kubectl get namespace`), instead of inferring from elapsed time. There's no reason for this to be the only one of the project's three "waits" still resolved by guessing at a duration.

**Practical consequence:** `module.eks` gained `variable "aws_region"` (the script's `aws eks update-kubeconfig` needs an explicit `--region`; the `aws`/`kubernetes`/`helm` providers already get the region from provider configuration, but a CLI call inside a `local-exec` doesn't). The `hashicorp/time` provider was removed from `terraform/modules/eks/versions.tf` and `terraform/envs/lab/versions.tf` (no remaining uses left); `hashicorp/null` was added to the `eks` module (previously only declared in the root).

## Consequences

- `terraform/modules/eks/main.tf`: `time_sleep.operator_access_propagation` (fixed 30s) → `null_resource.wait_for_operator_access` (poll up to 120s, progress logging).
- `terraform/modules/eks/variables.tf`: new `variable "aws_region"`.
- `terraform/modules/eks/versions.tf`: `time` removed, `null ~> 3.2` added.
- `terraform/envs/lab/versions.tf`: `time` removed (no longer used anywhere else in the root).
- `terraform/envs/lab/eks.tf`: `module "eks"` now passes `aws_region = var.aws_region`.
- No change for consumers (`kubernetes_namespace_v1.argocd`/`.platform` still use `depends_on = [module.eks]`) — the resource's internal address changes, the ordering guarantee the root module inherits doesn't.
- Validated in this session via `terraform plan` against the real, partially applied environment (stopped exactly at this point): the plan showed exactly what was expected — 1 resource destroyed (the old `time_sleep`, out of configuration) and the remaining 14 environment resources to create, with nothing unexpected. Full functional validation (that the poll actually avoids the `Unauthorized` end to end) is left for the operator's next `apply`.
- 3rd fixed budget in the project revisited in the same session (`wait_for_alb`, `cleanup_stale_metrics_apiservice` by extension of the same pattern, now this one) — if a fourth one shows up, it's worth considering whether there's a general pattern to extract (e.g., a reusable "poll with deadline and log" module/helper), instead of continuing to duplicate the same script shape in each `null_resource`.

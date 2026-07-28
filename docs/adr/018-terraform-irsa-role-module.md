# 018 — Extracting `terraform/modules/irsa-role`

## Status

Accepted

## Context

Part of a self-directed backlog of repository improvements (audit for dead code, branch protection, CI test coverage, and — this ADR — a further modularization pass), continuing what ADR 013 started. ADR 013 already flagged the natural next candidates once `modules/vpc` and `modules/eks` existed: `iam-app.tf` and `iam-platform.tf`, not modularized at the time for lack of a second environment to justify the reuse.

The actual trigger here isn't a second environment — it's a repeated *shape*. `envs/lab` declared 6 IAM roles (the app's shared role in `iam-app.tf`, plus aws-load-balancer-controller/external-dns/cert-manager/ebs-csi-driver/grafana in `iam-platform.tf`) with a byte-identical OIDC-federated trust policy, differing only in role name, namespace, and service account name(s). Six copies of the same 15-line `jsonencode` block is exactly the kind of duplication `docs/engineering-standards.md` (section 6) already asks to avoid.

Same timing argument as ADR 013 applies again: `terraform/envs/lab`'s remote state is empty (destroyed between sessions, by design — the ephemeral infrastructure principle). Changing a resource's address inside a `module {}` block is free against empty state; there's no `terraform state mv` to get right, no live role to accidentally replace.

## Decisions

### 1. One `irsa-role` module, not one module per add-on

The module owns only the trust policy (`aws_iam_role.this` + its `assume_role_policy`), taking `role_name`, `oidc_provider_arn`, `oidc_provider_url`, `namespace`, and `service_account_names` (a list, so the app's role — shared by two service accounts — and the platform roles — one each — use the same interface). Each consumer's actual permissions (`aws_iam_role_policy` inline JSON, or `aws_iam_role_policy_attachment` for ebs-csi-driver's AWS-managed policy) stay in `envs/lab`, referencing the module's `role_id`/`role_name` output — those differ too much per consumer to be worth abstracting, and doing so would just move the interesting part of each resource behind a parameter.

### 2. The ArgoCD `Applications` block in `argocd.tf` is deliberately left alone

`argocd.tf` also has a large repeated-looking shape: 8 `Application` entries (aws-load-balancer-controller, external-dns, cert-manager, ebs-csi-driver, kube-prometheus-stack, loki, promtail, metrics-server) inside one `yamlencode(...)` blob feeding a single `helm_release.argocd_apps`. Unlike the IRSA roles, these aren't separate Terraform resources — they're map entries inside one resource's `values` argument, so there's no `module {}` boundary to draw around "one Application" without either restructuring the whole app-of-apps mechanism or building a module that just returns a map (a function-shaped module, not a resource-shaped one). More importantly, each entry carries real, non-generic differences — retry/backoff policy (cert-manager, kube-prometheus-stack, loki), `finalizers` for owned PVCs, chart-specific `helm.parameters` — each documented inline with the operational reason it exists. A generic module would either lose that documentation or grow enough parameters to stop being simpler than the flat version. Not extracted.

### 3. Same interface conventions as `modules/vpc`/`modules/eks`

Singular resource named `this` (ADR 013, decision 3); the module receives an already-fully-formed `role_name` rather than assembling one from a prefix — naming stays the caller's concern, same reasoning ADR 013 used for `modules/vpc`'s `project`/`cluster_name` inputs.

## Consequences

- No behavior change: same 6 roles, same trust policies, only their resource address changes (`aws_iam_role.grafana` → `module.grafana_irsa.aws_iam_role.this`, etc.) — `outputs.tf` and the 5 IRSA-role-ARN references inside `argocd.tf`'s Helm values were updated to read from the new module outputs.
- Unlike ADR 013 (which deferred verification to "the operator's next `apply`"), this round was verified with a real `terraform plan` against the actual (empty) S3 backend: `55 to add, 0 to change, 0 to destroy`, all 6 `module.*_irsa.aws_iam_role.this` present and no errors — the safe-timing argument was checked, not just asserted.
- Incidental cleanup: a stale, unreferenced `hashicorp/time` provider entry was dropped from `envs/lab`'s `.terraform.lock.hcl` (pre-existing drift, surfaced by a clean `terraform init`, unrelated to this refactor but bundled in the same PR since it was a 2-line diff).
- `terraform/modules/irsa-role` added to the CI matrix (`.github/workflows/ci.yml`) and to the branch protection required status checks — a new module directory needs both, same as `modules/vpc`/`modules/eks` already had.
- Natural next candidate, if it comes up again: `iam-app.tf`/`iam-platform.tf`'s remaining per-consumer policy blocks and `cloudfront.tf` are still flat in the root module (ADR 013's original list) — not extracted now, same YAGNI reasoning as before, unless a concrete second consumer shows up.

## Validation

`terraform fmt -recursive`, `terraform validate`, and `tflint` clean in `terraform/modules/irsa-role/` and `terraform/envs/lab/` (matching the CI job exactly). A real `terraform plan` against the empty S3 backend (`AWS_PROFILE=cloudlab`) confirmed the change end to end: `55 to add, 0 to change, 0 to destroy`. Merged in [PR #60](https://github.com/alisson92/minitube/pull/60).

# Phase 1 — Terraform Foundation

> Phase retrospective, written at its end. Does not repeat the content of ADRs and runbooks — links to them. Serves as input for the project's final documentation (see `CLAUDE.md`, "Repository structure" section).

## Phase goal

Build the infrastructure-as-code foundation on which all subsequent phases rest: remote state backend, an AWS account with well-defined identity and privileges, a dedicated VPC, and an EKS cluster with a spot node group — all applicable from scratch and fully destructible, with no hidden manual steps. The original completion criterion (`CLAUDE.md`): *"a complete `terraform destroy` followed by a clean `apply`, with no manual steps"*.

## What was delivered

| Deliverable | Where it lives | Persistent or ephemeral |
| --- | --- | --- |
| Remote state backend (S3 bucket + native lock) | `terraform/bootstrap/` | Persistent |
| Dedicated AWS account + operator via IAM Identity Center (SSO) | `terraform/bootstrap-iam/` | Persistent |
| EKS IAM roles (cluster/node) + OIDC provider (IRSA) | `terraform/bootstrap-iam/` + `terraform/envs/lab/eks.tf` | Persistent roles; ephemeral cluster |
| VPC (2 AZs, public/private subnets, 1 NAT Gateway) | `terraform/envs/lab/vpc.tf` | Ephemeral |
| EKS + managed spot node group (2× t3.medium) | `terraform/envs/lab/eks.tf` | Ephemeral |
| Budget alert (10 USD/month, email at 80%/100%) | `terraform/bootstrap-iam/budget.tf` | Persistent |

The persistent/ephemeral split was not an organizational detail — it was the most recurring architecture decision of the phase (see next section).

## Architecture decisions (ADRs)

Each one solved a concrete problem found during the phase, not an abstract "best practices" choice:

- **[ADR 001](../adr/001-terraform-state-backend.md) — Remote backend with S3's native lock.** Avoids depending on an additional DynamoDB table, using the native lock (`use_lockfile`) available since Terraform 1.10.
- **[ADR 002](../adr/002-aws-account-and-iam-bootstrap.md) — Dedicated AWS account and `bootstrap`/`bootstrap-iam` split.** Born from a real error: the first `apply` failed because the account inherited from a previous project had neither a traceable `lab-operator` nor `s3:CreateBucket`. Splitting into two modules (one for daily use, one admin-only) solved a second problem — `PowerUserAccess` blocks all IAM reads, so the state of IAM resources can't even be planned by the daily operator.
- **[ADR 003](../adr/003-cloudlab-operator-sso-migration.md) — Migration to IAM Identity Center.** Replaced the operator's static `aws_iam_access_key` with temporary credentials via `aws sso login`, eliminating the account's last long-lived credential.
- **[ADR 004](../adr/004-eks-iam-roles-and-access-mode.md) — Persistent EKS roles, `authentication_mode = "API"`, managed node group, OIDC provider ahead of time.** Consolidated the "IAM roles live in `bootstrap-iam`" pattern already established by ADR 002, and adopted access-entries authentication mode instead of the legacy `aws-auth` ConfigMap.
- **[ADR 005](../adr/005-budget-alert-persistence.md) — Persistent budget alert, no SNS.** Applied the same persistence reasoning from ADR 004 to a different problem: a cost alert is only useful if it survives the very destroy cycle it exists to watch over.

**The common thread across the five ADRs:** ephemeral infrastructure by default, with explicit and documented exceptions — never implicit. Whenever something needed to persist (state, identity, roles, cost alert), that was a recorded decision, not an oversight.

## How we validated it

Following the "post-apply functional validation" standard (`docs/engineering-standards.md`, section 11) — `describe-*` proves the resource exists, not that it works:

- **Network:** [`docs/runbooks/validate/validate-vpc-network.md`](../runbooks/validate/validate-vpc-network.md) — an ephemeral EC2 instance in the private subnet confirms real egress via NAT (SSM-only, no bastion).
- **EKS:** [`docs/runbooks/validate/validate-eks-cluster.md`](../runbooks/validate/validate-eks-cluster.md) — ephemeral kubeconfig, real pod scheduled and run on a spot node, logs checked.
- **Budget alert:** [`docs/runbooks/validate/validate-budget-alert.md`](../runbooks/validate/validate-budget-alert.md) — configuration confirmed via API; documents the limitation that AWS Budgets recalculates spend on its own schedule, so the actual alert firing can't be forced on demand.

## Lessons learned

- **`PowerUserAccess` blocks IAM reads, not just writes.** `iam:GetRole`, `iam:GetInstanceProfile`, and `iam:PassRole` return `AccessDenied` for the daily operator — any resource that needs to pass a role (instance profile, EKS cluster) requires a narrow inline policy, scoped by ARN, applied via an admin session.
- **CloudShell has only 1 GB of persistent `$HOME`.** Running `terraform init` across several modules in the same session without shared plugin cache exhausts disk space.
- **Static credentials in `~/.aws/credentials` take precedence over the same profile's `sso_session` in `~/.aws/config`.** A misconfigured SSO profile with a stale static entry produces a confusing `InvalidClientTokenId` instead of an obvious authentication error.
- **Manual operations outside the assisted flow deserve cross-checking.** A manual test `destroy` in `envs/lab` was only confirmed safe by comparing `terraform state list` against `aws ec2 describe-vpcs` before any destructive action.
- **AWS Budgets does not recalculate in real time.** Functional cost validation has a ceiling: you can prove the configuration is correct, not that the alert fires — the final proof only comes organically, with real account usage.

## Final state of the phase

- Completion criterion met: a complete `terraform destroy` in `envs/lab` followed by a clean `apply`, with no manual steps, repeated successfully for VPC, EKS, and (now, indirectly) the budget alert in `bootstrap-iam`.
- Infrastructure left standing between sessions, by design: state bucket, IAM Identity Center (permission set + EKS roles + smoke-test role), and the budget alert — all with no relevant recurring cost.
- `terraform/envs/lab/` (VPC + EKS) destroyed at the end of every test session.
- PRs: [#5](https://github.com/alisson92/minitube/pull/5) (VPC), [#7](https://github.com/alisson92/minitube/pull/7) (EKS), [#8](https://github.com/alisson92/minitube/pull/8) (budget alert).

## Next phase

[Phase 2 — Application](../../CLAUDE.md#fases-do-projeto): minimal API + transcoding job (FFmpeg → HLS → S3), completion criterion: a test video transcoded with readable segments in S3.

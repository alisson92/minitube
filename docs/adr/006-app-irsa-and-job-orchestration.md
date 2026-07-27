# 006 — App IRSA, Job orchestration, and image registry

## Status

Accepted

## Context

Phase 2 introduces the project's first real workload: an API (FastAPI) that receives video uploads and triggers transcoding (FFmpeg → HLS) as a Job on the ephemeral EKS. This raises three new decisions: how the app securely accesses S3 (IRSA), how transcoding is orchestrated, and where container images live — none covered by ADRs 001–005.

## Decisions

### 1. The app's IRSA role lives in `terraform/envs/lab/`, not in `terraform/bootstrap-iam/`

An IRSA role's trust policy references the ARN and URL of the cluster's OIDC provider (`aws_iam_openid_connect_provider.lab`, created in `envs/lab/eks.tf` since Phase 1/ADR 004). This provider is recreated every session along with the cluster — so any role trusting it would also need to be recreated/updated every session. Placing the role in `bootstrap-iam` (the pattern used for the cluster/node roles in ADR 004) would require reopening CloudShell every time the cluster is recreated, just to update a trust policy — the same operational friction already discarded by ADR 002.

The role (`minitube-app-irsa-role`) therefore lives in `envs/lab`, alongside the OIDC provider, within the same `apply`/`destroy` cycle. This requires a one-time grant — done once, via CloudShell — to the daily operator's permission set: a new `Statement` (`ManageAppIrsaRoles`) in the existing inline policy (`operator_pass_roles`, `terraform/bootstrap-iam/main.tf`), granting `iam:CreateRole`/`DeleteRole`/`PutRolePolicy`/`DeleteRolePolicy`/`GetRole`/`GetRolePolicy`/`ListRolePolicies`/`ListAttachedRolePolicies`/`TagRole`/`UntagRole`, **scoped by name prefix** (`arn:aws:iam::<account>:role/minitube-app-*`), not by a specific ARN (the role doesn't exist yet at the time the permission is granted). After this one-time grant, the full `envs/lab` cycle — including the IRSA role — becomes 100% operable by the operator via SSO, without CloudShell.

`iam:ListAttachedRolePolicies` was only discovered as necessary in a second real test: an `aws_iam_role` *refresh* always checks attached managed policies, even when only an inline one exists (as here) — the same class of gap as item 5 (OIDC provider), just on the app's own role.

A third round, this time on `terraform destroy`: `iam:ListInstanceProfilesForRole` also had to be added — the AWS provider checks attached instance profiles before deleting the role, even though this role never had one. Same class of gap (a provider check that isn't obvious from the resource's `assume_role_policy`/`aws_iam_role_policy`), just exposed in the destroy cycle instead of the plan.

### 2. A single IRSA role shared by API and transcoder

The API only writes to `raw/`; the transcoder reads `raw/` and writes to `hls/` — same bucket, same kind of policy. Two nearly identical roles wouldn't bring any real additional isolation at this stage. The trust policy accepts both service accounts (`system:serviceaccount:minitube-app:api` and `:transcoder`) via `StringLike` in the `sub` condition.

### 3. Orchestration via a dynamic Kubernetes Job, created by the API

The API creates a `batch/v1 Job` per received video (Python `kubernetes` client, in-cluster config), instead of a queue worker (SQS, RabbitMQ) consuming continuously. For "one test video transcoded" — this phase's completion criterion — a Job per upload is the simplest orchestration that solves the problem. Queue/worker is left for when the project needs robust retry and real parallelism under load (Phase 6).

### 4. ECR repositories live in `terraform/bootstrap/`, not `bootstrap-iam`

ECR is not blocked by `PowerUserAccess` — only IAM/Organizations are. The two repositories (`minitube-api`, `minitube-transcoder`) are applicable by the daily operator via SSO, without CloudShell, and persist between sessions (rebuilding images every test would be wasteful). `image_tag_mutability = "IMMUTABLE"` reinforces the project's convention of never using `latest`.

### 5. Additional grant: reading/managing the OIDC provider by the operator

Discovered in real testing, not anticipated in the original design: `aws_iam_openid_connect_provider.lab` has existed in `envs/lab` since Phase 1, but every `plan`/`apply` that touched it up to that point ran via CloudShell/root (including EKS validation). The first time the daily operator ran `terraform plan` in `envs/lab` against a state where this resource **already existed**, the *refresh* failed with `AccessDenied` on `iam:GetOpenIDConnectProvider` — an action never granted. `terraform plan` always refreshes every resource already present in the state before computing the diff, not just the ones changing; for an IAM resource, that requires an explicit read permission, not covered by item 1's grant (which only covers `iam:*Role*`, not `iam:*OpenIDConnectProvider*`).

Fixed with a new `Statement` (`ManageEksOidcProvider`) in the same inline policy, covering `Create`/`Delete`/`Get`/`Tag`/`Untag`/`ListTags` for `OpenIDConnectProvider`. Since the provider's ARN embeds a cluster ID assigned by AWS (not predictable by name, unlike the app's role), the scope uses a `Resource` based on account/region/service pattern (`oidc-provider/oidc.eks.<region>.amazonaws.com/id/*`), not an exact ARN.

### 6. Explicit access entry so the operator has kubectl access to the cluster

Another discovery in real testing: `bootstrap_cluster_creator_admin_permissions = true` (ADR 004) only grants admin to whoever actually called `CreateCluster` — which, in Phase 1, was the CloudShell/root session, not `cloudlab-operator`. When trying `kubectl apply` locally for the first time, the operator couldn't even authenticate to the cluster (the server-side error message was generic, "the server has asked for the client to provide credentials" — a symptom of the identity not being recognized as a valid principal, not an RBAC error).

Fixed with an explicit `aws_eks_access_entry` + `aws_eks_access_policy_association` (`AmazonEKSClusterAdminPolicy`, `cluster` scope) in `envs/lab/eks.tf`, pointing to `var.operator_role_arn`. Since `eks:CreateAccessEntry`/`AssociateAccessPolicy` are not IAM actions, `PowerUserAccess` already allows this for the daily operator — without CloudShell.

The first attempt resolved this ARN dynamically via `data "aws_iam_session_context"` (from `data.aws_caller_identity.current.arn`, which is the ARN of an assumed session, with a session-name suffix that doesn't match the role's own ARN). This approach failed: the data source itself calls `iam:GetRole` on the SSO-managed role (`AWSReservedSSO_cloudlab-operator_...`) — an IAM read outside the already-granted `minitube-app-*` prefix, and a resource this project doesn't even manage via Terraform. Chasing yet another one-off permission for this specific case wasn't worth it. Instead, `var.operator_role_arn` holds the fixed ARN (obtained once via `aws iam get-role`, CloudShell/root, read-only) — the same pattern already used for `operator_sso_username` in `bootstrap-iam`. Requires no new IAM grant; it only changes if the permission set is recreated (a rare event, already documented as an exception in the runbook).

### 7. Manual `kubectl apply -k gitops/app/` in this phase

The manifests already live in `gitops/app/` (Kustomize), ready for ArgoCD to take over in Phase 3, but are applied manually for now — the same temporary exception already used for the VPC/EKS smoke tests in Phase 1. No `kubectl apply` will remain manual beyond Phase 3.

### Alternatives considered

- **IRSA role in `bootstrap-iam` + `terraform_remote_state`:** discarded — the trust policy would be tied to the OIDC provider's ARN, which changes every time the cluster is recreated; would require CloudShell every test session.
- **Reuse the node group's role (`eks_node`) for S3 access, without IRSA:** discarded — every pod on the node would inherit access to the video bucket, violating the least-privilege principle already recommended in `docs/engineering-standards.md` §8. It would be simpler now, but Phase 4 will already bring other add-ons (aws-load-balancer-controller, external-dns, cert-manager) that need their own IRSA roles — better to establish the correct pattern already on the first workload.
- **Message queue (SQS) right away:** discarded on scope — YAGNI until Phase 6, when load tests actually stress orchestration of multiple simultaneous videos.

## Consequences

- `terraform/bootstrap-iam/main.tf` gains the `ManageAppIrsaRoles` and `ManageEksOidcProvider` `Statement`s — any future role with the `minitube-app-*` prefix, and the cluster's own OIDC provider, can be managed by `envs/lab` without touching `bootstrap-iam` again. This second grant closes a gap that had existed since Phase 1 (the OIDC provider had only been tested via CloudShell) and was only exposed when running `envs/lab` for the first time with the daily operator's profile after the resource already existed in the state.
- `terraform/envs/lab/eks.tf` gains `aws_eks_access_entry.operator` + `aws_eks_access_policy_association.operator_admin` — `kubectl` access to the cluster no longer depends on who originally created it.
- `terraform/envs/lab/` gains `s3.tf` (video bucket) and `iam-app.tf` (IRSA role + policy), and destroys both along with everything else on every `terraform destroy` — no app infrastructure remains standing outside the ephemeral cycle.
- `terraform/bootstrap/` gains `ecr.tf` — the two repositories and the images in them persist between sessions.
- Post-apply functional validation gains `terraform/envs/lab/scripts/validate-transcoding.sh` and the runbook [`docs/runbooks/validate/validate-transcoding.md`](../runbooks/validate/validate-transcoding.md).
- `kubectl apply -k gitops/app/` is a temporary exception to the GitOps principle (`docs/engineering-standards.md` §5) — it should stop being necessary as soon as ArgoCD is installed in Phase 3.

> **Update (Phase 3):** the manual `kubectl apply -k gitops/app/` from this item is no longer necessary — ArgoCD takes over full reconciliation of `gitops/app/` starting this phase. Decision recorded in [ADR 007](007-argocd-gitops-bootstrap.md).

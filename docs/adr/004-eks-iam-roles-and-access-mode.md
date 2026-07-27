# 004 — EKS IAM roles, authentication mode, and managed node group

## Status

Accepted

## Context

The next deliverable of Phase 1 is EKS with a spot node group in `terraform/envs/lab/`, reusing the already-validated VPC. This raises architecture decisions about where the cluster/node IAM roles live, how to grant access to the daily operator, and what type of node group to use.

## Decisions

### 1. Cluster and node roles live in `terraform/bootstrap-iam/`, not in `terraform/envs/lab/`

Same reason as ADRs 002/003: the `cloudlab-operator`'s `PowerUserAccess` policy excludes **all** IAM actions, including reads (`iam:GetRole`, `iam:GetInstanceProfile`). The `minitube-eks-cluster-role` and `minitube-eks-node-role` roles can only be created via a root/CloudShell session. `terraform/envs/lab/` references them by name via `data "aws_iam_role"`, after the permission set's inline policy grants `iam:GetRole`/`iam:PassRole` scoped to these two ARNs — the same pattern already used for the network smoke test's instance profile.

Practical consequence: a full `destroy`/`apply` of `envs/lab` (Phase 1 completion criterion) never needs to reapply `bootstrap-iam` — the roles persist outside the environment's ephemeral cycle.

### 2. A single inline policy, edited rather than duplicated

The IAM Identity Center API accepts **at most one** inline policy per permission set. The resource that already existed (`operator_pass_smoke_test_role`, granting `iam:PassRole`/`iam:GetInstanceProfile` only for the network smoke test role) was renamed to `operator_pass_roles` and now has two `Statement`s (`Sid`s `PassSmokeTestRole` and `PassEksRoles`). Any future need for `PassRole` on a new role (e.g., IRSA for some add-on) must follow the same pattern: add a `Statement` to this same resource, never create a second `aws_ssoadmin_permission_set_inline_policy`.

### 3. `authentication_mode = "API"` instead of `CONFIG_MAP`

The cluster uses **access entries** (`API` mode) with `bootstrap_cluster_creator_admin_permissions = true`, instead of the legacy `aws-auth` ConfigMap. This is the mode currently recommended by AWS for new clusters, eliminates the need to manually edit a ConfigMap to grant access, and the operator applying the Terraform automatically gets admin permissions on the cluster.

### 4. Managed node group (`aws_eks_node_group`), not self-managed

A managed node group covers the Auto Scaling Group, optimized AMI selection, and node draining on updates, without requiring reimplementing this in pure Terraform. For a learning project, understanding EKS doesn't require rebuilding what the managed node group already solves — the "how it works underneath" learning is left for when it makes sense (e.g., when investigating spot interruption handling).

### 5. `aws_iam_openid_connect_provider` (IRSA) already created in this phase

The OIDC provider is a single, cheap, idempotent resource per cluster. Creating it now avoids a retrofit coupled to the VPC/cluster when the first add-on that needs IRSA is implemented (Phase 4: aws-load-balancer-controller/external-dns/cert-manager; Phase 6: cluster-autoscaler or Karpenter). No specific IRSA IAM role is created now — each add-on creates its own role only when implemented (YAGNI applied to the role, not the provider).

### Alternatives considered

- **EKS roles in `envs/lab`:** discarded for the same reason as ADR 002 — `PowerUserAccess` blocks all IAM actions for the daily operator.
- **Second separate inline policy:** technically impossible — the Identity Center API rejects more than one inline policy per permission set.
- **`authentication_mode = "CONFIG_MAP"`:** discarded — depends on the legacy `aws-auth` ConfigMap, which AWS itself is phasing out as the recommended path.
- **Self-managed node group (own ASG + launch template):** discarded for this phase — more code to maintain without proportional learning gain; can be revisited in a future ADR if the project needs finer control over node lifecycle.
- **Postpone the OIDC provider to Phase 4:** discarded — the cost of creating it now is negligible, and postponing it would mean touching the EKS module again just to add a resource that doesn't depend on any still-open decision.

## Consequences

- `terraform/bootstrap-iam/main.tf` grows with two roles and a unified inline policy — any future new `PassRole` edits this same resource.
- `terraform/envs/lab/` gains `eks.tf`, new variables (`eks_cluster_version`, `eks_node_instance_types`, `eks_node_desired_size`/`min_size`/`max_size`), and new outputs (`eks_cluster_name`, `eks_cluster_endpoint`, `eks_cluster_certificate_authority_data`, `eks_oidc_provider_arn`).
- Post-apply functional validation (section 11 of `engineering-standards.md`) gains `scripts/validate-eks.sh` and the runbook [`docs/runbooks/validate/validate-eks-cluster.md`](../runbooks/validate/validate-eks-cluster.md).
- The cluster's public endpoint (`endpoint_public_access = true`) is enabled for simplicity of kubectl access in the lab; if the project needs to restrict this (e.g., via `public_access_cidrs`), that change deserves its own ADR once the Phase 4/5 network context is clearer.

> **Update (Phase 2):** the assumption that "the operator applying the Terraform automatically gets admin permissions" (`bootstrap_cluster_creator_admin_permissions`) only holds for whoever *created* the cluster — in practice, that was CloudShell/root in Phase 1, not `cloudlab-operator`. Since the project's goal is for the daily operator to use `envs/lab` without depending on CloudShell, this required an explicit `aws_eks_access_entry`. Decision recorded in [ADR 006](006-app-irsa-and-job-orchestration.md).

> **Update (Phase 5):** `bootstrap_cluster_creator_admin_permissions = true` was reverted to `false`. The automatic access entry that this flag creates for whoever calls `CreateCluster` collides (`409 ResourceInUseException`) with the explicit `aws_eks_access_entry` whenever the two point to the same principal — which started happening whenever `cloudlab-operator` itself (not CloudShell/root) ran the `apply`. Instead of continuing to work around this on a per-session basis (as in ADR 007, item 11), cluster access became 100% declared by Terraform, independent of who applies it. Decision recorded in [ADR 009](009-eks-access-entries-and-api-edge-routing.md).

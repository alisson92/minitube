# 013 — Extracting `terraform/modules/vpc` and `terraform/modules/eks`

## Status

Accepted

## Context

With the phase roadmap closed out (Phase 6), this session reviewed the repository's organization against `docs/engineering-standards.md` and market practices, before making the repository public for portfolio purposes. One finding: `terraform/envs/lab/` had always been a single monolithic root module — `vpc.tf` and `eks.tf` declare resources directly, with no `module {}` block anywhere in the repository, despite the author preparing for the Terraform Associate certification (`CLAUDE.md`, "Learning objectives"), which directly tests this pattern, and `docs/engineering-standards.md` (section 6) already recommending "small, cohesive modules."

The timing is deliberate, not incidental: `terraform/envs/lab/` is destroyed (the ephemeral infrastructure principle, always honored between sessions) — there's no real state to migrate. Refactoring resources into a `module {}` changes each resource's *resource address* (`aws_vpc.lab` becomes `module.vpc.aws_vpc.this`, for example); against a live environment this would require a careful `terraform state mv` to avoid needlessly recreating everything. Against an already-destroyed environment, the next `apply` simply creates the resources at the new addresses — no risk, no state migration, no downtime to avoid. There's hardly a cheaper moment to make this change than now.

## Decisions

### 1. Two modules, not a single generic `infra`

`terraform/modules/vpc/` (VPC, subnets, IGW, NAT Gateway, route tables) and `terraform/modules/eks/` (cluster, spot node group, OIDC provider for IRSA, operator access entry) — extracted from `vpc.tf` and `eks.tf` respectively, keeping the same domain-based split the repository already used for files. These are the two most foundational infrastructure blocks, and the closest to "generic enough to reuse" (any EKS project needs a VPC and a cluster in this shape); app/platform IRSA roles (`iam-app.tf`, `iam-platform.tf`) and the ArgoCD bootstrap (`argocd.tf`) remain in the root module — they're specific to this project, with no added didactic value in becoming a module now (YAGNI).

### 2. Custom modules, not the Registry (`terraform-aws-modules/vpc`, `terraform-aws-modules/eks`)

`CLAUDE.md` already records the project's general preference: "prefer writing custom modules over copying ready-made ones when the goal is didactic" (principle 5). The Registry modules are the right choice for productivity in real production, but they hide exactly the mechanics (subnet tags for LBC auto-discovery, the single NAT Gateway as a cost decision, `authentication_mode = "API"` vs. the legacy ConfigMap) that this project exists to practice from the ground up.

### 3. Naming convention: `this` for each module's singular resource

Follows the common convention in community Terraform modules (`aws_vpc.this`, `aws_eks_cluster.this`) instead of the previous `.lab` (an environment name, which makes no sense inside a module reusable across multiple environments). The node group kept `spot` (`aws_eks_node_group.spot`) since it was already self-descriptive.

### 4. `time_sleep.operator_access_propagation` moved inside `module.eks`

This resource (ADR 009, decision 2 — waits for the access entry to propagate in the EKS *authorizer*) only depended on resources that now live inside `module.eks` (`aws_eks_access_entry.operator`, `aws_eks_access_policy_association.operator_admin`) and was only consumed, via `depends_on`, by Kubernetes/Helm resources in the root module. Moving it inside the module eliminates an unnecessary cross-dependency: the root module now only needs `depends_on = [module.eks]` to inherit the wait, without knowing it exists internally.

### 5. Root-module `depends_on` simplified to module level

The repository's most critical `depends_on` (`helm_release.argocd_apps`, `platform` Application, see ADR 010 decision 4) manually enumerated the 6 network resources that guarantee egress survives until the LBC finishes cleaning up the shared ALB on `destroy`. With these 6 resources now inside `module.vpc`, `depends_on = [module.vpc]` expresses exactly the same guarantee (Terraform treats a dependency on a module as a dependency on all its resources) — and, unlike the manual list, it stays correct automatically if the module gains more network resources in the future. The same simplification was applied to the two other `depends_on`s that pointed at specific EKS resources (`helm_release.argocd` waiting for the node group; `kubernetes_namespace_v1.argocd` waiting for the access entry) — both became `depends_on = [module.eks]`.

### 6. The `eks` module's outputs now deliver a ready-made `oidc_provider_url`

Previously, `local.oidc_provider_url = replace(aws_iam_openid_connect_provider.lab.url, "https://", "")` lived duplicated as logic in the root module (`iam-app.tf`), consumed by `iam-app.tf` and `iam-platform.tf`. Since the module already exposes the ARN (`oidc_provider_arn`) for IRSA trust policies, it makes sense to also expose the already-processed URL (`oidc_provider_url`) as an output — a single source of truth for that transformation, inside the module that owns the resource.

## Consequences

- No behavior change: the same resources, with the same arguments, in the same places on AWS — only the *resource address* in the state changes.
- `docs/runbooks/validate/validate-argocd-gitops.md` (the only place that referenced individual resource addresses in a real command, not in historical prose) needed to update its `-target` fallback in two steps: the 3 `-target=aws_eks_cluster.lab`/`aws_eks_node_group.lab_spot`/`aws_iam_openid_connect_provider.lab` became a single `-target=module.eks`.
- Previous ADRs (004, 007, 008, 009, 010, 011) that mention `aws_vpc.lab`, `aws_eks_cluster.lab`, etc. **were not rewritten** — they are historical records of decisions made against the code as it existed at that moment; changing them now would mix the original decision with a later refactor. This ADR is the pointer to "where these resources lived afterward."
- Natural next candidate, if the project grows to multiple real environments (today only `lab` exists): the other files in `envs/lab/` (`iam-app.tf`, `iam-platform.tf`, `cloudfront.tf`) getting their own modules — not done now since there's no second environment to justify the reuse.

## Validation

`terraform fmt -recursive` and `terraform validate` clean in `terraform/envs/lab/` and in each module in isolation (`terraform/modules/vpc/`, `terraform/modules/eks/`). No active AWS session for this review (infrastructure destroyed by design), so a real `terraform plan` is left for the operator's next `apply` — which should show the net creation of the same resources as always, now under the new `module.vpc.*`/`module.eks.*` addresses, with nothing beyond that.

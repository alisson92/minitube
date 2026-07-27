# Phase 3 — GitOps

> Phase retrospective, written at its end. Does not repeat the content of ADRs and runbooks — links to them. Serves as input for the project's final documentation (see `CLAUDE.md`, "Repository structure" section).

## Phase goal

Install ArgoCD and have it take over reconciliation of `gitops/app/` (and prepare `gitops/platform/` for Phase 5), closing the temporary manual `kubectl apply -k` exception opened in Phase 2. Completion criterion (`CLAUDE.md`): *"No manual `kubectl apply` — every deploy comes from Git."*

## What was delivered

| Deliverable | Where it lives | Persistent or ephemeral |
| --- | --- | --- |
| ArgoCD (`argo-cd` chart) | `terraform/envs/lab/argocd.tf` + `values/argocd.yaml` | Ephemeral — installed on every `terraform apply` of `envs/lab` |
| Declarative bootstrap of root Applications (`argocd-apps` chart) | `terraform/envs/lab/argocd.tf` | Ephemeral |
| `AppProject minitube-platform` | `terraform/envs/lab/argocd.tf` (via `argocd-apps`) | Ephemeral |
| Git credential (SSH deploy key) | `kubernetes_secret_v1.argocd_repo_credentials` | Ephemeral — key generated outside the repo, registered as a Deploy Key on GitHub |
| `gitops/app/` reconciled by ArgoCD (no longer `kubectl apply -k`) | `gitops/app/` | — |
| `gitops/platform/` (placeholder for Phase 5) | `gitops/platform/README.md` | — |
| 2 new IAM grants for the operator (`PassEksRoles` +1 action, new `ReadEksServiceLinkedRoles`) | `terraform/bootstrap-iam/main.tf` | Persistent |

## Architecture decisions (ADRs)

- **[ADR 007](../adr/007-argocd-gitops-bootstrap.md)** — the phase's central decision. Covers: installing ArgoCD via Terraform's `helm_release` (not a manual `helm install`); bootstrapping the root Applications via the `argocd-apps` chart (no `kubectl apply` for that either); `gitops/platform/` created now as a placeholder, with the `AppProject` declared via Terraform to avoid a chicken-and-egg problem; a read-only SSH deploy key for the private repository; Dex/notifications disabled (YAGNI); UI access only via port-forward in this phase; ArgoCD self-management (app-in-app) evaluated and deferred; and the real bugs described below.
- **[ADR 006](../adr/006-app-irsa-and-job-orchestration.md)** got an update note (item 7): the manual `kubectl apply -k gitops/app/` is no longer needed as of this phase.

## Real bugs found and fixed

As in previous phases, none of these showed up before a real `terraform apply`/validation against AWS:

1. **Duplicate access entry.** Since `cloudlab-operator` (not CloudShell/root, unlike Phases 1–2) called `CreateCluster` in this session, `bootstrap_cluster_creator_admin_permissions=true` (ADR 004) automatically created an access entry + `AmazonEKSClusterAdminPolicy` for that principal — conflicting with the explicit `aws_eks_access_entry.operator` that Terraform tried to create on top of it (`ResourceInUseException`). Resolved with a `terraform import` of the already-existing resource into state, with no manual `aws eks` command outside Terraform.
2. **Missing `iam:ListAttachedRolePolicies` for `CreateNodegroup`.** The AWS provider validates the managed policies already attached to the node role before creating the node group — an action not covered by the original `PassEksRoles` `Statement` (which only had `GetRole`/`PassRole`). Fixed by adding the action to the same `Statement`, applied via CloudShell/root in `terraform/bootstrap-iam/`.
3. **Missing `iam:GetRole` on EKS service-linked roles.** Even after fixing bug 2, `CreateNodegroup` failed again: it also confirms that `AWSServiceRoleForAmazonEKSNodegroup` already exists via a direct `iam:GetRole` on that ARN — not covered by any existing `Statement` (which only covered cluster/node roles, not SLRs). Fixed with a new `Statement`, `ReadEksServiceLinkedRoles`, scoped to the two EKS SLRs.
4. **`global.additionalLabels` overwriting ArgoCD's own internal `part-of`.** The most expensive bug of the phase to diagnose: `values/argocd.yaml` set `global.additionalLabels: {app.kubernetes.io/part-of: minitube}` as a grouping label, but that same key is already used by the chart (`part-of: argocd`) and read by `argocd-server`/`argocd-application-controller` themselves to locate their own configuration via an informer with a label selector. Since Helm overwrites (not merges) label values on the same key, the value became `minitube`, and those two components entered a permanent `CrashLoopBackOff` with `configmap "argocd-cm" not found` — even though the ConfigMap existed, with the right name, in the right namespace, with correct RBAC (methodically confirmed via `kubectl auth can-i` before suspecting the label). `redis`, `repo-server`, and `applicationset-controller` stayed healthy, which helped isolate the cause to the two components that depend on that informer. Fixed by removing `global.additionalLabels` — the "part-of: minitube" grouping already exists on the Namespace, with no collision.
5. **`targetRevision` pinned to `main` preventing validation of the branch itself.** The `platform` Application pointed to `targetRevision: main`, but `gitops/platform/` only existed on the `feat/argocd-bootstrap` branch (not yet merged) — `path does not exist`. Fixed by parameterizing the revision (`var.argocd_gitops_revision`, default `main`), allowing the current branch to be validated via `-var` with no hardcoding and no need for a premature merge just to test.
6. **Destroy order revoking the operator's own access mid-process.** In the final `terraform destroy`, `aws_eks_access_entry.operator`/`aws_eks_access_policy_association.operator_admin` were removed before the ArgoCD namespace/secret (no explicit dependency between them), dropping the operator's `kubectl` access to the cluster partway through — the reported error (`cannot delete resource "secrets"`) was actually "your identity no longer has any binding on this cluster". Fixed with an explicit `depends_on` on `kubernetes_namespace_v1.argocd`, ensuring the correct reverse order on destroy. Recovered in this session via `terraform state rm` on the two orphaned Kubernetes resources (the whole cluster would be destroyed next anyway) + a normal `terraform destroy` for the rest.

## How we validated it

[`docs/runbooks/validate/validate-argocd-gitops.md`](../runbooks/validate/validate-argocd-gitops.md) + `terraform/envs/lab/scripts/validate-argocd.sh`: confirms ArgoCD components are `Available`, both root Applications are `Synced`/`Healthy`, that `Deployment/api` carries the ArgoCD tracking annotation (proof it didn't come from a manual `kubectl apply`), that the API responds via port-forward, and — the central check — that manual drift (`kubectl scale --replicas=2`) is reverted by `selfHeal` on its own, with no intervention. All checks passed, with drift reverted in ~5s. We also reran `validate-transcoding.sh`, confirming that the app, now 100% synced via GitOps, still transcodes a real video end to end.

## Lessons learned

- **Global Helm chart labels can collide with labels the chart itself uses internally.** `global.additionalLabels`/equivalent values overwrite rather than merge — always check whether the chosen key is already used by the chart before applying it globally, especially in complex charts like `argo-cd` that use label selectors at runtime, not just for visual organization.
- **`terraform import` resolves "external drift" without leaving the IaC flow.** Both the access entry auto-created by AWS and (during one troubleshooting moment) an orphaned Helm release from an interrupted `apply` were recovered via `terraform import`, avoiding any manual `aws`/`helm` command outside Terraform — keeps the "everything is code" principle even when dealing with side effects from AWS/Helm themselves.
- **Testing an ArgoCD Application before merge requires pointing at the branch.** A `targetRevision` pinned to `main` is correct for production, but creates a circular dependency when validating new infrastructure on a branch — parameterizing that revision (safe default, one-off override) solves it without giving up real functional validation before merge.

## Final state of the phase

- Completion criterion met: no manual `kubectl apply` — `gitops/app/` and `gitops/platform/` are reconciled by ArgoCD from Git, confirmed by a real functional test (including proof of self-heal).
- `terraform/bootstrap-iam/` gained 2 new IAM grants (persistent, no cost); `terraform/envs/lab/` (VPC, EKS, S3, IRSA, ArgoCD) confirmed destroyed at the end of the session.
- Repository visibility: briefly made public in this session (for `git pull` convenience in CloudShell) and reverted to **private** within the same session — the project stays private throughout development and is deliberately made public at the end, for portfolio/LinkedIn purposes. See ADR 007.
- PR for this phase: branch `feat/argocd-bootstrap` *(update the PR link once opened)*.

## Next phase

[Phase 4 — Edge, DNS and TLS](../../CLAUDE.md#fases-do-projeto): CloudFront in front of S3; Route 53 + external-dns + cert-manager with the operator's own domain — completion criterion: `app.<domain>` serving video via CDN with valid HTTPS, plus an ADR on the persistence of the DNS zone between sessions.

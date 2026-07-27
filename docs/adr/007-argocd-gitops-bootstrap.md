# 007 — ArgoCD bootstrap and GitOps synchronization

## Status

Accepted

## Context

Phase 3 completion criterion (`CLAUDE.md`): "No manual `kubectl apply` — every deploy comes from Git". ADR 006 (item 7) had already recorded this gap as a temporary exception: `gitops/app/` was applied manually via `kubectl apply -k`, with the explicit promise that "no `kubectl apply` will remain manual beyond Phase 3". This phase installs ArgoCD and has it take over full reconciliation of `gitops/app/`, while also preparing `gitops/platform/` (nonexistent until now) for Phase 5's observability components.

The GitHub repository (`alisson92/minitube`) is **private** — ArgoCD, running inside the cluster, needs its own credential to clone the Git repo; it doesn't inherit the operator's local SSH key.

## Decisions

### 1. ArgoCD installed via Terraform's `helm_release`, not manual `helm install`

The official `argo-cd` chart (`argo-helm` repository) is installed as a `helm_release` in `terraform/envs/lab/argocd.tf`, with the `kubernetes`/`helm` providers authenticated from `aws_eks_cluster.lab`'s own attributes (via `data "aws_eks_cluster_auth"`) — without writing a kubeconfig to disk. Since `envs/lab`'s infrastructure is destroyed and recreated every session (the project's ephemerality principle), any imperative step (`helm install`) would need to be remembered and manually rerun every session — the same kind of operational friction already discarded in earlier decisions (ADR 002). A single `terraform apply` now recreates VPC, EKS, S3, IRSA, **and** ArgoCD.

### 2. Bootstrap of root Applications via the `argocd-apps` chart, not a manually applied Application YAML

The `argocd-apps` chart (same `argo-helm` repository) allows declaring `Application`/`AppProject`/`ApplicationSet` via Helm values. Used as a second `helm_release` to create two root Applications — `app` (points to `gitops/app`, destination `minitube-app`) and `platform` (points to `gitops/platform`, destination `minitube-platform`) — and the `AppProject minitube-platform`. This closes the very act of "giving the first `kubectl apply` for ArgoCD to exist": even the creation of the Applications remains 100% declarative and reproducible via `terraform apply`, instead of reopening the exception this phase is meant to close.

### 3. `gitops/platform/` created now with only a `README.md`; `AppProject` declared via Terraform, not inside the Git directory

The directory is created in this phase (with the `platform` Application already pointing to it) even without real content yet — Phase 5 (kube-prometheus-stack/Loki) will only need to add manifests to a Git path that already exists and is already being synchronized, without touching Terraform again. The `AppProject minitube-platform` is declared via Terraform (`argocd-apps` chart), not as a manifest inside `gitops/platform/`: putting it there would create a chicken-and-egg problem — the very Application that syncs that directory needs to reference a `project` that, if it only lived in Git, wouldn't exist yet on the first sync.

### 4. Dedicated read-only SSH deploy key

Evaluated with the project operator: read-only SSH deploy key (chosen) vs. Personal Access Token vs. making the repository public. The deploy key was chosen for having the narrowest possible scope — read-only, restricted to this single repository, without touching any other resource in the operator's GitHub account. The public key is registered on GitHub via `gh repo deploy-key add`; the private one is passed only via `TF_VAR_argocd_repo_ssh_private_key` (a `sensitive = true` variable, no default) and becomes a `kubernetes_secret_v1` in the repository-credential format ArgoCD expects (label `argocd.argoproj.io/secret-type: repository`) — never committed, the same pattern for secrets via local environment variable already used in the project (`docs/engineering-standards.md` §8).

> **Update (Phase 4, ADR 008):** this way of passing the key (`TF_VAR` with no persistence) required generating a new key pair and re-registering the deploy key every session that recreated `envs/lab` — real friction, discovered in practice, contrary to the principle that recreating the environment from scratch should be painless. Starting in Phase 4, the private key persists in `aws_ssm_parameter` (`terraform/bootstrap/ssm.tf`), read via a `data source` instead of `TF_VAR` on every apply. The choice of the deploy key itself (vs. PAT/public repo) remains valid — only the value-persistence mechanism changed. See [ADR 008](008-cloudfront-dns-tls.md), decision 10.

### 5. Dex and the notifications-controller disabled

`dex.enabled=false` and `notifications.enabled=false` in the `argo-cd` chart's values (`terraform/envs/lab/values/argocd.yaml`). There's no SSO or notification channel (Slack/email/webhook) configured yet — keeping these components active would cost resources (CPU/memory on the small node group, already hosting API+transcoder) with no real use. YAGNI, revisitable when the project actually needs one of these.

### 6. Access to the ArgoCD UI only via `kubectl port-forward` in this phase

No Ingress/DNS/TLS yet — that's a Phase 4 deliverable (`app.<domain>`, `argocd.<domain>` via Route 53 + external-dns + cert-manager). `server.service.type` stays `ClusterIP` (already the chart's default).

### 7. ArgoCD self-management (app-of-apps pattern) postponed

Evaluated and discarded for now. `envs/lab`'s infrastructure is destroyed and recreated every session — so ArgoCD will always need a bootstrap external to Git at the start of each session (the `helm_release.argocd` itself), regardless of whether it self-manages afterward. Implementing self-management now would duplicate the `argo-cd` chart's definition in two places (the initial Terraform `helm_release` and a future Application that would take over management) — two sources of truth for the same values, real risk of drift between them, with no practical gain at this stage: there are no multiple operators today changing ArgoCD's own configuration, nor a need to audit those changes via PR. Recorded as a future candidate in `gitops/platform/README.md`, to be reconsidered only if ArgoCD becomes persistent infrastructure between sessions (which would contradict the already-validated ephemerality principle) or if the project gains multiple operators.

### 8. Execution order in `terraform apply`

The `kubernetes`/`helm` providers reference attributes of `aws_eks_cluster.lab` from the same state (`endpoint`, `certificate_authority[0].data`) — not a separate module/state — so a single `terraform apply` works in the common case, with Terraform ordering cluster → node group → `kubernetes`/`helm` resources automatically via implicit dependency. Known caveat from the Terraform+EKS+Helm community: the first time a **completely new** cluster is born in the same run where a `helm_release` is also applied, the `helm`/`kubernetes` provider can fail with a connection error (`connection refused`/timeout) if it tries to authenticate before the control plane is fully ready to serve requests. Since this project recreates the cluster from scratch every session, this is the common scenario, not the exception — documented in the runbook as a fallback with `-target` in two steps (cluster+node group+OIDC provider first, the rest afterward), instead of trying to "solve" this in HCL.

**Real bug, discovered on `destroy`:** the reverse order of creation also matters and isn't automatic. `kubernetes_namespace_v1.argocd` didn't reference `aws_eks_access_entry.operator`/`aws_eks_access_policy_association.operator_admin` in any way, so Terraform had no way of knowing that destroying these two needs to happen **after** the Kubernetes resources — in a real `destroy`, the access entry was removed before ArgoCD's namespace/secret, revoking the operator's `kubectl` access mid-process (`cannot delete resource "secrets"`, an RBAC-looking error that in reality is "your identity no longer has any binding on this cluster"). Fixed with an explicit `depends_on` in `kubernetes_namespace_v1.argocd` pointing to both access resources — this orders creation (access context first, harmless) and, more importantly, forces destruction of the Kubernetes resources before revoking access. Recovery for this specific session: `terraform state rm` on the two orphaned Kubernetes resources (the whole cluster would be destroyed right after anyway, so there was no point chasing `kubectl` access just to delete them individually) followed by a normal `terraform destroy` for the rest.

### 9. Real bug: `global.additionalLabels` overwriting ArgoCD's internal `part-of`

Discovered in real testing, not anticipated in the original design: the first version of `values/argocd.yaml` included `global.additionalLabels: {app.kubernetes.io/part-of: minitube}`, intended only as a grouping label. The `argo-cd` chart already sets `app.kubernetes.io/part-of: argocd` on all its resources (including `argocd-cm`/`argocd-secret`) — and `argocd-server`/`argocd-application-controller` itself uses an informer with that label selector to locate its own configuration at runtime. Since `additionalLabels` **overwrites** (same key), rather than adds, the value became `minitube`, and the two components that depend on that filter went into a permanent `CrashLoopBackOff` with `configmap "argocd-cm" not found` — even with the ConfigMap existing, visible, and with correct RBAC (confirmed via `kubectl auth can-i`). `redis`, `repo-server`, and `applicationset-controller` remained healthy because they don't depend on that filter, which helped isolate the cause.

Fixed by removing `global.additionalLabels` from `values/argocd.yaml` — the "part-of: minitube" grouping already exists at the Namespace level (`kubernetes_namespace_v1.argocd`), which doesn't collide with anything internal to the chart. Lesson recorded as a comment in the values file itself.

### 10. Additional IAM grants discovered in real testing (CreateNodegroup)

Two gaps in the same class as those already documented in ADR 006 (provider/API checks not obvious from the declared resource): `CreateNodegroup` (called by `aws_eks_node_group.lab_spot`) validates the managed policies already attached to the node's role (`iam:ListAttachedRolePolicies`) and confirms that the `AWSServiceRoleForAmazonEKSNodegroup` service-linked role already exists via a direct `iam:GetRole` on that ARN — neither covered by the original `PassEksRoles` `Statement` (which only had `GetRole`/`PassRole` on the cluster/node roles, not on the SLR). Both only surfaced because, in this session, it was `cloudlab-operator` (not CloudShell/root) who called `CreateNodegroup` for the first time. Fixed with an additional action in the `PassEksRoles` `Statement` itself and a new `ReadEksServiceLinkedRoles` `Statement` (only `iam:GetRole`, scoped to the two EKS SLRs), both in `terraform/bootstrap-iam/main.tf`.

### 11. Conflict with the access entry auto-created by `bootstrap_cluster_creator_admin_permissions`

Also discovered in real testing: since `cloudlab-operator` became the one creating the cluster in this session (unlike Phases 1–2, where it was CloudShell/root), `bootstrap_cluster_creator_admin_permissions = true` (ADR 004) automatically creates, on the AWS side, an access entry + `AmazonEKSClusterAdminPolicy` association for that same principal — conflicting (`ResourceInUseException`) with the explicit `aws_eks_access_entry.operator` that Terraform tries to create on top of it. Resolved in this session via `terraform import` of the already-existing access entry into the state (without resorting to any manual `aws eks` command outside Terraform) — not a code change, since `bootstrap_cluster_creator_admin_permissions` itself isn't retroactively changeable on an already-created cluster. Recorded here for the next session: if the same principal creates the cluster again, the behavior repeats, and the same `terraform import` fixes it.

### Alternatives considered

- **Manual `helm install`:** discarded — reintroduces an imperative step that would need to be remembered and rerun every session, breaking the "painless to recreate" ephemeral infrastructure principle.
- **Argo CD Autopilot:** discarded — its own bootstrap tool, diverges from the Terraform-first pattern already established in earlier phases; brings no additional learning benefit for this project.
- **An `Application` YAML applied manually once:** discarded — would reopen, even if just once, the manual `kubectl apply` exception that Phase 3 exists to close.
- **`AppProject` inside `gitops/platform/`:** discarded — chicken-and-egg problem (see decision 3).
- **PAT (Personal Access Token):** discarded — typically broader scope than a deploy key, subject to expiration, managed separately from the repository's configuration.
- **Making the repository public:** discarded in this decision — would eliminate the need for a credential, but would publicly expose ADRs with AWS account details and the project's entire history. **Update, still in the same session:** the repository was made public by the operator for operational convenience (allowing `git pull` directly in CloudShell without configuring a Git credential there), after the deploy key was already implemented, and reverted to private still in the same session, with the project's intent clarified: the repository becomes public **deliberately at the end of the project** (portfolio/LinkedIn disclosure), not incidentally during development. The SSH deploy key keeps working normally in both cases (doesn't depend on repository visibility).
- **ArgoCD self-management (app-of-apps) already in this phase:** discarded — see decision 7.

## Consequences

- `terraform/envs/lab/versions.tf` gains the `kubernetes` (`~> 3.2`) and `helm` (`~> 3.2`) providers.
- `terraform/envs/lab/main.tf` gains `data "aws_eks_cluster_auth" "lab"` and the `kubernetes`/`helm` providers configured from the cluster's attributes.
- `terraform/envs/lab/variables.tf` gains `argocd_repo_ssh_private_key` (sensitive, no default), `argocd_chart_version`, `argocd_apps_chart_version`, `argocd_gitops_revision` (default `main` — parameterized to allow validating a branch before merge, see decision 3 and the phase retrospective).
- `terraform/envs/lab/values/argocd.yaml` (new) defines the `argo-cd` chart's values — Dex/notifications disabled, explicit `resources.requests/limits` on all active components (the chart doesn't set limits by default).
- `terraform/envs/lab/argocd.tf` (new) creates the `argocd` namespace, the repository-credential `kubernetes_secret_v1`, and the two `helm_release`s (`argo-cd`, `argocd-apps`).
- `terraform/envs/lab/outputs.tf` gains `argocd_namespace`.
- `gitops/app/kustomization.yaml` no longer instructs manual application; `gitops/app/namespace.yaml` and `gitops/app/deployment.yaml` switch the `app.kubernetes.io/managed-by` label from `kubectl` to `argocd`.
- `gitops/platform/README.md` (new) — the directory's first file, documenting its purpose and what arrives in Phase 5.
- Post-apply functional validation gains `terraform/envs/lab/scripts/validate-argocd.sh` and the runbook [`docs/runbooks/validate/validate-argocd-gitops.md`](../runbooks/validate/validate-argocd-gitops.md) — the central check proves that a manual drift is reverted by `selfHeal` without any `kubectl apply`.
- `docs/runbooks/validate/validate-transcoding.md` and the header of `terraform/envs/lab/scripts/validate-transcoding.sh` no longer mention `kubectl apply -k` as a prerequisite.
- `kubectl apply -k gitops/app/` is no longer necessary in any documented project flow from this phase on — the temporary exception opened in ADR 006 (item 7) is closed.
- `terraform/bootstrap-iam/main.tf` gains an action (`iam:ListAttachedRolePolicies`) in the existing `PassEksRoles` `Statement` and a new `Statement` (`ReadEksServiceLinkedRoles`) — see decision 10.

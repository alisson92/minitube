# 008 — CloudFront, DNS/TLS, and platform add-ons

## Status

Accepted

## Context

Phase 4 completion criterion (`CLAUDE.md`): `app.<domain>` serving video via CDN with valid HTTPS. The phase was split into 2 PRs because of a non-instantaneous external dependency: the manual delegation of NS records by the user at the root domain's registrar. The first PR (`feat/route53-zone-and-cert`, `terraform/bootstrap/dns.tf`) created the Route 53 hosted zone (`minitube.projetodevops.com.br`) and the wildcard ACM certificate (`*.minitube.projetodevops.com.br`), both persistent — confirmed in this session, independently, as delegated (`dig`) and `ISSUED` (`aws acm describe-certificate`), before any code from this PR was written. This ADR covers the second PR: CloudFront, the 3 platform IRSA roles, the add-ons via GitOps, and the Ingresses.

## Decisions

### 1. `app.<domain>` = CloudFront alias = phase completion criterion

`terraform/envs/lab/cloudfront.tf` creates `aws_route53_record.app` as an alias A record pointing to the distribution — via Terraform, not `external-dns`, since CloudFront is itself a Terraform resource (no reason to delegate this discovery to an in-cluster controller).

### 2. `argocd.<domain>` goes directly to the ALB, not via CloudFront

ArgoCD is an internal operational tool — it doesn't benefit from edge caching, and keeping CloudFront restricted to serving HLS by default + `/api/*` on demand keeps its dynamic behavior minimal. Routed via `gitops/platform/argocd/ingress.yaml` + `external-dns` (the ALB is dynamically provisioned by the controller, so only an in-cluster controller knows its current endpoint each session — a static `aws_route53_record` in Terraform wouldn't work here, unlike the CloudFront record).

### 3. A single ACM certificate (us-east-1) serves both CloudFront and the ALB

Already anticipated in the comment of `terraform/bootstrap/dns.tf` since PR #1. CloudFront requires `us-east-1` regardless of the origins' region; this project's region is already `us-east-1` by default.

### 4. Shared IngressGroup — a single ALB for app and ArgoCD

`gitops/app/ingress.yaml` and `gitops/platform/argocd/ingress.yaml` use `alb.ingress.kubernetes.io/group.name: minitube`, provisioning a single ALB instead of two (cost: ~$0.0225/h fixed per ALB). Both set `alb.ingress.kubernetes.io/load-balancer-name: minitube-app` (identical in both) to give the ALB a predictable name, instead of relying on the controller's auto-generated tags.

### 5. `data "aws_lb"` by name, not by tags — and the circular dependency this exposes

The ALB is dynamically provisioned by the aws-load-balancer-controller from the Ingress, not by Terraform. `terraform/envs/lab/cloudfront.tf` needs its DNS name for CloudFront's dynamic origin — resolved via `data "aws_lb" { name = "minitube-app" }` (fixed name, decision 4), not via tag filtering (whose exact controller syntax isn't worth risking a guess on).

This exposes a real circular dependency: on the first `apply` of a new environment, `helm_release.argocd_apps` (which triggers reconciliation of the Ingress → ALB) and the read of `data.aws_lb.app_shared` happen in the same run — the ALB may not exist yet when the data source is read, even with `depends_on` guaranteeing the correct order of Terraform resources among themselves (`depends_on` doesn't wait for ArgoCD/the controller *inside* the cluster to finish converging). Mitigation: the same class of solution already used in ADR 007 (decision 8) for ArgoCD's own bootstrap — a two-step `apply`, documented in the runbook: if `data.aws_lb.app_shared` fails because the ALB doesn't exist yet, wait ~1-2 min and reapply.

### 6. Delivery of the 3 add-ons via a multi-source ArgoCD Application

Each add-on (aws-load-balancer-controller, external-dns, cert-manager) is a dedicated Application in `terraform/envs/lab/argocd.tf` (`argocd-apps` chart, same mechanism as ADR 007) with two `sources`: the official remote Helm chart + a `ref: values` pointing to this repository itself (`gitops/platform/<addon>/values.yaml`). This allows injecting the corresponding IRSA role's ARN (known only to Terraform) via `helm.parameters`, without manually copying anything to Git.

**Alternatives discarded:**
- **Kustomize `helmCharts:` (HelmChartInflationGenerator):** incompatible with `directory.recurse = true`, already in use by the `platform` Application — adopting it would require changing that entire Application's source type, with no real gain over the chosen option.
- **Pre-rendered, committed `helm template`:** breaks "Git as the single source of truth" every time a chart version bumps — ArgoCD would never know the chart changed, real risk of silent drift between what's committed and the real chart.

### 7. `gitops/platform/` gains a subdirectory per add-on; the `platform` Application excludes `values.yaml`

Each add-on's `values.yaml` isn't a valid standalone Kubernetes manifest — the `platform` Application (`directory` mode, recursive) gains `directory.exclude = "**/values.yaml"` to avoid trying to sync them as loose resources. The only real plain manifest that the `platform` Application still syncs in this phase is `cert-manager/cluster-issuer.yaml`.

### 8. Functional `ClusterIssuer`, but with no real public consumer in this phase

`gitops/platform/cert-manager/cluster-issuer.yaml` (DNS-01 via Route53) proves that cert-manager's IRSA role and RBAC work end-to-end (the ClusterIssuer reaches `Ready`), but no `Certificate` is issued by it yet — CloudFront and the ALB use the already-existing, validated ACM certificate (persistent, PR #1). YAGNI: issuing a real Let's Encrypt certificate would require publicly exposing an HTTP-01 endpoint or reusing the same DNS-01 challenge with no gain over the already-validated ACM certificate. `hostedZoneID` is hardcoded in the manifest (persistent zone, stable ID between sessions) — same pattern as `var.operator_role_arn`.

### 9. Catch-all app Ingress, no `host:`

`gitops/app/ingress.yaml` doesn't declare `host:` — domain-based routing is already resolved by the CloudFront alias (decision 1); a `host: app.<domain>` on the Ingress would semantically collide with that, since traffic arriving at the ALB via CloudFront no longer carries the original hostname on `/api/*` the way the Ingress would expect without a proper origin request policy (already covered via `Managed-AllViewerExceptHostHeader`).

### 10. ArgoCD's SSH deploy key now persists via SSM Parameter Store, no longer via `TF_VAR` every session

ADR 007 (decision 4) kept the private key only in `TF_VAR_argocd_repo_ssh_private_key`, with no persistence — which, in practice, required generating a new key pair and re-registering the deploy key on GitHub in **every** session that recreated `envs/lab`, contrary to the project's goal that recreating the environment from scratch should be painless (`CLAUDE.md`, principle 1: "if it hurts, the code still isn't good"). Discussed with the operator upon encountering this friction in practice.

Fixed: `terraform/bootstrap/ssm.tf` (new) creates `aws_ssm_parameter.argocd_repo_ssh_private_key` (`SecureString`), persistent like the other `bootstrap/` resources (ECR, Route 53 zone, certificate). `lifecycle.ignore_changes = [value]` guarantees that only the first `apply` (with a real `TF_VAR_argocd_repo_ssh_private_key`) writes the value — every subsequent `apply`, even with the variable at its empty default, never tries to overwrite it. `terraform/envs/lab/argocd.tf` now reads the value via `data "aws_ssm_parameter" { with_decryption = true }`, no longer via its own sensitive variable — the `argocd_repo_ssh_private_key` variable was removed from `envs/lab/variables.tf`.

SSM Parameter Store was chosen (over Secrets Manager) for having no relevant cost on the `Standard`/`SecureString` tier with the managed `aws/ssm` KMS key, and for not being an action restricted by the daily operator's `PowerUserAccess` (unlike any IAM resource) — no need for any new grant in `bootstrap-iam`. The deploy key itself remains the right choice (ADR 007, decision 4); only the private key's persistence mechanism changed.

**Practical consequence:** the old private key (the pair generated in Phase 3) no longer existed on disk anywhere — the corresponding orphaned deploy key on GitHub was removed and replaced with a new pair in this session, whose private key was written once into the SSM parameter. From now on, no future session needs to generate or register a new deploy key.

### 11. New `minitube-platform-*` IAM prefix

`terraform/bootstrap-iam/main.tf` gains the `ManagePlatformIrsaRoles` `Statement`, in the same form as `ManageAppIrsaRoles` (ADR 006), scoped to `arn:aws:iam::<account>:role/minitube-platform-*` — a prefix distinct from `minitube-app-*` to keep the two grants independently auditable, even with identical actions.

### 12. Four real bugs found in the first real sync, all fixed

None of the four showed up in `terraform plan`/`validate` — only in ArgoCD's real sync and the real functional test, reinforcing the "exists vs. works" principle (`docs/engineering-standards.md` §11):

1. **`AppProject.sourceRepos` didn't allow the add-ons' Helm repositories.** The 3 multi-source Applications (decision 6) failed with `InvalidSpecError: application repo ... is not permitted in project` — `sourceRepos` restricts **every** source of every Application in the project, not just Git. Fixed by adding the 3 chart URLs (`eks-charts`, `external-dns`, `charts.jetstack.io`) to the list.
2. **`AppProject.destinations` didn't allow `kube-system`.** The cert-manager chart creates leader-election `Role`/`RoleBinding` in `kube-system` by upstream default, regardless of the rest of the chart's install namespace — `SyncFailed: namespace kube-system is not permitted in project`. Fixed by adding `kube-system` to the allowed destinations.
3. **`aws-load-balancer-controller` doesn't discover the VPC ID on its own in this cluster.** Without an explicit `vpcId` in the values, the controller tries to discover it via IMDS on the node's EC2 instance — fails (`context deadline exceeded`) and the pod goes into `CrashLoopBackOff`. Fixed by injecting `vpcId = aws_vpc.lab.id` via `helm.parameters` on the Application (same mechanism already used for the IRSA role's ARN — the value changes every session, so it can't be hardcoded in `values.yaml`).
4. **Shared ALB rule priority inverted (`group.order`).** `gitops/app/ingress.yaml` (catch-all, no `host:`) and `gitops/platform/argocd/ingress.yaml` (`host: argocd.<domain>`) share the same `IngressGroup` (decision 4) — the catch-all rule had `group.order: "10"` (higher priority, lower number) against `"20"` for ArgoCD's Ingress, so the ALB matched **every** request — including `argocd.<domain>` — to the `api` backend before evaluating the host-specific rule. Symptom: `argocd.<domain>` responded with a `404` from `uvicorn` (the FastAPI API), valid TLS, no error on ArgoCD's side. Fixed by inverting the values: rules with a specific `host:` need a **lower** number (higher priority) than the catch-all.

### 13. `terraform import` of the access entry failing because of an unrelated data source

When re-importing `aws_eks_access_entry.operator` (same conflict as ADR 007 item 11, which recurs whenever `cloudlab-operator`, not CloudShell/root, creates the cluster), the `terraform import` command failed even with the correct target resource — because `terraform import` evaluates **all** of the module's data sources as part of preparing the state, including `data.aws_lb.app_shared` (decision 5), which doesn't resolve on a newly created VPC without an ALB yet. Worked around by temporarily renaming `cloudfront.tf` (and removing the 2 lines in `outputs.tf` that reference it) during the `import`, restoring the files right after — no permanent code change, just an operational procedure to repeat if the same scenario happens again.

### 14. Process bug: a local session without commit/push corrupted decision 10's SSM parameter

All the code in this session was written locally without commit/push before asking the operator to apply the `ManagePlatformIrsaRoles` grant via CloudShell. CloudShell clones from GitHub, so it only saw the old `main` — without decision 10's `ssm.tf`. Since the remote state (S3, shared) already had the parameter (created by an earlier local session), CloudShell's `terraform plan` saw a resource "in the state but not in the code" and proposed destroying it; the operator, following the normal plan-review flow, applied it. Result: the SSM parameter (and the private key it held) was deleted without anyone having done anything "wrong" in isolation — each side correctly followed the process with an outdated view of the other side.

**Fixed:** commit + push the branch before any Terraform operation requested of a different session (CloudShell, another operator) against the same remote backend. **Process lesson, not a code one:** two Terraform sessions against the same remote state need the same local code before any `plan`/`apply` in either one — never assume "the state already has the right answer" is a substitute for syncing the code first.

### 15. `terraform destroy` leaves orphaned AWS resources when the `aws-load-balancer-controller` is involved

The 3 add-on Applications and the `app`/`platform` Applications (declared via `helm_release.argocd_apps`, decisions 6-7) don't have the `resources-finalizer.argocd.argoproj.io` finalizer. When destroying `envs/lab`, Terraform's destroy order (node group before anything still depending on it being up) kills the `aws-load-balancer-controller` pod **before** any Ingress is removed — the controller never gets the chance to delete the ALB it provisioned itself. Three cascading consequences, all discovered only in this session's real `destroy` (none of them show up in a `plan -destroy`):

1. **Orphaned ALB on AWS**, with `in-use` ENIs in the public subnets, blocking `DeleteSubnet`/`DetachInternetGateway` (`DependencyViolation`). Fixed via manual `aws elbv2 delete-load-balancer`.
2. **`argocd` namespace stuck in `Terminating`** because of the `elbv2.k8s.aws/resources` (on the Ingress) and `group.ingress.k8s.aws/minitube` (on the `TargetGroupBinding`) finalizers — only the controller (already dead) would remove them. Trying to remove the finalizers via `kubectl patch` in turn failed on the LBC's own *admission webhook* (`no endpoints available`, the webhook pod is also dead). Fixed by first deleting the `aws-load-balancer-webhook` `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration`, then manually removing the finalizers.
3. **Two security groups created by the LBC** (`k8s-<cluster>-<hash>`, `k8s-traffic-<cluster>-<hash>`) surviving the entire cluster, blocking `DeleteVpc`. Fixed via `aws ec2 delete-security-group` (no cross rules between them, safe to delete directly).

**Not fixed in this session's code** — recorded as technical debt: none of the three fixes were automated; all required manual intervention via AWS CLI during the `destroy`. Candidates for a future session: (a) adopt the finalizer on the Applications that manage LBC resources, accepting that Terraform's `destroy` now waits for ArgoCD to delete the resources first (slower, but automatic); or (b) a pre-destroy step in the runbook/script that runs `kubectl delete ingress --all -A` and waits for the ALB to disappear before `terraform destroy` touches the node group.

## Consequences

- `terraform/bootstrap-iam/main.tf` gains the `ManagePlatformIrsaRoles` `Statement` (applied via CloudShell/root, before any `apply` in `envs/lab`).
- `terraform/envs/lab/iam-platform.tf` (new): 3 `aws_iam_role`s + policies (LBC vendored from `terraform/envs/lab/policies/aws-load-balancer-controller-iam-policy.json`; external-dns and cert-manager inline, scoped to the zone_id).
- `terraform/envs/lab/dns-data.tf` (new): `data "aws_route53_zone"`/`data "aws_acm_certificate"`, consumed from `terraform/bootstrap/` — never via `terraform_remote_state` (same reason as ADR 006: modules with different lifecycles shouldn't couple via state).
- `terraform/envs/lab/cloudfront.tf` (new): OAC, bucket policy, distribution (S3 default + `/api/*` → ALB), Route53 alias.
- `terraform/envs/lab/argocd.tf`: `AppProject` gains the `argocd` destination; the `platform` Application gains `directory.exclude`; 3 new multi-source Applications; `kubernetes_secret_v1.argocd_repo_credentials` now reads `data.aws_ssm_parameter` instead of `var.argocd_repo_ssh_private_key` (removed).
- `terraform/bootstrap/ssm.tf` (new): `aws_ssm_parameter.argocd_repo_ssh_private_key`, persistent — see decision 10.
- `terraform/envs/lab/values/argocd.yaml`: `configs.params."server.insecure" = true` (TLS terminates at the ALB).
- `gitops/platform/{aws-load-balancer-controller,external-dns,cert-manager}/values.yaml`, `cert-manager/cluster-issuer.yaml`, `argocd/ingress.yaml` (new).
- `gitops/app/ingress.yaml` (new) + updated `kustomization.yaml`.
- `terraform/envs/lab/scripts/validate-cloudfront-dns-tls.sh` + `docs/runbooks/validate/validate-cloudfront-dns-tls.md` (new), following the post-apply functional validation pattern (`docs/engineering-standards.md` §11).

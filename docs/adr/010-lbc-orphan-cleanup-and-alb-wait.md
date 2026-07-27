# 010 — Waiting for the ALB on apply and eliminating the LBC orphan on destroy

## Status

Accepted

## Context

Phase 5 resumption session. The initial `apply` of `envs/lab` failed (as already expected and documented since ADR 008 decision 5) on `data.aws_lb.app_shared`, requiring a manual re-run — behavior incompatible with the goal of a reliable pipeline, where `apply` needs to run from start to finish in a single execution, with no human intervention. The subsequent `destroy` got stuck again on the same problem already recorded **3 times** before this session (ADR 008 items 7-9 → ADR 009 decision 5 → ADR 009 decision 6): the ALB and 2 security groups from `aws-load-balancer-controller` survived the already-destroyed node group, blocking `DeleteSubnet`/`DetachInternetGateway` with `DependencyViolation`, and the `argocd` namespace got stuck in `Terminating` because of LBC finalizers on an `Ingress`/`TargetGroupBinding` with no live controller left to remove them.

Unlike the 3 previous occurrences, this time both problems were fixed in code — but the `destroy` problem required **four real iterations** of root-cause analysis, each one only exposed by actually testing a full `apply`→`destroy` cycle. None of them showed up in `terraform plan`/`validate` — reinforcing, once again, the "exists vs. works" principle (`docs/engineering-standards.md` §11).

## Decisions

### 1. `null_resource` with an AWS CLI poll before `data.aws_lb.app_shared`

The existing `depends_on = [helm_release.argocd_apps]` only guarantees the order of Terraform's API calls — not that `aws-load-balancer-controller` has already reconciled the `Ingress` and provisioned the ALB inside the cluster at that instant. Since `helm_release.argocd_apps` returns as soon as the Applications are created (well before ArgoCD syncs and the LBC acts), `data.aws_lb.app_shared` would almost always fail on the first `apply` of a new environment.

Fixed with `resource "null_resource" "wait_for_alb"` (`terraform/envs/lab/cloudfront.tf`), with `depends_on = [helm_release.argocd_apps]` and a `provisioner "local-exec"` that polls `aws elbv2 describe-load-balancers --names minitube-app` (10 attempts, 10s apart, total timeout of 5 min) before `data.aws_lb.app_shared` is read. Explicit `interpreter = ["/bin/bash", "-c"]` — the provisioner's default (`/bin/sh -c`) resolves to `dash` in this environment, which doesn't understand `set -o pipefail`, breaking the script on the first real attempt.

**Discarded alternative:** `time_sleep` with a fixed duration, the same mechanism already used in ADR 009 decision 2. Rejected because ALB provisioning time varies — a fixed value is either too short (repeats the same failure) or wastes time on every run. Validated in this session across two full `apply`s from scratch: it waited 2min01s and 2min11s respectively, with no failures.

**Practical consequence:** new `hashicorp/null` provider (`~> 3.2`), pinned in `terraform/envs/lab/versions.tf`.

### 2. Separate `AppProject` in its own `helm_release`, destroyed last

The `resources-finalizer.argocd.argoproj.io` finalizer (decision 3 below) makes ArgoCD prune an Application's resources before removing its CR — but this requires the `AppProject` referenced by the Application (`spec.project`) to still exist throughout the pruning. With `projects.minitube-platform` and `applications.platform` in the **same** `helm_release.argocd_apps`, `helm uninstall` deleted both at the same time, with no guaranteed order between different CRD kinds — in practice, the `AppProject` disappeared before the `platform` pruning finished, and ArgoCD permanently failed with `error getting app project "minitube-platform": ... not found`, locking the `platform` Application (owner of ArgoCD's `Ingress`) forever.

Fixed by extracting the `projects` block into `resource "helm_release" "argocd_project"` (`terraform/envs/lab/argocd.tf`), with only `depends_on = [helm_release.argocd]` (created before `argocd_apps`, with no real ordering constraint). `helm_release.argocd_apps` gains `depends_on = [..., helm_release.argocd_project]` — on destroy, this inverts to: `argocd_apps` (and the Applications it contains) destroyed **first**, `argocd_project` (the `AppProject`) destroyed **afterwards**. The `AppProject` now survives the entire pruning window of the Applications that reference it.

### 3. `resources-finalizer.argocd.argoproj.io` finalizer on the `app` and `platform` Applications

None of the 5 Applications had `metadata.finalizers`. Without this finalizer, deleting the Application CR (which `helm uninstall` does on `destroy`) does **not** trigger ArgoCD to prune the resources it manages first — the `Ingress`/`TargetGroupBinding` sharing the ALB (decision 4 of ADR 008) were left orphaned: neither ArgoCD (object already removed) nor the LBC (never notified) had any way to deprovision the ALB before `aws_eks_node_group` was destroyed.

Fixed by adding `finalizers = ["resources-finalizer.argocd.argoproj.io"]` to `applications.app` and `applications.platform` — the two owners of the `Ingress` resources that share the ALB. With the finalizer, deleting these Applications now **blocks** until ArgoCD prunes the managed resources. `helm_release.argocd_apps` gained `wait = true` (already the provider default, now explicit) and `timeout = 600` (previously unset, falling back to the 300s default) to allow room for this pruning plus the ALB cleanup on AWS.

**Discarded alternative:** a pre-destroy script (`kubectl delete ingress --all -A` + pausing `syncPolicy`), already considered in ADRs 008/009. Rejected for not being declarative — it would require remembering to run an extra step before every `destroy`, the opposite of this session's goal.

### 4. The entire network path (NAT + IGW + routes + associations) needs to survive the pruning

With decisions 2-3 applied, the first complete test `destroy` got stuck again — this time in `helm_release.argocd_apps` itself, for **10 minutes** (decision 3's timeout), until it failed with `context deadline exceeded`. Diagnosis: nothing in `helm_release.argocd_apps` references `aws_nat_gateway.lab`, so Terraform destroyed it in parallel, within the first minute of `destroy` — cutting off the LBC pods' (private subnet) access to the AWS API right in the middle of pruning (`dial tcp ...:443: i/o timeout` in the LBC logs).

The first fix — `depends_on` on the NAT gateway + its private route + private subnet associations — **wasn't enough**: the NAT gateway survived, but its own subnet is *public*, and its route to the Internet Gateway (`aws_route.public_internet_gateway`) and the public subnet associations had no protection at all — they were destroyed within the first seconds of `destroy` regardless. The NAT gateway remained standing, but isolated, with no path at all to the internet — same symptom (`i/o timeout`), a slightly different cause.

Fixed by pinning down the **complete** network path — the private side (`aws_nat_gateway.lab`, `aws_route.private_nat_gateway`, `aws_route_table_association.private`) and the public side the NAT gateway depends on (`aws_internet_gateway.lab`, `aws_route.public_internet_gateway`, `aws_route_table_association.public`) — in `helm_release.argocd_apps`'s `depends_on`. In both directions this dependency is correct, not just a destroy workaround: the nodes/pods already need this complete path since creation, to pull images and talk to the AWS API.

### 5. LBC and external-dns IAM policies also need to survive the pruning

With decisions 2-4 applied, a third full test `destroy` got stuck again, the same 10-minute pattern — but this time the LBC logs showed `AccessDenied: ... is not authorized to perform: elasticloadbalancing:DescribeTargetHealth` instead of a timeout: the network was already working. The LBC's IAM *role* (`aws_iam_role.aws_load_balancer_controller`) was already implicitly protected — its ARN is referenced directly in `helm_release.argocd_apps`'s `values` (the `aws-load-balancer-controller` Application's `helm.parameters`), creating an implicit dependency. But the inline **policy** (`aws_iam_role_policy.aws_load_balancer_controller`) is a separate resource, referenced nowhere — nothing protected it, and it was destroyed in parallel while the LBC was still trying to deregister targets and delete the ALB.

Fixed by adding `aws_iam_role_policy.aws_load_balancer_controller` to `depends_on`. `aws_iam_role_policy.external_dns` received the same treatment preemptively — external-dns needs this policy to delete the Route 53 record for `argocd.<domain>` when the corresponding `Ingress` is pruned; without it, the record would be silently orphaned (it doesn't block `destroy`, but it's a mess the pattern was already causing elsewhere). `aws_iam_role_policy.cert_manager` did not receive the same treatment — in this architecture cert-manager never actually gets to issue a real `Certificate` (ADR 008 decision 8), so it has no API call in flight during pruning.

With all five decisions applied, a fourth complete `apply`→`destroy` cycle, from scratch, ran with no manual intervention on either end — `helm_release.argocd_apps` was destroyed in **29 seconds** (before, when it didn't hang completely, it would get stuck for 10+ minutes).

## Consequences

- `terraform/envs/lab/cloudfront.tf`: `resource "null_resource" "wait_for_alb"`; `data.aws_lb.app_shared` now depends on it instead of `helm_release.argocd_apps` directly.
- `terraform/envs/lab/versions.tf`: `hashicorp/null ~> 3.2` provider added.
- `terraform/envs/lab/argocd.tf`: new `resource "helm_release" "argocd_project"` (just the `projects` block); `applications.app`/`applications.platform` gain `finalizers`; `helm_release.argocd_apps` gains `wait = true`, `timeout = 600`, and `depends_on` covering `argocd_project` + the entire network path (NAT/IGW/routes/associations, public and private) + the LBC and external-dns IAM policies.
- Validated in this session: 4 complete `apply`→`destroy` cycles from scratch, each one exposing and fixing a real root cause, until the fourth ran cleanly end to end — `scripts/validate-cloudfront-dns-tls.sh` (9 checks) passed on every successful `apply`; complete cleanup confirmed via direct AWS API after each final `destroy`.
- Closes the technical debt recorded in ADR 008 (items 7-9, 15) and ADR 009 (decisions 5 and 6) — 4th occurrence of the original LBC bug, now fixed in code, plus 3 additional root causes (AppProject, network, IAM) discovered and fixed only by actually testing the fix.

# Runbook — from zero to a running environment (and back to zero)

> Single entry point: gathers, in order, the complete sequence of steps to run MiniTube — from a blank AWS account to `app.<domain>` serving video, and back to zero at the end. It doesn't replace the specific runbooks (each one remains the source of truth for its own step) — it just organizes them into an executable order, with the friction of each stage (what's manual, what requires a different session, what only runs once) made explicit.

## Which part do you need

- **Resuming a work session on an AWS account already used for this project?** Go straight to "Part 2 — session cycle" below — Part 1 has already been done and persists across sessions.
- **Bootstrapping a genuinely new AWS account** (replicating the project from scratch, on another account)? Start with Part 1.

## Overview

| Step | What | Who runs it | Frequency |
| ----- | ----- | --------- | ---------- |
| 1.1 | Account, MFA, Identity Center, operator user | Manual, AWS console | Once per account |
| 1.2 | Apply `terraform/bootstrap-iam/` | Root/CloudShell | Once per account¹ |
| 1.3 | Apply `terraform/bootstrap/` | Root/CloudShell (1st time) | Once per account¹ |
| 1.4 | Delegate the subdomain at the registrar | Manual, outside AWS | Once per domain |
| 1.5 | Generate ArgoCD's SSH deploy key | `cloudlab-operator`, local | Once per account¹ |
| 1.6 | Configure the local SSO profile | `cloudlab-operator`, local | Once per account/laptop |
| 2.1 | SSO login | `cloudlab-operator`, local | Every time the session expires |
| 2.2 | Apply `terraform/envs/lab/` | `cloudlab-operator`, local | **Every session** |
| 2.3 | Build + push the images | `cloudlab-operator`, local | Only if `app/` changed |
| 2.4 | Validate each subsystem | `cloudlab-operator`, local | **Every session** |
| 2.5 | Use the environment | `cloudlab-operator`, local | As needed |
| 2.6 | Destroy `terraform/envs/lab/` | `cloudlab-operator`, local | **Every session**, at the end |

¹ Already applied and persistent for the account used in this project (`479213212405`) — reapplying is only necessary if `bootstrap-iam/`/`bootstrap/` gain new code (steps 1.1/1.4 never repeat; only the `terraform apply` does).

---

## Part 1 — bootstrapping a new AWS account (once per account)

### 1.1 — Account, MFA, Identity Center, operator user

Complete step-by-step (all manual, via console, no Terraform) in [`docs/runbooks/bootstrap/aws-account-bootstrap.md`](bootstrap/aws-account-bootstrap.md), steps 1 through 5: account creation and MFA on root, opening CloudShell with a shared provider cache, cloning the repository, enabling IAM Identity Center, and creating the operator user.

### 1.2 — Apply `bootstrap-iam` (CloudShell/root)

⚠️ **Only runs with a root/CloudShell session.** It's not just the operator's permission set — this module has by now also accumulated the EKS roles, the smoke-test role, the account budget alert, and the inline policy with seven different permissions granted to the operator throughout the project. Full detail on each resource in step 6 of [`aws-account-bootstrap.md`](bootstrap/aws-account-bootstrap.md).

```bash
cd terraform/bootstrap-iam
terraform init
terraform plan
terraform apply
```

### 1.3 — Apply `bootstrap` (remote backend, ECR, DNS)

Still in the same root/CloudShell session (step 7 of [`aws-account-bootstrap.md`](bootstrap/aws-account-bootstrap.md)) — the first apply uses a local backend, since the state bucket doesn't exist yet. Once created, migration to the S3 backend is done separately (see [`bootstrap-remote-backend.md`](bootstrap/bootstrap-remote-backend.md) and [ADR 001](../adr/001-terraform-state-backend.md)).

```bash
cd ../bootstrap
terraform init
terraform plan
terraform apply
```

Creates, among other things: the state bucket, the two ECR repositories, the Route 53 hosted zone, and the wildcard ACM certificate.

### 1.4 — Delegate the subdomain at the registrar (manual, outside AWS)

```bash
terraform output route53_zone_name_servers
```

Register the 4 returned nameservers as an NS delegation at the root domain's registrar. **Not instant** — DNS propagation can take from minutes to a few hours; confirm with `dig NS <domain>` before moving on to Part 2.

### 1.5 — Generate ArgoCD's SSH deploy key (once)

ArgoCD needs its own credential to clone this private repository. Exact steps (generate the key pair, register the public one as a read-only deploy key on GitHub, write the private one via a single `terraform apply` in `bootstrap/`) are in the "Prerequisites" section of [`docs/runbooks/validate/validate-argocd-gitops.md`](validate/validate-argocd-gitops.md). After that apply, the key persists in SSM Parameter Store and never needs to be regenerated or re-exported.

### 1.6 — Configure the local SSO profile

Step 8 of [`aws-account-bootstrap.md`](bootstrap/aws-account-bootstrap.md) — `~/.aws/config` with a dedicated `sso-session`, then `aws sso login --profile cloudlab`.

**At the end of Part 1:** `terraform/bootstrap-iam/` and `terraform/bootstrap/` applied and persistent; `terraform/envs/lab/` doesn't exist yet. Everything from here on is Part 2, and repeats every session.

---

## Part 2 — session cycle (every time you use the environment)

### 2.1 — SSO login (if the previous session expired)

```bash
aws sso login --profile cloudlab
aws sts get-caller-identity --profile cloudlab
```

### 2.2 — Apply `terraform/envs/lab/`

```bash
cd terraform/envs/lab
terraform init -upgrade
AWS_PROFILE=cloudlab terraform plan
AWS_PROFILE=cloudlab terraform apply
```

Creates from scratch: VPC, EKS (cluster + spot node group), video S3 bucket, IRSA roles, ArgoCD, CloudFront, and the entire observability stack — automatically reconciled by ArgoCD from Git as soon as the cluster comes up, with no manual `kubectl apply`.

⚠️ **If the apply fails on `helm_release.argocd` with a connection error right after creating a new cluster** (`connection refused`/`context deadline exceeded`): a known symptom of the control plane not yet being ready for the `kubernetes`/`helm` providers in the same apply where it was created — the most common scenario here, not the exception, since the cluster is recreated every session. Documented fallback in the "Apply ArgoCD and run the test" section of [`validate-argocd-gitops.md`](validate/validate-argocd-gitops.md): `terraform apply -target=module.eks` first, then the full apply again.

⚠️ **If `make validate-all`/`validate-argocd.sh` hangs past its documented timeout waiting for the `platform` Application to reach `Synced`:** on a fresh cluster, `platform`'s `PrometheusRule` (`gitops/platform/kube-prometheus-stack/slo-rules.yaml`) can race the `kube-prometheus-stack` Application's operator webhook — ArgoCD applies it before the operator pod has ready endpoints (`no endpoints available for service "kube-prometheus-stack-operator-webhook"`), and without a `retry` policy this failed permanently instead of eventually succeeding once the pod came up. Fixed by giving `platform` the same explicit `retry`/`backoff` already used by `cert-manager`/`kube-prometheus-stack` for the identical class of sibling-Application race (`terraform/envs/lab/argocd.tf`). If it still happens (confirm first with `kubectl -n argocd describe application platform` — a `SyncError` mentioning the operator webhook, not a `kubectl`/network hang), force a fresh attempt without any manual `kubectl apply`:
```bash
kubectl -n argocd annotate application platform argocd.argoproj.io/refresh=hard --overwrite
```

### 2.3 — Build + push the images (only if the `app/` code changed)

If `app/api/` and `app/transcoder/` haven't changed since the last session, **skip this step** — the images are already published in ECR (persistent) and `gitops/app/deployment.yaml` already references the right tag.

If it did change:

```bash
account_id=$(aws sts get-caller-identity --profile cloudlab --query Account --output text)
aws ecr get-login-password --region us-east-1 --profile cloudlab | \
  docker login --username AWS --password-stdin "${account_id}.dkr.ecr.us-east-1.amazonaws.com"

docker build -t "${account_id}.dkr.ecr.us-east-1.amazonaws.com/minitube-api:vX.Y.Z" app/api
docker push "${account_id}.dkr.ecr.us-east-1.amazonaws.com/minitube-api:vX.Y.Z"
# repeat for minitube-transcoder if app/transcoder/ also changed
```

Then, update the tag in `gitops/app/deployment.yaml`, commit, and let ArgoCD sync — never a manual `kubectl set image` (see `docs/engineering-standards.md` §5).

### 2.4 — Validate each subsystem

All at once, in the right order, without stopping at the first failure (a `PASS`/`FAIL` summary for each at the end):

```bash
make validate-all
```

`make help` lists each individual check (`validate-network`, `validate-eks`, etc.), in case you only need to run one. What each one proves and how to read the result, in detail:

1. [`validate-vpc-network.md`](validate/validate-vpc-network.md) — real egress via NAT.
2. [`validate-eks-cluster.md`](validate/validate-eks-cluster.md) — control plane, nodes, a real pod scheduled.
3. [`validate-transcoding.md`](validate/validate-transcoding.md) — real upload → Job → FFmpeg → segments in S3.
4. [`validate-argocd-gitops.md`](validate/validate-argocd-gitops.md) — `selfHeal` reverts a manual drift without `kubectl apply`.
5. [`validate-cloudfront-dns-tls.md`](validate/validate-cloudfront-dns-tls.md) — real HLS via CDN, valid HTTPS.
6. [`validate-observability.md`](validate/validate-observability.md) — PVCs, Prometheus, Grafana, Loki.

### 2.5 — Use the environment

- **Watch page:** `make upload-video FILE=/path/to/video.mp4` uploads a real video and prints its `https://app.<domain>/?v=<video_id>` URL once transcoding succeeds (`terraform/envs/lab/scripts/upload-video.sh`) — see [`showcase-urls.md`](../showcase-urls.md).
- **ArgoCD:** [`access-argocd-ui.md`](access-argocd-ui.md) — real URL + password via `terraform output`.
- **Grafana:** `terraform output -raw grafana_admin_password`, at `grafana.<domain>`.
- **Load tests (k6):** [`../../load/README.md`](../../load/README.md) for an overview of the 4 scenarios, individual runbooks in `docs/runbooks/load/`.
- **Chaos experiments:** the 3 runbooks in `docs/runbooks/chaos/`, and [`incident-response.md`](incident-response.md) for the incident response runbook they train for.

### 2.6 — Destroy the environment (always, at the end of the session)

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan -destroy
AWS_PROFILE=cloudlab terraform destroy
```

Then, confirm via the direct AWS API — never trust `terraform state list` alone — that nothing billable is left:

```bash
aws eks list-clusters --profile cloudlab --region us-east-1
aws ec2 describe-nat-gateways --profile cloudlab --region us-east-1 --filter Name=state,Values=available
aws elbv2 describe-load-balancers --profile cloudlab --region us-east-1
aws cloudfront list-distributions --profile cloudlab --query 'DistributionList.Items[?Enabled==`true`]'
```

All should return empty. If `destroy` gets stuck with `DependencyViolation` on the Internet Gateway/subnets — the classic symptom of an orphaned `aws-load-balancer-controller` resource (ALB/security groups outliving the node group) — the root cause has already been structurally fixed by [ADR 010](../adr/010-lbc-orphan-cleanup-and-alb-wait.md); if it happens anyway, the manual recovery playbook is in decision 6 of [ADR 009](../adr/009-eks-access-entries-and-api-edge-routing.md).

⚠️ **If `destroy` gets stuck on `kubernetes_namespace_v1.argocd`/`kubernetes_namespace_v1.platform` (`Still destroying...` for several minutes, ending in `Error: context deadline exceeded`):** since [ADR 015](../adr/015-destroy-stale-metrics-apiservice-automation.md), `null_resource.cleanup_stale_metrics_apiservice` (`terraform/envs/lab/argocd.tf`) automates the cleanup below on every `destroy` that starts from an `apply` that already has this resource in state — manual intervention shouldn't be needed anymore in a full `apply`→`destroy` cycle.

If it still gets stuck (e.g. `aws`/`kubectl` missing from the `PATH` of whoever runs `destroy`, or the `null_resource` didn't yet exist in the state because the previous `apply` was done before ADR 015), the diagnosis and manual fallback fix are:

```bash
kubectl get namespace minitube-platform argocd -o yaml | grep -A5 "conditions:"
```

If `reason: DiscoveryFailed` shows up mentioning `metrics.k8s.io/v1beta1: stale GroupVersion discovery`: the `metrics-server`'s (cluster-scoped) `APIService` was left registered pointing at a backend that ArgoCD already removed when pruning the `metrics-server` `Application` — while this broken `APIService` exists, API discovery for the entire cluster fails, and the namespace finalization controller (which needs that complete discovery) gets stuck for **any** namespace, not just the metrics-server's. No risk of an orphaned resource (it's just API registration metadata, no real data involved):

```bash
kubectl delete apiservice v1beta1.metrics.k8s.io
```

The namespaces should finish terminating within seconds after this — rerun `terraform destroy` to resume from there. If the ADR 015 `null_resource` already existed in the state but still didn't run the cleanup in time, that's a sign of a new root cause, not covered by this runbook — investigate before assuming it's the same problem.

Original root cause: since `kubernetes_namespace_v1.argocd`/`.platform` started being managed directly by Terraform (needed for `kubernetes_secret_v1.grafana_admin` — see decision 12 of [ADR 011](../adr/011-observability-stack.md)), `destroy` started waiting for the graceful finalization of these namespaces via the Kubernetes API before destroying EKS — previously, destroying the cluster took everything down together without waiting, so this race was never visible.

`terraform/bootstrap-iam/` and `terraform/bootstrap/` **are not touched** — they stay up between sessions by design (see "Current state" in [`CLAUDE.md`](../../CLAUDE.md)).

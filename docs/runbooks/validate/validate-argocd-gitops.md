# Runbook — ArgoCD and GitOps flow functional validation

> Establishes the "functional validation post-apply" standard described in [`docs/engineering-standards.md`](../../engineering-standards.md#11-post-apply-functional-validation). See also [`docs/adr/007-argocd-gitops-bootstrap.md`](../../adr/007-argocd-gitops-bootstrap.md).

## Why this exists

`helm_release.argocd` without error and pods `Running` in the `argocd` namespace prove that ArgoCD **exists** — they do not prove it is actually reconciling `gitops/` from Git. The question that matters: if someone manually diverges the cluster (drift), does ArgoCD fix it on its own, without any `kubectl apply`? This is the real proof of the OpenGitOps principles of "applied by pull" and "continuously reconciled".

This runbook documents `terraform/envs/lab/scripts/validate-argocd.sh`, which confirms ArgoCD's components, the `Synced`/`Healthy` status of the two root Applications, that the API really responds, and — the central check — that a manual drift introduced into the cluster is reverted on its own by `selfHeal`.

## Prerequisites

### 1. Read-only SSH deploy key for ArgoCD to read the private repository

The `alisson92/minitube` repository is private — ArgoCD needs its own credential (it doesn't inherit your local SSH key). **Since Phase 4 (ADR 008), this is a one-time setup** — the private key persists in `aws_ssm_parameter.argocd_repo_ssh_private_key` (`terraform/bootstrap/ssm.tf`), read by `envs/lab` via a `data source` every session, without needing to be regenerated or re-exported on every `apply`. Only repeat the steps below if the SSM parameter doesn't exist yet (first project setup) or if the key needs to be rotated for some reason.

```bash
# 1. Generate the key pair outside the repository (use a temporary directory)
ssh-keygen -t ed25519 -C "argocd-minitube-readonly" -f /tmp/argocd-minitube-deploy-key -N ""

# 2. Register the PUBLIC key as a read-only Deploy Key
#    (no --allow-write ⇒ read-only by default)
gh repo deploy-key add /tmp/argocd-minitube-deploy-key.pub \
  --repo alisson92/minitube \
  --title "argocd-minitube-readonly"

# 3. Write the PRIVATE key to SSM Parameter Store, via a single apply of
#    terraform/bootstrap/ (never in .tfvars, never committed) -- after
#    this apply, lifecycle.ignore_changes ensures it never needs to be
#    passed again
cd terraform/bootstrap
AWS_PROFILE=cloudlab terraform apply \
  -var argocd_repo_ssh_private_key="$(cat /tmp/argocd-minitube-deploy-key)"

rm -f /tmp/argocd-minitube-deploy-key /tmp/argocd-minitube-deploy-key.pub
```

⚠️ If the SSM parameter doesn't exist yet and you run `terraform apply` in `envs/lab` without first having done step 3 above in `bootstrap/`, the `data "aws_ssm_parameter"` in `envs/lab/argocd.tf` fails with "parameter not found" — the order matters, `bootstrap/` first.

### 2. VPC + EKS + S3 bucket + IRSA + cluster access (same prerequisite as previous phases)

See [`docs/runbooks/validate/validate-eks-cluster.md`](./validate-eks-cluster.md) and [`docs/runbooks/validate/validate-transcoding.md`](./validate-transcoding.md) — nothing changes here, ArgoCD is just added to the same `terraform apply` of `envs/lab`.

## Apply ArgoCD and run the test

```bash
cd terraform/envs/lab
terraform init -upgrade     # downloads the new kubernetes/helm providers (versions.tf)
AWS_PROFILE=cloudlab terraform validate
AWS_PROFILE=cloudlab terraform plan     # review: (VPC+EKS if recreating) + argocd namespace + repo secret + 2 helm_release + new output
AWS_PROFILE=cloudlab terraform apply

AWS_PROFILE=cloudlab ./scripts/validate-argocd.sh
```

Dependencies in your environment: `aws` CLI, `jq`, `terraform`, `kubectl`, `curl`, `gh`.

⚠️ **If the `apply` fails on `helm_release.argocd` with a connection error** (`connection refused` / `context deadline exceeded`) **right after creating a brand-new cluster**: this is a known symptom of the control plane not yet being 100% ready for the `kubernetes`/`helm` providers within the same apply that created the cluster. Since this project recreates the cluster from scratch every session, this is the most common scenario, not the exception. Fallback with `-target` in two stages:

```bash
AWS_PROFILE=cloudlab terraform apply -target=module.eks

AWS_PROFILE=cloudlab terraform plan     # should show only the rest: S3, IRSA, argocd namespace, helm_releases
AWS_PROFILE=cloudlab terraform apply
```

> `-target=module.eks` brings up the cluster, the node group, and the OIDC provider (all inside `terraform/modules/eks/`, see [ADR 013](../../adr/013-terraform-vpc-eks-modules.md)) in a single stage — targeting an entire module applies every resource within it.

## How to access the ArgoCD UI

Since Phase 4, ArgoCD has its own Ingress/DNS/TLS — see [`docs/runbooks/access-argocd-ui.md`](../access-argocd-ui.md) (real URL and password via `terraform output`, no longer port-forward nor `argocd-initial-admin-secret`, which stopped being created once the password started being pre-seeded).

## How the validation script works

- **Ephemeral kubeconfig**: generated via `aws eks update-kubeconfig` in a temporary file, without writing to the operator's `~/.kube/config`.
- **Checks performed:**
  1. `argocd-server` and `argocd-repo-server` reach `Available`; `argocd-application-controller` has at least 1 `Ready` replica.
  2. The two root Applications (`app`, `platform`) reach `Synced` — `app` also needs `Healthy`; `platform` accepts an empty health status, since it syncs 0 resources at this phase (see `gitops/platform/README.md`).
  3. `Deployment/api` exists, carries the `argocd.argoproj.io/tracking-id` annotation (proof that ArgoCD created the resource, not a manual `kubectl apply` run separately), and the API responds at `/api/healthz` via port-forward.
  4. **Central check — drift and selfHeal:** the script patches the value of `metadata.labels."app.kubernetes.io/part-of"` on `deployment/api` (a deliberate manual divergence, never done via Git) and polls until ArgoCD reverts it on its own back to `minitube` (what `gitops/app/deployment.yaml` declares), with a 120s timeout. Not `spec.replicas`: [ADR 012](../../adr/012-hpa-cpu-autoscaling.md)'s HPA owns that field at runtime, and `terraform/envs/lab/argocd.tf`'s `ignoreDifferences` deliberately tells ArgoCD to never touch it — a replica-count drift would never revert. A label already declared in Git, with no `ignoreDifferences` entry, still proves the same thing.
- **Guaranteed cleanup:** `trap cleanup EXIT` kills the `port-forward` and, if the drift test was started but not confirmed reverted, forces the label back to `minitube` before exiting — the cluster never stays diverged from Git because of the test itself.

## Expected output

```
PASS: argocd-application-controller has at least 1 ready replica
PASS: Application 'app' reaches Synced+Healthy (up to 180s)
PASS: Application 'platform' reaches Synced (up to 180s; empty health accepted, 0 resources)
PASS: deployment/api carries an ArgoCD tracking-id annotation (proves ArgoCD created it, not a manual kubectl apply)
PASS: API is reachable and healthy via port-forward
Baseline: deployment/api label 'app.kubernetes.io/part-of'=minitube (gitops/app/deployment.yaml declares 'minitube')
Introducing manual drift: changing that label's value (never via GitOps)...
  [  5s] label='app.kubernetes.io/part-of'=drift-test
  [ 10s] label='app.kubernetes.io/part-of'=minitube
PASS: ArgoCD selfHeal reverted the drift back to 'minitube' in ~10s, with no manual intervention
=== All checks passed: ArgoCD is installed, both root Applications are synced from Git, and selfHeal reconciles drift without any kubectl apply. ===
```

Exit code `0` when everything passes, `1` if any check fails. The exact drift-reversion time varies with ArgoCD's reconciliation interval (by default, a few seconds up to ~3 minutes).

## Destroy everything at the end of the test

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan -destroy   # review: removes ArgoCD and the Applications along with VPC/EKS/S3/IRSA — everything
AWS_PROFILE=cloudlab terraform destroy
```

`terraform/bootstrap/` (ECR) and `terraform/bootstrap-iam/` (roles, permission set, budget alert) are **not** destroyed — they persist between sessions, with no relevant cost. Confirm nothing billable is left:

```bash
aws eks list-clusters --profile cloudlab --region us-east-1
aws ec2 describe-vpcs --profile cloudlab --region us-east-1 --filters "Name=tag:Name,Values=minitube-lab"
aws ec2 describe-nat-gateways --profile cloudlab --region us-east-1 --filter "Name=state,Values=available"
```

The deploy key registered on GitHub (`argocd-minitube-readonly`) also doesn't need to be removed between sessions — it's read-only and scoped to this repo; removing it is optional (`gh repo deploy-key delete <id> --repo alisson92/minitube`), but it's not a cost or security concern that justifies automating it now.

## Security / rollback

If the script is interrupted abnormally (`kill -9`) in the middle of the drift check and the `trap` doesn't run, revert manually:

```bash
aws eks update-kubeconfig --region us-east-1 --name minitube-lab --profile cloudlab --kubeconfig /tmp/minitube-kubeconfig
kubectl --kubeconfig /tmp/minitube-kubeconfig -n minitube-app label deployment/api "app.kubernetes.io/part-of=minitube" --overwrite
rm -f /tmp/minitube-kubeconfig
```

This is harmless even if run unnecessarily — ArgoCD would have already reverted the drift on its own; the command just speeds up the correction.

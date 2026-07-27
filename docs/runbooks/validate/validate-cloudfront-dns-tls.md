# Runbook — CloudFront, DNS/TLS, and platform add-ons functional validation

> Establishes the "functional validation post-apply" standard described in [`docs/engineering-standards.md`](../../engineering-standards.md#11-post-apply-functional-validation). See also [`docs/adr/008-cloudfront-dns-tls.md`](../../adr/008-cloudfront-dns-tls.md).

## Why this exists

A clean `terraform apply` creating the CloudFront distribution and the `ClusterIssuer`/Ingress does not prove that `app.<domain>` actually serves real video via the CDN with valid HTTPS — Phase 4's completion criterion. This runbook documents `terraform/envs/lab/scripts/validate-cloudfront-dns-tls.sh`, whose central check is a real HTTPS request to an HLS playlist through CloudFront, with a valid TLS chain and a cache header present.

## Prerequisites

### 0. Delegated Route 53 zone and issued ACM certificate (PR #1 of this phase, `terraform/bootstrap/`)

```bash
cd terraform/bootstrap
AWS_PROFILE=cloudlab terraform apply    # if not already applied
dig NS minitube.projetodevops.com.br    # confirm it resolves to awsdns-* nameservers
AWS_PROFILE=cloudlab aws acm describe-certificate \
  --region us-east-1 \
  --certificate-arn "$(terraform output -raw acm_certificate_arn)" \
  --query "Certificate.Status" --output text   # should return ISSUED
```

### 1. New IAM grant in `bootstrap-iam` — via CloudShell/root

```bash
cd terraform/bootstrap-iam
terraform plan     # review: new Statement "ManagePlatformIrsaRoles"
terraform apply
```

⚠️ Without this `apply`, the `apply` of `envs/lab` fails with `AccessDenied` when trying to create the 3 platform IRSA roles (`iam-platform.tf`).

### 2. `gitops/` manifests/values already committed

ArgoCD needs to find `gitops/platform/{aws-load-balancer-controller,external-dns,cert-manager}/values.yaml`, `cert-manager/cluster-issuer.yaml`, `argocd/ingress.yaml`, and `gitops/app/ingress.yaml` already on the branch that `var.argocd_gitops_revision` points to. To test before merging (same pattern as ADR 007, decision 5):

```bash
AWS_PROFILE=cloudlab terraform apply -var argocd_gitops_revision=feat/cloudfront-dns-tls
```

### 3. VPC + EKS + S3 + app IRSA + ArgoCD (prerequisites from previous phases)

See [`docs/runbooks/validate/validate-argocd-gitops.md`](./validate-argocd-gitops.md) and [`docs/runbooks/validate/validate-transcoding.md`](./validate-transcoding.md).

## Apply and run the test

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform init -upgrade
AWS_PROFILE=cloudlab terraform validate
AWS_PROFILE=cloudlab terraform plan     # review: 3 IRSA roles, CloudFront, 3 new Applications, edits in argocd.tf
AWS_PROFILE=cloudlab terraform apply

AWS_PROFILE=cloudlab ./scripts/validate-cloudfront-dns-tls.sh
```

Dependencies in your environment: `aws` CLI, `jq`, `terraform`, `kubectl`, `curl`, `dig`, `openssl`, `ffmpeg`.

⚠️ **If the `apply` fails on `data.aws_lb.app_shared` ("no matching load balancer found")**: this is an expected symptom in a fresh environment — the ALB only exists after the aws-load-balancer-controller reconciles `gitops/app/ingress.yaml`, which only happens after `helm_release.argocd_apps` (same run) triggers the sync. Same class of two-stage fallback already documented in ADR 007 (decision 8):

```bash
# Wait for the ALB to show up (1-2 min after the rest of the first apply succeeds)
watch -n 10 'aws elbv2 describe-load-balancers --names minitube-app --profile cloudlab --region us-east-1 --query "LoadBalancers[0].State.Code" --output text'

# Reapply as soon as the state above is "active"
AWS_PROFILE=cloudlab terraform apply
```

## How the validation script works

- **Ephemeral kubeconfig**, same pattern as previous scripts.
- **Checks performed, in order:**
  1. `app.<domain>` resolves via a public resolver (up to 5 min — DNS propagation can be cached even with the record already correct in Route53).
  2. The CloudFront distribution reaches `Deployed` (up to 10 min — the slowest step of a fresh `apply`).
  3. `ClusterIssuer letsencrypt-route53` reaches `Ready` — proves the IRSA role and cert-manager's RBAC work end to end, even with no real `Certificate` issued yet at this phase.
  4. The `aws-load-balancer-controller` provisions the shared ALB (Ingress `api` gets `.status.loadBalancer.ingress[0].hostname`).
  5. `argocd.<domain>` resolves — proves `external-dns` is actually creating records from ArgoCD's Ingress.
  6. The ArgoCD UI responds via `https://argocd.<domain>`, valid TLS, straight off the ALB (no CloudFront in front).
  7. **Central check:** ensures real HLS exists in S3 (reuses the same synthetic video from `validate-transcoding.sh` if `hls/` is empty) and confirms that `https://app.<domain>/hls/<video_id>/playlist.m3u8` responds `200`, carries an `X-Cache` header from CloudFront (Hit or Miss — either one proves it passed through the CDN), and presents a TLS chain issued by Amazon (ACM).
- **Guaranteed cleanup:** `trap cleanup EXIT` kills the port-forward eventually opened for the synthetic upload and removes temporary files — no cloud resource is created just for this test (unlike the VPC/EC2 smoke test), so there's no need to destroy anything beyond the ephemeral kubeconfig.

## Expected output

```
PASS: app.minitube.projetodevops.com.br resolves via a public resolver (up to 300s)
PASS: CloudFront distribution reaches Deployed (up to 600s)
PASS: ClusterIssuer letsencrypt-route53 reaches Ready (up to 180s)
PASS: aws-load-balancer-controller provisioned the shared ALB (up to 180s)
PASS: argocd.minitube.projetodevops.com.br resolves via a public resolver (up to 300s)
PASS: ArgoCD UI reachable via https://argocd.minitube.projetodevops.com.br with valid TLS
PASS: CloudFront serves the HLS playlist at https://app.minitube.projetodevops.com.br/hls/<video_id>/playlist.m3u8
PASS: response carries an X-Cache header from CloudFront (Hit or Miss)
PASS: TLS certificate chain for app.minitube.projetodevops.com.br is issued by Amazon (ACM)
=== All checks passed: app.minitube.projetodevops.com.br serves real HLS content via CloudFront over valid HTTPS, and argocd.minitube.projetodevops.com.br is reachable straight off the shared ALB. ===
```

Exit code `0` when everything passes, `1` if any check fails. The first run after a fresh `apply` tends to be the slowest (mainly CloudFront issuance/propagation); subsequent reruns in the same environment should pass quickly on almost every check.

## Destroy everything at the end of the test

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan -destroy   # review: removes CloudFront, platform IRSA, Applications, along with VPC/EKS/S3/IRSA(app)/ArgoCD — everything
AWS_PROFILE=cloudlab terraform destroy
```

⚠️ **Known risk (ADR 008, decision 15): the shared ALB may end up orphaned.** ArgoCD's Applications don't have the `resources-finalizer.argocd.argoproj.io` finalizer, so the aws-load-balancer-controller may be destroyed (along with the node group) before it manages to delete the ALB it provisioned — the `destroy` hangs with `DependencyViolation` on the subnets/IGW. If this happens:

```bash
# 1. Manually delete the orphaned ALB
aws elbv2 delete-load-balancer --load-balancer-arn "$(aws elbv2 describe-load-balancers --names minitube-app --query 'LoadBalancers[0].LoadBalancerArn' --output text)"

# 2. If the argocd namespace gets stuck in Terminating (LBC finalizers on the
#    Ingress/TargetGroupBinding, with no controller alive to remove them):
kubectl delete validatingwebhookconfigurations aws-load-balancer-webhook
kubectl delete mutatingwebhookconfigurations aws-load-balancer-webhook
kubectl patch ingress argocd-server -n argocd --type=merge -p '{"metadata":{"finalizers":[]}}'
kubectl patch targetgroupbindings.elbv2.k8s.aws -n argocd --all --type=merge -p '{"metadata":{"finalizers":[]}}'

# 3. If VPC deletion hangs on DeleteVpc (orphaned LBC security groups):
aws ec2 describe-security-groups --filters "Name=group-name,Values=k8s-*" --query "SecurityGroups[].GroupId" --output text
# for each returned GroupId:
aws ec2 delete-security-group --group-id <id>

# 4. Reapply the destroy normally
AWS_PROFILE=cloudlab terraform destroy
```

`terraform/bootstrap/` (state, ECR, **now also the Route 53 zone and the ACM certificate**) and `terraform/bootstrap-iam/` (roles, permission set, budget alert, **including the new `ManagePlatformIrsaRoles` grant**) are **not** destroyed — they persist between sessions. Confirm nothing billable is left:

```bash
aws eks list-clusters --profile cloudlab --region us-east-1
aws ec2 describe-vpcs --profile cloudlab --region us-east-1 --filters "Name=tag:Name,Values=minitube-lab"
aws ec2 describe-nat-gateways --profile cloudlab --region us-east-1 --filter "Name=state,Values=available"
aws cloudfront list-distributions --profile cloudlab --query "DistributionList.Items[].Id"
aws elbv2 describe-load-balancers --profile cloudlab --region us-east-1 --names minitube-app   # should return a "not found" error after the destroy
```

The Route 53 zone and the ACM certificate (persistent, `terraform/bootstrap/`) remain standing — this is expected and intentional, see ADR 008.

## Security / rollback

If the script is interrupted abnormally (`kill -9`) during the synthetic video upload, the port-forward may be left orphaned:

```bash
pkill -f "port-forward svc/api" || true
```

Harmless even if run unnecessarily. No other state needs manual reversion — this script does not introduce deliberate drift into the cluster (unlike `validate-argocd.sh`).

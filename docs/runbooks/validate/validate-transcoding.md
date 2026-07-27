# Runbook — Transcoding functional validation (API + transcoder)

> Establishes the "functional validation post-apply" standard described in [`docs/engineering-standards.md`](../../engineering-standards.md#11-post-apply-functional-validation). See also [`docs/adr/006-app-irsa-and-job-orchestration.md`](../../adr/006-app-irsa-and-job-orchestration.md).

## Why this exists

`kubectl apply -k gitops/app/` without error and pods `Running` prove that the manifests **exist with the expected configuration** — they do not prove that a real video can be uploaded, transcoded, and served as HLS. The question that matters: does a real upload trigger a real Job, which actually runs FFmpeg and writes readable segments to S3? This can only be answered by exercising the pipeline end to end.

This runbook documents the `terraform/envs/lab/scripts/validate-transcoding.sh` script, which generates a synthetic video with FFmpeg (without committing a binary to the repo), uploads it via `POST /api/videos`, waits for the Job to finish, and confirms the playlist + segments in S3.

## Prerequisites

### 1. IAM grant for the operator (one time, via CloudShell)

The app's IRSA role requires the day-to-day operator to gain permission to manage roles with the `minitube-app-*` prefix, and also to read/manage the cluster's OIDC provider (`aws_iam_openid_connect_provider.this`, inside `terraform/modules/eks/` since ADR 013 — existing since Phase 1, but never previously planned by the operator profile) — see the decision in [ADR 006](../../adr/006-app-irsa-and-job-orchestration.md). Without this, `terraform plan`/`apply` in `envs/lab` fails: either while trying to create `aws_iam_role.app` (first run) or, on any subsequent run, while refreshing the OIDC provider already in state (`AccessDenied` on `iam:GetOpenIDConnectProvider`).

```bash
# Root/CloudShell session, one time only
cd terraform/bootstrap-iam
terraform plan     # review: 2 new statements in the operator's inline policy (ManageAppIrsaRoles, ManageEksOidcProvider)
terraform apply
```

### 2. ECR repositories (day-to-day operator, no CloudShell)

```bash
cd terraform/bootstrap
AWS_PROFILE=cloudlab terraform plan     # review: 2 new aws_ecr_repository resources
AWS_PROFILE=cloudlab terraform apply
```

### 3. Build and push the images (manual — no CI in this phase)

```bash
account_id=$(aws sts get-caller-identity --profile cloudlab --query Account --output text)
aws ecr get-login-password --region us-east-1 --profile cloudlab | \
  docker login --username AWS --password-stdin "${account_id}.dkr.ecr.us-east-1.amazonaws.com"

docker build -t "${account_id}.dkr.ecr.us-east-1.amazonaws.com/minitube-api:v0.1.0" app/api
docker push "${account_id}.dkr.ecr.us-east-1.amazonaws.com/minitube-api:v0.1.0"

docker build -t "${account_id}.dkr.ecr.us-east-1.amazonaws.com/minitube-transcoder:v0.1.0" app/transcoder
docker push "${account_id}.dkr.ecr.us-east-1.amazonaws.com/minitube-transcoder:v0.1.0"
```

### 4. VPC + EKS + S3 bucket + IRSA role + cluster access (day-to-day operator, no CloudShell)

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan     # review: VPC+EKS (if recreating) + S3 bucket + IRSA role + policy + access entry
AWS_PROFILE=cloudlab terraform apply
```

Includes `aws_eks_access_entry`/`aws_eks_access_policy_association` (cluster-admin for `var.operator_role_arn`) — without this, `kubectl` fails authentication even with correct IAM, if the cluster was created by an identity different from the one currently running `kubectl` (see [ADR 006](../../adr/006-app-irsa-and-job-orchestration.md), item 6).

⚠️ If the `cloudlab-operator` permission set is ever recreated (a rare event), `var.operator_role_arn` in `terraform/envs/lab/variables.tf` needs to be updated — get the new ARN via `aws iam get-role --role-name AWSReservedSSO_cloudlab-operator_<hash> --query Role.Arn --output text` (CloudShell/root, read-only).

### 5. ArgoCD syncs gitops/app/ automatically

As of Phase 3, `gitops/app/` is no longer applied manually — ArgoCD (installed via `terraform/envs/lab/argocd.tf`, alongside the rest of the `apply` above) syncs it from Git. Confirm the Application is `Synced`+`Healthy` before moving on to the transcoding test:

```bash
AWS_PROFILE=cloudlab ./scripts/validate-argocd.sh
```

See [`docs/runbooks/validate/validate-argocd-gitops.md`](./validate-argocd-gitops.md) and [ADR 007](../../adr/007-argocd-gitops-bootstrap.md). No `kubectl apply -k gitops/app/` should be run from this phase onward.

## Run the test

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab ./scripts/validate-transcoding.sh
```

Dependencies in your environment: `aws` CLI, `jq`, `terraform`, `kubectl`, `curl`, `ffmpeg`.

## How it works

- Generates a synthetic 3s clip (`ffmpeg -f lavfi`) — without depending on a video file committed to the repo.
- Opens a `kubectl port-forward` to the API's Service (no Ingress/ALB yet — that's Phase 4).
- `POST /api/videos` with the clip; the API writes the raw file to `s3://<bucket>/raw/<video_id>.mp4` and creates a Job `transcode-<video_id>`.
- Polls `GET /api/videos/{video_id}` until `succeeded`/`failed` (300s timeout).
- Confirms via `aws s3api head-object`/`aws s3 ls` that `hls/<video_id>/playlist.m3u8` and at least one `.ts` segment exist.
- If the Job fails, prints the pod logs before exiting (`kubectl logs job/transcode-<video_id>`), to help with debugging.
- **Guaranteed cleanup:** `trap cleanup EXIT` kills the `port-forward` and removes the temporary video, even on failure.

## Expected output

```
PASS: API is reachable and healthy
PASS: transcode job succeeded (status=succeeded)
PASS: HLS playlist exists in S3 (hls/<video_id>/playlist.m3u8)
PASS: at least one HLS segment exists in S3 (found: 1)
=== All checks passed: a real video was uploaded, transcoded, and its HLS segments are readable in S3. ===
```

Exit code `0` when everything passes, `1` if any check fails.

## Destroy everything at the end of the test

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan -destroy   # review: VPC, EKS, S3 bucket, IRSA role — everything
AWS_PROFILE=cloudlab terraform destroy
```

`terraform/bootstrap/` (ECR) and `terraform/bootstrap-iam/` (roles, permission set, budget alert) are **not** destroyed — they persist between sessions, with no relevant cost. The ECR images also persist, so the next test session doesn't need to rebuild/repush unless the code has changed.

# Phase 2 — Application

> Phase retrospective, written at its end. Does not repeat the content of ADRs and runbooks — links to them. Serves as input for the project's final documentation (see `CLAUDE.md`, "Repository structure" section).

## Phase goal

Stand up the project's first real workload: a minimal API that receives video uploads and triggers transcoding (FFmpeg → HLS) as a Job on the ephemeral EKS cluster, writing the segments to S3. Completion criterion (`CLAUDE.md`): *"a test video transcoded and readable segments in S3"*.

## What was delivered

| Deliverable | Where it lives | Persistent or ephemeral |
| --- | --- | --- |
| Upload API (FastAPI) | `app/api/` | Persistent image (ECR); ephemeral run (Deployment in `envs/lab`) |
| Transcoder (FFmpeg → HLS) | `app/transcoder/` | Same — runs as a Job per received video |
| Video S3 bucket (`raw/` + `hls/`) | `terraform/envs/lab/s3.tf` | Ephemeral |
| Shared IRSA role (API + transcoder) | `terraform/envs/lab/iam-app.tf` | Ephemeral (coupled to the cluster's OIDC provider) |
| ECR repositories (`minitube-api`, `minitube-transcoder`) | `terraform/bootstrap/ecr.tf` | Persistent |
| Kubernetes manifests (namespace, RBAC, Deployment, Service) | `gitops/app/` | Applied manually for now (`kubectl apply -k`) |

The API creates a `batch/v1 Job` per received video — no queue/worker behind it; the raw video goes to `raw/`, the transcoder reads from there and writes `.m3u8` + `.ts` segments to `hls/<video_id>/`.

## Architecture decisions

- **[ADR 006](../adr/006-app-irsa-and-job-orchestration.md)** — the phase's central decision. Covers: where the app's IRSA role lives (in `envs/lab`, not `bootstrap-iam`, because of the coupling to the ephemeral OIDC provider — the same reasoning as ADR 004, applied to a new case); why a single role is shared by the API and transcoder; why orchestration is via a dynamic Job, not a queue; why the ECR repositories live in `bootstrap/` and not `bootstrap-iam`; and why `kubectl apply -k` is manual only until Phase 3.
- **[ADR 004](../adr/004-eks-iam-roles-and-access-mode.md)** got an update note: the original assumption that "whoever applies the Terraform automatically gets cluster admin" only holds for whoever *created* the cluster — discovered in this phase when the daily operator ran `kubectl` for the first time against a cluster created via CloudShell.

## Real bugs found and fixed

None of these showed up in an isolated local test — all only surfaced by exercising the end-to-end pipeline against real AWS, reinforcing why functional validation (`engineering-standards.md` §11) matters more than `terraform apply`/`kubectl apply` exiting without error:

1. **FFmpeg + 4:4:4 chroma.** The first test of the transcoding command failed: the test video filter (`testsrc`) generates 4:4:4 output, incompatible with H.264's `main` profile. Fixed by adding `format=yuv420p` to the filter chain — necessary anyway for broad HLS player compatibility, not just for the synthetic test.
2. **`[[ ]]` as a function argument in bash.** `[[` is a shell keyword, not a command — it can't be passed via `"$@"` to the `run_check` function. Replaced with `[ ]` (the `test` builtin, which is a real command) in the validation script.
3–5. **Three successive IAM permission gaps for the operator**, all of the same kind: `terraform plan`/`apply`/`destroy` run AWS provider checks that aren't obvious from the declared resource — refreshing every resource already in state (not just the one changing), and "related resources" checks (attached policies, instance profiles) even when none exist. Each exposed a missing IAM action: reading the OIDC provider (`iam:GetOpenIDConnectProvider` and related), reading managed policies attached to the IRSA role (`iam:ListAttachedRolePolicies`), reading instance profiles before delete (`iam:ListInstanceProfilesForRole`). All fixed as new `Statement`s in the same operator inline policy (never a new resource — the Identity Center API only accepts one inline policy per permission set).
6. **Operator `kubectl` access to the cluster.** `bootstrap_cluster_creator_admin_permissions` only grants admin to whoever actually called `CreateCluster` — in this session, CloudShell (which applied everything for the first time), not `cloudlab-operator`. Fixed with an explicit `aws_eks_access_entry`, resolved via `var.operator_role_arn` (a fixed ARN, obtained once via CloudShell — not via `data "aws_iam_session_context"`, which would in turn require yet another IAM permission over a role the project doesn't even manage).
7. **`jobs/status` as a separate RBAC subresource.** The transcoding Job finished successfully (confirmed via `kubectl logs`: FFmpeg ran, both files went to S3), but the API reported `running` forever. Cause: `read_namespaced_job_status()` hits the `/status` subresource, which requires a separate RBAC permission (`jobs/status`) that the `Role` never had — only `jobs`. Fixed by switching to `read_namespaced_job()`, which returns the same `.status` field using only the `get` permission on `jobs` already granted.
8. **`set -e`/`pipefail` masking the bug above.** The validation script's poll loop treated any non-parseable API response (including a real error, like bug 7's 403) as "still running", hiding the problem until the 300s timeout blew with no diagnostic message at all. Fixed: repeated failures (3 in a row) now abort with the raw response printed, instead of silently masking it.

## How we validated it

[`docs/runbooks/validate/validate-transcoding.md`](../runbooks/validate/validate-transcoding.md) + `terraform/envs/lab/scripts/validate-transcoding.sh`: generates a synthetic video via FFmpeg (no binary committed), sends it via `POST /videos` through a `kubectl port-forward`, waits for the Job to finish by polling `GET /videos/{id}`, and confirms via `aws s3api`/`aws s3 ls` that the playlist and at least one segment exist in the real bucket. All 4 checks passed in this phase's final validation.

## Final state of the phase

- Completion criterion met: real test video, transcoded, HLS segments confirmed in S3.
- `terraform/bootstrap/` gained 2 ECR repositories (persistent); `terraform/bootstrap-iam/` gained 3 new `Statement`s in the operator's inline policy (persistent); `terraform/envs/lab/` (VPC, EKS, video bucket, IRSA role, access entry) confirmed destroyed at the end of the session.
- PR for this phase: [`feat/phase-2-app`](https://github.com/alisson92/minitube/pull/10) *(update the link if the PR number changes)*.

## Next phase

[Phase 3 — GitOps](../../CLAUDE.md#fases-do-projeto): install ArgoCD and sync `gitops/app/` (and `gitops/platform/`) from Git — completion criterion: no manual `kubectl apply`, every deploy comes from Git. Eliminates the temporary exception recorded in ADR 006 (item 7).

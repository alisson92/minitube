# Runbook: k6 load baseline (Phase 6)

## What

`load/run-baseline.sh` runs the **first** load test of Phase 6 (`load/k6/baseline.js`) against the environment **exactly as it stands today**: API with 1 fixed replica (`gitops/app/deployment.yaml`), EKS node group fixed at 3/3/3 (`terraform/envs/lab/variables.tf`), no HPA and no Cluster Autoscaler/Karpenter.

The script ramps up a small, growing load (k6 `ramping-vus`, ~9 minutes) across two parallel scenarios, mirroring the two flows of the architecture described in `CLAUDE.md`:

- **`viewers`** — simulates the real "crowd wave": repeated requests for the HLS playlist and segments of an already-transcoded video, via CloudFront. The vast majority of these requests should terminate at the CDN.
- **`api_dynamic`** — a much smaller volume of dynamic traffic hitting the API directly (`/api/healthz`, `/api/videos/{id}`) via ALB → EKS — the single replica without autoscaling yet, the most likely candidate to saturate first.

## Why

This is deliberately the **first** test of the phase, before any mitigation (HPA, Cluster Autoscaler, adjusting the SLO in `slo-rules.yaml`). Adding a mitigation before having real data would be a bet, not an informed decision — see the "logical sequence" section agreed with the operator for this phase. The result of this script decides:

1. Whether the bottleneck is at the **pod** level (CPU/memory of the API's single replica) or the **node group** level (cluster capacity) — this determines whether the answer is HPA (cheap) or Cluster Autoscaler/Karpenter (more expensive).
2. Whether the 500ms threshold in `slo-rules.yaml` (an arbitrary value at the time) was realistic, too loose, or too tight — result: it was quite loose, later revised with all the data from this phase to `APILatencyWarning` (250ms) + `APILatencyCritical` (800ms).

Bulk upload/transcoding is **not** part of this baseline — spinning up several concurrent transcoding Jobs is a separate, heavier stress scenario, not a small/growing load.

## How

```bash
AWS_PROFILE=cloudlab ./load/run-baseline.sh
```

Prerequisites: `k6`, `aws`, `jq`, `terraform`, `kubectl`, `curl`, `ffmpeg` in the PATH; `terraform apply` already ran in `terraform/envs/lab` and ArgoCD already synced `gitops/app/` (see `docs/runbooks/validate/validate-transcoding.md`).

The script:

1. Reads the Terraform outputs (`app_url`, bucket name, cluster name).
2. Looks for an already-transcoded video in S3 (`hls/*/playlist.m3u8`); if none is found, it uploads a synthetic video via `POST /api/videos` and waits for the transcoding Job to finish — the same pattern already used in `validate-transcoding.sh`/`validate-cloudfront-dns-tls.sh`.
3. Runs `k6 run load/k6/baseline.js` against the public URL (`app.<domain>`), with the found/generated `video_id`.

## How to read the result

The k6 summary at the end shows, per `endpoint` (tag `playlist`, `segment`, `api`):

- **`http_req_failed`** — error rate. The configured threshold (`rate<0.01`) fails `k6 run` (exit code ≠ 0) if more than 1% of requests fail in any scenario — this is the most direct signal that "something broke".
- **`http_req_duration` p95** — compare against the thresholds in `slo-rules.yaml` (`APILatencyWarning` 250ms, `APILatencyCritical` 800ms). If `endpoint:api` consistently breaches before `endpoint:playlist`/`endpoint:segment`, it's evidence that the bottleneck is the API pod, not the CDN/origin — in favor of HPA as the first mitigation.
- Cross-reference the test time with the Phase 5 dashboards in Grafana (CPU/memory saturation of the `api` pod, node saturation) to confirm whether the bottleneck was pod- or node-group-level before deciding on a mitigation.

This test **does not self-clean like the `validate-*.sh` scripts** in the sense of destroying infrastructure — it only reads/generates HTTP traffic and, absent an existing video, creates a real test video in S3 (which then counts as an "already-transcoded video" for subsequent runs). No Terraform resource is created or destroyed by this script.

## Validated result (2026-07-24)

Run against the real infra (1 API replica, node group 3/3/3, no HPA): **0% error rate** across 8733 requests, all thresholds green with comfortable headroom — p95 of 186ms (`api`), 120ms (`playlist`) and 184ms (`segment`), all well below the 500ms in `slo-rules.yaml`. Peak load: only 60 VUs (50 `viewers` + 10 `api_dynamic`), ~20 req/s total.

**This does not mean the architecture doesn't break under load — it means this baseline is too small to find out where.** The API runs `uvicorn` without `--workers` (`app/api/Dockerfile`) — a single process, under a `500m` CPU limit — but the `api_dynamic` scenario never generated enough volume to get close to that ceiling (10 VUs with 2-5s sleep between iterations = few actual requests/second against the pod). `viewers` hits CloudFront/S3, which has no reason to feel 50 VUs. Baseline **confirmed stable under light load**; it remains recorded as-is, without scaling up — to find the real breaking point, use `docs/runbooks/load/run-k6-breakpoint.md`.

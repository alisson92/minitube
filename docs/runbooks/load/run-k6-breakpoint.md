# Runbook: k6 breakpoint test (Phase 6)

## What

`load/run-breakpoint.sh` runs `load/k6/breakpoint.js` — a **breakpoint** test, a category officially documented by k6 itself (distinct from load/soak/spike testing): deliberately scaling load until the system actually breaks, instead of validating that it holds up under a fixed number. It complements `load/run-baseline.sh` (small, fixed load, already validated stable — see `docs/runbooks/load/run-k6-baseline.md`), without replacing it: the baseline remains recorded as-is, this is a new, separate test.

The target is the API path (`/api/healthz`, `/api/videos/{id}` via ALB → EKS) — the single replica with no HPA, the most likely candidate to break first (see the baseline result: `uvicorn` without `--workers`, `500m` CPU limit, never truly stressed). `viewers` traffic (CloudFront/S3) is included only as a small, constant background (10 VUs), not as a target — CDN/S3 is not what this test is trying to break.

## Why

Central difference from the baseline: **open model, not closed**. `load/k6/baseline.js` uses `ramping-vus` (closed model) — each VU only makes its next request after the previous one responds, so if the system slows down, actual demand drops along with it (the queue stays invisible). `load/k6/breakpoint.js` uses `ramping-arrival-rate` (open model) — it fires requests at a target rate (req/s) regardless of response time, so queues and errors really show up in the metrics when the system can't keep up. This is k6's official recommendation for this type of test.

The thresholds here **do not** protect an SLO — they exist only to detect breakage and abort (`abortOnFail`, `delayAbortEval: 10s`) as soon as:
- `http_req_failed` exceeds 5% (much more tolerant than the baseline's `<1%` — here we want to let it degrade until it hurts, not until the first hiccup).
- `http_req_duration{endpoint:api}` p95 exceeds 1s.

Without `abortOnFail`, the test would run its full duration blindly against an already-broken target, wasting time and possibly worsening a real incident in progress.

## How

```bash
AWS_PROFILE=cloudlab ./load/run-breakpoint.sh
```

Scale the ceiling between runs (without editing code):

```bash
PEAK_RATE=800 AWS_PROFILE=cloudlab ./load/run-breakpoint.sh
```

`PEAK_RATE` (default `400` req/s) is the top of the 6-stage ramp (~17 min): `5% → 12.5% → 25% → 50% → 100% → 100%` of the `PEAK_RATE` value, sustained for the last 5 minutes. `preAllocatedVUs`/`maxVUs` scale up automatically along with it.

Prerequisites: the same as the baseline (`k6`, `aws`, `jq`, `terraform`, `kubectl`, `curl`, `ffmpeg` in the PATH; `terraform apply` already ran; ArgoCD synced). The script reuses the same "find or create test video" logic (`load/lib/find-or-create-video.sh`), shared with `run-baseline.sh`.

## How to read the result

- **Aborted before the end (`abortOnFail`)?** We found the breaking point — k6 prints at which stage/instant the threshold was breached. This is the data that was missing to decide between HPA and Cluster Autoscaler/Karpenter (cross-reference with the Phase 5 dashboards: CPU saturation of the `api` pod vs. node saturation at the exact moment of the abort).
- **Completed the ~17 minutes without aborting?** The system held up to `PEAK_RATE` req/s. That's not the real ceiling yet — rerun with a higher `PEAK_RATE` (doubling is a reasonable step: 400 → 800 → 1600...) until you find the breakage.
- Always cross-reference with Grafana/Prometheus at the exact test time, not just the k6 summary — k6 shows the client-side symptom, the dashboard shows the cause (CPU, memory, throttling, replicas).

Same note as the baseline: this script does not self-clean like the `validate-*.sh` scripts in the sense of destroying infrastructure — it only generates HTTP traffic and, if needed, creates a real test video in S3.

## After finding the breaking point

This runbook only discovers where the breakage happens — the decision on which mitigation to apply (HPA vs. Cluster Autoscaler/Karpenter) and adjusting the 500ms threshold in `slo-rules.yaml` remain the next steps agreed with the operator, not part of this script.

## Run result (2026-07-24) — aborted early, but not due to capacity

Run with `PEAK_RATE=400` (default) against the real infra, resuming the session after a power outage (environment checked healthy before running: valid SSO session, `terraform plan` with no drift, cluster/node group `ACTIVE`, all 9 ArgoCD Applications `Synced`/`Healthy`).

`k6 run` aborted (`abortOnFail`) at ~82s — still in the first stage of the ramp (~14 VUs, ~85 req/s peak, **9% of the first 5% step of `PEAK_RATE`**). This alone is already the first sign that neither the API nor the node group had saturated: the load never got close to any capacity ceiling.

**Root cause confirmed: not a capacity issue, it's a correctness bug exposed by the test.** `GET /api/videos/{video_id}` (`app/api/jobs.py::get_job_status`) uses the Kubernetes `batch/v1 Job` as the sole source of truth about the video. That Job is created with `ttl_seconds_after_finished=3600` — after that 1h following completion, Kubernetes itself garbage-collects the object (`kubectl get job transcode-<id>` → `NotFound`, confirmed after the test). The video reused by `load/lib/find-or-create-video.sh` (`4228cdfc6c57409ebe8fd6100a5ac7cb`, the same one from the baseline, run hours earlier) was already outside that window: the HLS segments remain 100% valid and servable from S3/CloudFront (the `playlist status is 200` and `segment status is 200` checks passed 100%), but the Job no longer exists — so `get_job_status` returns `"not_found"` and the API responds `404` for `/api/videos/{id}`. This isn't a failure under load: it's a legitimate (but incorrect) 404 that would happen the same way with a single user, at any time more than 1h after transcoding.

Evidence in the `api` pod logs (`kubectl logs -n minitube-app deploy/api --since-time=...`, exact test window): 100% of `GET /api/healthz` → `200`; 100% of `GET /api/videos/4228cdfc6c57409ebe8fd6100a5ac7cb` → `404`. `http_req_duration{endpoint:api}` p95 = 176.89ms — nowhere near the 1s threshold — reinforcing that the response was wrong and fast, not slow/saturated. Reason the baseline (run earlier, against the same still-"fresh" video) didn't hit this: it ran within the Job's 1h TTL window.

**Second-order root cause, in the test script itself:** `load/lib/find-or-create-video.sh` only checks whether `hls/*/playlist.m3u8` exists in S3 — it never checks whether the corresponding Job still exists in the cluster. It works for finding "an already-transcoded video" but doesn't guarantee that `GET /api/videos/{id}` will respond `200` for it.

**Conclusion: this run did not find the capacity breaking point — it found that the test, as it stands, is invalid against a video reused after more than 1h.** No mitigation (HPA, Cluster Autoscaler) was decided or applied based on this result; there is still no real capacity data.

### Open items (operator decision) — resolved in the following session

1. ~~**Real bug in the API**~~ — fixed: `get_job_status` (`app/api/jobs.py`) now falls back to `s3_client.hls_playlist_exists()` (new helper, `head_object` on `hls/<id>/playlist.m3u8`) when the Job is not found, instead of responding `not_found` directly. S3 becomes the durable source of truth; the Job remains the source of truth only while it still exists (to distinguish `running`/`failed`). Published as `minitube-api:v0.1.4`.
2. ~~**Breakpoint test pending**~~ — rerun after the fix. See section below.

## Run result (2026-07-24, post-fix) — real capacity finding, not CPU/memory

Rerun with `PEAK_RATE=400` (default) against the real infra, image `minitube-api:v0.1.4` (with the Job TTL fix) published via GitOps — ArgoCD temporarily pointed at the `feat/k6-baseline-scenario` branch (`terraform apply -var argocd_gitops_revision=...`, same pattern as ADR 007 decision 5), Application `app` `Synced`/`Healthy` at the fix commit's revision. Validated in isolation **before** k6: `GET /api/videos/4228cdfc6c57409ebe8fd6100a5ac7cb` (the same "old" video that previously returned 404) went back to responding `200`/`succeeded`.

`k6 run` aborted again (`abortOnFail`), this time at ~91s — still early (only ~22-24 VUs, ~63 req/s), but **for a genuinely different reason**:

- `http_req_failed`: **0.00%** (5724 of 5724 requests successful) — `video status is 200` now passes 100%, confirming the fix eliminated the TTL bug.
- `http_req_duration{endpoint:api}`: `p(95)=1s` — breached the threshold (`p(95)<1000`), with `max=7.54s`. Latency, not errors, is what aborted the test this time.

**I ruled out pod/node capacity as the cause before concluding anything** — I cross-referenced the exact test time (20:44:19–20:46:00 UTC) with Prometheus (`kube-prometheus-stack`, Phase 5) via `container_cpu_usage_seconds_total`/`container_memory_working_set_bytes` for the `api` pod:
- CPU: peak of **~0.083 cores** (8.3% of the `500m` limit).
- Memory: peak of **~102 MB** (40% of the `256Mi` limit).

In other words, **the pod never got close to saturating CPU or memory** while latency had already breached the 1s SLO — the answer to the baseline's original question ("is the bottleneck at the pod or node-group level?") is **neither**. The node group (headroom confirmed in Phase 5, 3× `t3.medium`) wasn't even thoroughly assessed because the pod itself already ruled out the resource hypothesis.

`argocd_gitops_revision` reverted to `main` (default) at the end of this validation — the override was only to test the fix before merging, not a permanent state.

## Latency investigation (2026-07-24) — the connection-pool hypothesis was ruled out by evidence

The first hypothesis recorded here ("`uvicorn` without `--workers`, sequential blocking calls to K8s/S3, `boto3`/k8s client connection pool") **was refuted by data**, before any code was changed based on it. Two independent sources, in the exact test window (20:44:19–20:46:05 UTC), show that processing inside the API was never slow:

- **`http_request_duration_seconds`** (a metric from `prometheus-fastapi-instrumentator` itself, via Prometheus): of the 842 requests to `/api/videos/{video_id}` in the window, **100% completed in ≤ 0.5s** (99.6% in ≤ 0.1s). Zero internal requests exceeded 1s — the two synchronous calls (K8s API + S3 fallback) never took as long as k6 measured.
- **`TargetResponseTime`** (CloudWatch, `AWS/ApplicationELB` — AWS's own metric, not ours): p95 ≤ 37ms, p99 ≤ 84ms, **absolute maximum of 145ms** in any 30s window of the test.

In other words: neither the pod nor the ALB→pod hop comes close to what k6 reported (`p95=1s`, `max=7.54s`). The latency is being added somewhere between the k6 client (running locally via WSL2, on the operator's machine) and the ALB.

**Four short (90s each) differential tests, isolating one variable at a time, all via CloudFront, against the same video:**

| Test | Configuration | Result |
| ----- | ------------- | --------- |
| 1 | `api` only, constant rate 20 req/s | p95=184ms, max=1.09s |
| 2 | `viewers`(10 VUs) + `api` together, constant rate | p95=193ms, max=945ms |
| 3 | `api` only, `ramping-arrival-rate` (5→20 over 90s) | p95=184ms, max=1.41s |
| 4 | `viewers`(10 VUs) + `api` with `ramping-arrival-rate`, **exact same sizing as the real breakpoint** (`preAllocatedVUs=100`, `maxVUs=800`) | p95=191ms, max=978ms |

**None of the four reproduced the problem** — not even the variant that exactly replicates the parameters of the first stage of the real breakpoint (test 4). This rules out, with data, the hypotheses of: constant rate vs. ramp, combined vs. isolated scenarios, and the size of k6's VU pool.

**Honest conclusion:** the latency spike (`max=7.54s` in the post-fix run) was not systematically reproduced in any tested variation, despite replicating the exact parameters of the original test. Combined with the evidence that the ALB and pod were fast during the very run that failed, the most defensible explanation is that the spike was a **transient artifact of the client→AWS path** (the operator's local network/WSL2/home internet at the exact moment of those two runs) — not a deterministic property of MiniTube nor of the k6 test design. It's notable that the two real aborts happened at similar instants (~82s and ~91s) within the ramp, which could suggest something deterministic, but no reproduction attempt (including a faithful copy of the parameters) confirmed that.

**Practical implication:** k6 running locally (WSL2, home network) is not a reliable client for measuring the real capacity ceiling via public HTTPS at this level of precision — instabilities in the client→AWS path can abort the test before any real saturation of the system happens. For a clean signal, the load generator would need to run from inside AWS (e.g., a small, ephemeral EC2 instance in the same VPC/region). **Confirmed in the following section** — this change of approach is what finally found the real breakpoint.

HPA vs. Cluster Autoscaler/Karpenter **remained without real capacity data until the EC2 run, below** — neither the result of the first post-fix breakpoint (client-side latency, not server-side) nor the differential tests (never came close to stressing anything) answered this.

## Running k6 from inside AWS (`run-breakpoint-from-ec2.sh`)

To eliminate the "client network" variable from the equation once and for all, `load/run-breakpoint-from-ec2.sh` runs the **same** `load/k6/breakpoint.js`, but the k6 process executes on an ephemeral EC2 instance inside the lab's own VPC, not on the operator's machine.

```bash
AWS_PROFILE=cloudlab ./load/run-breakpoint-from-ec2.sh
# Scale the ceiling between runs, same as the local script:
PEAK_RATE=800 AWS_PROFILE=cloudlab ./load/run-breakpoint-from-ec2.sh
```

**How it works (reuses existing infrastructure, no Terraform changes):**
- Same pattern as `terraform/envs/lab/scripts/validate-network.sh`: a `t3.small` instance (`INSTANCE_TYPE` overridable) in the private subnet, no public IP, accessed only via **SSM Session Manager/Run Command** — no SSH, no bastion.
- Same IAM instance profile as the network smoke test (`smoke_test_instance_profile_name`, only `AmazonSSMManagedInstanceCore`) — the comment itself in `terraform/bootstrap-iam/main.tf` already anticipated reuse ("reusable across future validation scripts"), so no new IAM resource was created.
- The step of finding/creating the test video (`find_or_create_test_video`) still runs **locally** (needs local `kubectl`/AWS) — only the `k6 run` itself runs on the EC2 instance. The k6 binary (same version used locally) is downloaded from the official GitHub release; the contents of `breakpoint.js` are sent base64-encoded via SSM Run Command.
- The instance is **always terminated at the end**, even on error (`trap cleanup EXIT`), same as every `validate-*.sh` script in the project.

**When to use this script instead of the local `run-breakpoint.sh`:** whenever the goal is to measure real capacity (the reason this section exists) — the local script remains valid for quick/exploratory tests where client-side network noise doesn't matter much (e.g., confirming a fix didn't break anything, as in the "post-fix" section above).

## Run result via EC2 (2026-07-25) — real breakpoint found: pod CPU, not node

Run with `PEAK_RATE=400` (default), `t3.small` instance in the private subnet, same video (`4228cdfc6c57409ebe8fd6100a5ac7cb`). This time the test **ran for ~6m32s** (versus ~82-91s for the local runs) before aborting — it reached **367 concurrent VUs** and 1,418,721 total requests before the latency threshold was breached again:

- `http_req_failed`: **0.00%** — zero errors in the entire run.
- `http_req_duration{endpoint:api}`: `p(95)=1.19s`, `max=2.95s` — breached the same threshold (`p(95)<1000`) as before, but after much more sustained load.

**This time the slowdown is real and confirmed by three independent sources, in the exact test window (~00:21:58–00:28:30 UTC, via Prometheus):**

1. **The `api` pod's CPU rises steadily and monotonically** throughout the test — from ~0.15% at rest to **~0.49 cores at 00:28:15-00:28:30, ~98% of the `500m` limit** — exactly at the moment of the abort.
2. **The API's own internal latency** (`http_request_duration_seconds`, measured inside the pod via Prometheus, not by k6) stays **stable at ~95ms p95 for over 6 minutes** and only spikes in the last ~60s: **0.48s at 00:28:30, 1s at 00:29:00** — tracking the CPU curve, not k6.
3. **Pod memory stays stable** (~100-120MB out of a `256Mi` limit, never exceeding 47%) — not the bottleneck. Zero pod restarts (no OOM/crash).
4. **CPU on the 3 nodes has ample headroom throughout the entire test** — the node hosting the `api` pod peaks at only ~35% utilization; the other two stay between 4-6%. **It's not a node capacity shortage.**

**Confirmed finding: the bottleneck is the CPU limit (`500m`) of the Deployment `api`'s single replica.** Under sustained load (saturation began around the start of the 4th ramp stage, ~6 min into the test, ~125-130 combined req/s of `/api/healthz` + `/api/videos/{id}`), `uvicorn` without `--workers` exhausts the single allocated core before any other resource (node, memory) gets anywhere near its limit.

**This overturns the premature conclusion of the earlier post-fix run** ("this result rules out CPU-based HPA") — that result came from a test that aborted too early (91s, CPU never exceeded 8.3%) due to client-side network noise, before real load got anywhere near saturating anything. With the noise removed (EC2) and the test running long enough to reach real load, **CPU is exactly the signal that rises first and in the right place (the pod, not the node)** — the simplest response (CPU-based HPA, or increasing `--workers`/the replica's CPU limit) is once again the correct candidate.

**Mitigation decision (HPA vs. Cluster Autoscaler/Karpenter) now has real data to lean on:** CPU-based HPA on the `api` pod is the indicated mitigation — the nodes have ample headroom, so Cluster Autoscaler/Karpenter wouldn't solve anything on its own here (it would only start to make sense if the HPA ever scaled replicas enough to exhaust the current 3 nodes, which is far from happening given the observed headroom).

EC2 instance terminated at the end of the test (`trap cleanup EXIT`), confirmed in the script's own log (`Cleaning up: terminating i-0af14f1a8b8316d5c`).

## Run result via EC2, post-HPA (2026-07-25) — the same test that used to abort now completes cleanly

HPA implemented (`docs/adr/012-hpa-cpu-autoscaling.md`): metrics-server via GitOps, `HorizontalPodAutoscaler` on the Deployment `api` (`minReplicas: 2`, `maxReplicas: 6`, `averageUtilization: 70` of CPU), `PodDisruptionBudget` (`minAvailable: 1`), `ignoreDifferences` on `/spec/replicas` in the `app` Application so ArgoCD's `selfHeal` stops fighting the HPA.

Reran `AWS_PROFILE=cloudlab ./load/run-breakpoint-from-ec2.sh` with **exactly the same parameters** as the previous test (`PEAK_RATE=400`, same video, same `t3.small` instance). Result:

- **The test completed the full ~17 minutes — it did not abort.** It used to abort at ~6m32s.
- `http_req_duration{endpoint:api}`: `p(95)=48.16ms` — versus `p(95)=1.19s`/`max=2.95s` before. The threshold (`p(95)<1000`) passed cleanly.
- `http_req_failed`: **0.00%** (1 isolated failure out of 4,250,363 requests — negligible noise, not a pattern).
- Total volume much higher than before, having completed the full test: 4,250,363 requests, combined peak of 4166.5 req/s (viewers + api).

**Confirmed via Prometheus, in the exact test window (~01:03–01:21 UTC), that the HPA is the cause of the improvement, not a coincidence:**
- **Replicas scaled 2 → 3 → 5 → 6** tracking aggregate CPU as it rose — reached the `maxReplicas: 6` ceiling during the peak stage (`PEAK_RATE=400` sustained) and held there.
- **Aggregate CPU across all `api` pods reached ~2.3 cores at the peak** — spread across 6 replicas (~380m each, comfortable headroom below the per-pod `limits.cpu: 500m` that used to saturate alone) — never throttled.
- CPU dropped to near zero as soon as the test ended, confirming that consumption tracked real load, not another process.

**Conclusion: the mitigation worked exactly as the previous run's data predicted.** The single-replica CPU bottleneck was resolved by spreading load across multiple replicas, within the node CPU headroom already confirmed.

**This did not find a new capacity ceiling** — it only confirmed that the previous ceiling (one replica, ~125-130 combined req/s) was comfortably surpassed at `PEAK_RATE=400`. To find the new breaking point (now limited by `maxReplicas: 6` × `500m` CPU per pod, or by some other resource not yet tested), the next step would be to scale up `PEAK_RATE` (800, then 1600...) until the test aborts again — not done in this session, remains a future candidate if the goal is to find the exact new ceiling rather than just validate the mitigation.

## Run result via EC2, `PEAK_RATE=800` (2026-07-26) — new real ceiling found: `maxReplicas: 6`, not one replica's CPU

Reran `PEAK_RATE=800 AWS_PROFILE=cloudlab ./load/run-breakpoint-from-ec2.sh` (double the previous value), same `t3.small` instance, same test video. This time the test **aborted again** — but for a genuinely different reason than the single-replica CPU bottleneck already resolved by the HPA:

- `http_req_failed`: **0.00%** (2 isolated failures out of 2,031,915 requests — negligible noise, same pattern as previous runs).
- `http_req_duration{endpoint:api}`: `p(95)=1.04s`, `max=12.94s` — breached the threshold (`p(95)<1000`) again.
- `http_reqs`: combined peak of ~3721.6 req/s (viewers + api) before the abort — the `t3.small` instance itself generated throughput far above the `PEAK_RATE=800` target (checks, iterations, and completed requests in the millions), which is already a first hint that the load generator was **not** the bottleneck this time.

**Root cause confirmed via `kubectl describe hpa` + Prometheus, collected right after the test** (replicas had already returned to `2` due to the HPA cooldown by the time of collection — that's why the instantaneous CPU/latency queries below show low values, reflecting the post-test state, not the peak):

```
Events:
  Type    Reason             Age   From                       Message
  ----    ------             ----  ----                       -------
  Normal  SuccessfulRescale  15m   horizontal-pod-autoscaler  New size: 3; ...
  Normal  SuccessfulRescale  15m   horizontal-pod-autoscaler  New size: 5; ...
  Normal  SuccessfulRescale  14m   horizontal-pod-autoscaler  New size: 6; ...
  Normal  SuccessfulRescale  3m7s  horizontal-pod-autoscaler  New size: 2; reason: All metrics below target
```

The HPA scaled 2 → 3 → 5 → **6** (its own `maxReplicas`) during the ramp and **held at 6 replicas** for several minutes, until traffic ceased (scale-down to 2, "All metrics below target", ~3 minutes before collection). This is the same scaling sequence already seen in the successful `PEAK_RATE=400` run — the difference is that, this time, the system hit the `maxReplicas: 6` ceiling and stayed there under still-growing demand, instead of stabilizing with headroom.

**Conclusion: the new real ceiling is no longer one replica's CPU (solved by the HPA) — it's the HPA's own `maxReplicas: 6`.** With 6 replicas × `limits.cpu: 500m` = 3 aggregate cores as the Deployment's physical limit, `PEAK_RATE=800` generated more demand than 3 cores can absorb, causing queuing (latency rising up to `max=12.94s`) without dropping requests (error rate stayed at 0%) — the expected behavior of a saturated but not unstable system.

**Stopped here, without scaling to `PEAK_RATE=1600`:** the stopping criterion (a clear root cause via HPA/Prometheus, or aggregate CPU at the `maxReplicas` ceiling) was already met — testing `1600` would only hit the same wall faster, without revealing new information about the current architecture. Finding the exact req/s value where degradation begins (between 400 and 800) remains a future candidate, not necessary for this phase's goal (confirming that a known ceiling exists and why).

**Practical implication for Phase 6:** `maxReplicas: 6` (ADR 012) is today a configuration decision, not a physical limitation — the 3 `t3.medium` nodes still have plenty of headroom (confirmed in previous runs). If the goal is to support more than ~800 req/s peak, the next adjustment is to raise `maxReplicas` (the node group can handle more replicas before hitting the VPC CNI's 17 pods/node limit, see ADR 011 decision 1) — not a change in autoscaling strategy.

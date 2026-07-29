# Runbook: k6 waves test (Phase 6)

## What

`load/run-waves-from-ec2.sh` runs `load/k6/waves.js` — audience rising and falling in waves ("pre-game" → "1st half" → "halftime" → "2nd half" → "goal spike" → "final whistle"), over ~23 minutes. Unlike `load/k6/baseline.js` (monotonic growth, already validated stable) and `load/k6/breakpoint.js` (ramp until breakage, no descent), this is the first scenario that **descends** on purpose — the central goal is to observe the HPA (`gitops/app/hpa.yaml`, `minReplicas: 2`/`maxReplicas: 6`) scaling **down** after a peak, not just up.

The "goal spike" stage deliberately targets close to the real ceiling already found in [`docs/runbooks/load/run-k6-breakpoint.md`](run-k6-breakpoint.md) (the `PEAK_RATE=800` run): `maxReplicas: 6` × `limits.cpu: 500m` = 3 aggregate cores, the point where latency rises (queuing) without real errors appearing. Crossing that point on purpose — and then descending — is what makes this a **recovery** test, not just another breakpoint: does latency drop back down and do replicas return to `minReplicas: 2` after the wave passes, or does something get stuck?

## Why

Neither the baseline nor the breakpoint test scale-down. `docs/adr/012-hpa-cpu-autoscaling.md` validates the HPA scaling 2→3→5→6 under sustained, growing load — never the reverse path, which is equally part of the expected behavior of an HPA in production (cost savings between peaks, not just peak absorption).

## How

```bash
AWS_PROFILE=cloudlab ./load/run-waves-from-ec2.sh
```

Scale the deliberate peak between runs (without editing code):

```bash
WAVE_PEAK_RATE=1000 AWS_PROFILE=cloudlab ./load/run-waves-from-ec2.sh
```

`WAVE_PEAK_RATE` (default `700` req/s) is the top of the "goal spike" stage — the other stages scale as a fraction of it (`pre-game` 15%, `1st half` 35%, `halftime` 5%, `2nd half` 45%, `final whistle` 3%). The total duration (~23 minutes) is fixed, regardless of the value.

Runs from inside AWS via an ephemeral EC2 instance, the same pattern as `load/run-breakpoint-from-ec2.sh` (see the "Running k6 from inside AWS" section in `run-k6-breakpoint.md` — necessary to eliminate client-side network noise, especially relevant here since the goal is to measure the exact shape of the recovery curve, not just a single peak number). Prerequisites: the same as the other scripts (`aws`, `jq`, `terraform`, `kubectl`, `curl`, `ffmpeg` in the PATH; `terraform apply` already ran; ArgoCD synced; `k6` installed remotely via SSM, not locally).

## How to read the result

Unlike the breakpoint, **this test is not expected to abort** (`abortOnFail` is not set on any threshold) — the goal is to observe the full shape of the curve, including the expected degradation at the peak. Always cross-reference with Grafana/Prometheus in the exact test window:

- **HPA replicas:** confirm 2 → 3 → 5 → 6 climbing up to the "goal spike", then **returning to 2** after the "final whistle" (`kubectl -n minitube-app get hpa api` right after the test, or the history in `kube_deployment_status_replicas{namespace="minitube-app",deployment="api"}` in Prometheus).
- **Latency (`http_req_duration{endpoint:api}`):** expected to rise during the "goal spike" (same pattern as the breakpoint's `PEAK_RATE=800`) and return to low values (~50-190ms, the range already observed in the other tests) during the "final whistle" — if it doesn't return, that's a sign something is stuck (replicas not scaling down, hanging connections).
- **Error rate:** expected to stay near 0% throughout the test, including at the peak — the saturation observed in the breakpoint is queuing/latency, not errors.
- **The "halftime" trough:** confirm the HPA doesn't scale down too early or take too long — normal HPA behavior has a stabilization window (`stabilizationWindowSeconds`, the `autoscaling/v2` default is 5 min for scale-down) that may make the halftime trough (2-3 min) not long enough for a full descent before the "2nd half" rises again — this is expected, not a bug.

## Test result (2026-07-26) — scale-down confirmed, and a real auto-recovery bug found

Run with `WAVE_PEAK_RATE=700` (default) against the real infra, via `run-waves-from-ec2.sh`.

**Central question of the test answered: yes, the HPA scales down after the peak**, confirmed by the complete event history (`kubectl -n minitube-app describe hpa api`), covering the entire test:

```
SuccessfulRescale  New size: 3   (1st half)
SuccessfulRescale  New size: 4   (2nd half)
SuccessfulRescale  New size: 5   (2nd half)
SuccessfulRescale  New size: 6   (goal spike)
SuccessfulRescale  New size: 3   (final whistle) — "All metrics below target"
SuccessfulRescale  New size: 2   (final whistle) — "All metrics below target"
```

The expected rise-and-fall pattern happened end to end, without manual intervention — the final replica count, minutes after the test, was back at `minReplicas: 2`.

**But the k6 result itself did not match the previous tests:** `http_req_failed=0.31%` (versus 0.00% in every breakpoint, including at `PEAK_RATE=800` — higher than the 700 here) and `http_req_duration{endpoint:api}` `p(95)=2.42s`, `max=27.97s`. The aggregate metric (`expected_response:true`, which mixes `api` traffic with `playlist`/`segment`) also showed `p(95)=2.25s` — but the `checks` confirm that **`playlist status is 200` and `segment status is 200` never failed**, only `healthz status is 200` and `video status is 200` did — in other words, CloudFront/S3 never degraded; the aggregate number just reflects that most of the request volume in the window was `api` traffic.

**Root cause confirmed via `kubectl get events` (does not match the behavior seen in any previous breakpoint):**

```
Warning  Unhealthy  pod/api-...  Liveness probe failed: Get "http://.../api/healthz": context deadline exceeded (Client.Timeout exceeded while awaiting headers)
Warning  Unhealthy  pod/api-...  Readiness probe failed: Get "http://.../api/healthz": context deadline exceeded ...
Normal   Killing    pod/api-...  Container api failed liveness probe, will be restarted
```

Repeated across at least 5 different pods during the "goal spike" stage. **Finding: the default `timeoutSeconds` of 1s (neither `readinessProbe` nor `livenessProbe` in `gitops/app/deployment.yaml` defined an explicit value) is too short given the real latency observed under saturation** (`p(95)=2.42s` on `endpoint:api` during the peak) — when the pod is CPU-pressured near the `maxReplicas: 6` ceiling, even `/api/healthz` (a trivial endpoint, no I/O) sometimes starts responding slower than 1s, because it competes for the same limited CPU as the process. `kubelet` then kills pods that were **overloaded, not stuck** — exactly the anti-pattern documented in Kubernetes best practices for liveness probes ("should not depend on conditions the process itself doesn't control alone, such as CPU contention"). The effect is self-amplifying: losing a pod in the middle of the peak reduces available capacity right when it's needed most, the opposite of what the HPA is trying to do.

**Fixed in `gitops/app/deployment.yaml`** (same branch/commit as this result): `readinessProbe.timeoutSeconds: 3`; `livenessProbe.timeoutSeconds: 5` + `failureThreshold: 5` (the liveness probe got the larger margin because it's the only one of the two that **kills** the container — readiness just removes it from the Service's rotation, a much less destructive action under transient overload). The values were calibrated above the worst observed `p(95)` (2.42s) with margin.

**Not revalidated in this session** — the fix has not yet been confirmed with a new run of `waves.js` (running it again costs another ~25-30 minutes). Natural candidate for the next time this scenario runs: confirm that the `Unhealthy`/`Killing` events disappear from the log during the same "goal spike".

**Conclusion for the Phase 6 final report:** this was the most valuable finding of this phase in terms of "what broke first" — it wasn't aggregate capacity (the HPA absorbed the peak and gave back capacity afterward, as expected), it was a miscalibrated probe amplifying the very saturation the HPA was trying to resolve.

## Test result (2026-07-29) — probe fix confirmed (no more kills), but a second-order gap found: `HTTPCode_ELB_5XX`

Revalidation of the 2026-07-26 probe-timeout fix (`readinessProbe.timeoutSeconds: 3`, `livenessProbe.timeoutSeconds: 5`/`failureThreshold: 5`, both in `gitops/app/deployment.yaml`), run with `WAVE_PEAK_RATE=700` (default) via `run-waves-from-ec2.sh`. Found live by the operator watching the "ALB Errors (5xx)" panel on the game-day dashboard after the fact — the panel itself only started working correctly partway through this session (see the dashboard-fix PRs, #67-#71); this result is why getting it working mattered.

**The fix held on its primary goal:** confirmed via `kubectl get events -n minitube-app`, no `Killing`/`failed liveness probe` event appears anywhere in the test window — every `Stopping container` event is 7-9 minutes after the last probe failure, timestamped with the HPA's own "final whistle" scale-down (`SuccessfulRescale ... reason: All metrics below target`), not a kill. Same k6-level result as before: `http_req_failed=0.00%` end to end (541,964 requests).

**But CloudWatch's `HTTPCode_ELB_5XX_Count` (AWS/ApplicationELB) showed something k6 never reported, because it happened at the ALB, not to any specific client request k6 was tracking as failed:** 40 errors between 04:23-04:27 UTC (01:23-01:26 -03), overlapping exactly the "goal spike" stage. `kubectl get events` in that window shows **6 distinct `api` pods** (essentially every replica active at the peak) each failing **one** `Liveness`/`Readiness` probe check within the same ~90s window (`context deadline exceeded`) — the widened `timeoutSeconds` (3s/5s) was enough to prevent a kill, but not enough to prevent a transient `Readiness` failure under this run's saturation. A `Readiness` failure pulls the pod out of the target group immediately (`kubelet` deregisters it from the Service's endpoints, which the AWS Load Balancer Controller mirrors to the ALB target group) — with most/all replicas dipping out of rotation within the same short window, the ALB briefly had too few healthy targets for the incoming request rate, and generated `5xx` itself (`ELB_5XX`, not `Target_5XX` — no target ever returned an error; some requests just arrived when there was nowhere healthy to send them).

**A second, unrelated `HTTPCode_ELB_5XX` spike (58 errors, 02:34-02:37 UTC / 23:34-23:37 -03) was also found in the same investigation, from earlier in the session:** it lines up exactly with the Grafana pod's `OOMKilled` event (fixed separately, see `gitops/platform/kube-prometheus-stack/values.yaml`'s `grafana.resources.limits.memory` history) — Grafana shares the same ALB (`IngressGroup`) as the API and ArgoCD, so while its pod was down between the OOM kill and the restart, any request to `grafana.<domain>` in that window hit the same "no healthy target" condition. Unrelated to the waves test itself, but the same failure signature (`ELB_5XX` from a target-group gap), confirming the pattern generalizes to any Ingress sharing this ALB, not just the API.

**Not fixed in this session** (cost/time budget spent; documented as the natural next step): the probe-timeout margin absorbs *sustained* saturation (prevents the kill-cascade) but not a *simultaneous* dip across every replica at the exact peak instant. Candidates for next time this scenario runs, in rough order of effort:
1. Widen `readinessProbe.timeoutSeconds` further, past the current 3s — cheapest, but only buys more margin, doesn't remove the coupling to CPU contention.
2. Add a `startupProbe` or split `/api/healthz` into a lighter/uncontended path that doesn't compete with request-handling CPU for the readiness signal specifically (liveness can stay coupled to real health; readiness removing capacity mid-peak is the more damaging half of this).
3. Raise the ALB target group's `UnhealthyThresholdCount`/lower `HealthCheckIntervalSeconds` so a single transient dip doesn't remove a target from the ALB's own view as fast — orthogonal to the Kubernetes-side probes, acts as a second line of defense.

**Conclusion:** the 2026-07-26 fix did exactly what it was designed to do (no more self-amplifying kills), and this run proves it with evidence, not assumption. The residual `ELB_5XX` at the exact peak is a smaller, second-order problem the first fix was never scoped to solve — worth carrying into a future phase, not a regression.

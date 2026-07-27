# Chaos: take down the observability stack

> **Confirmed final result: `PASS`** — see the last section ("post-fix #2") for the actual result with Prometheus/Alertmanager genuinely down. The two previous sections document bugs in the script itself, fixed along the way, not in the experiment itself.

## What

`chaos/disable-observability-stack.sh` temporarily pauses `selfHeal` on the ArgoCD Applications `kube-prometheus-stack` and `loki` (only these two — `aws-load-balancer-controller`, `external-dns`, `cert-manager` and `ebs-csi-driver` live in the same `minitube-platform` namespace, but are not touched), scales Prometheus/Alertmanager/Grafana/Loki to zero replicas, and generates real traffic against the API and the HLS playlist (via CloudFront) to confirm the application keeps serving normally with no telemetry standing at all.

## Why

Confirms contained blast radius: a failure in the observability stack cannot, by itself, be an application availability incident.

## How

```bash
AWS_PROFILE=cloudlab ./chaos/disable-observability-stack.sh
```

Optional environment variables:
- `TRAFFIC_WINDOW_SECONDS` (default 60)
- `MAX_ERROR_RATE_PERCENT` (default 0 — the expectation here is zero impact, not "acceptable")

**On pausing `selfHeal` via `kubectl patch`:** this technique was already used (and recorded in the "Current state" section of `CLAUDE.md`) during manual troubleshooting of `terraform destroy` in previous sessions. This script formalizes it as a versioned, always-reverted procedure — never a permanent change outside Git. The `trap cleanup EXIT` restores, in reverse order, first the original replicas (captured before any mutation) and only then the original `syncPolicy` of each Application, so ArgoCD doesn't kick off a sync in the middle of restoring the replicas.

**Resource discovery:** the script scales everything in `minitube-platform` **except** the platform add-ons that aren't part of this experiment (`aws-load-balancer-controller`, `external-dns`, `cert-manager*`, `ebs-csi-controller`) — an exclusion list, not an inclusion one. The first version used inclusion via `app.kubernetes.io/instance in (kube-prometheus-stack, loki)`, which covers the resources templated directly by the Helm chart (Grafana, kube-state-metrics, the operator and its webhook, Loki) but **not** the actual Prometheus/Alertmanager StatefulSet — those are created dynamically by the Prometheus Operator from the `Prometheus`/`Alertmanager` CRs, with the operator's own labeling scheme, not the Helm instance label. See "Run result" below — this gap only showed up when actually running it.

## How to read the result

- **PASS:** error rate 0% (or within the configured threshold) throughout the whole window — the API and HLS kept serving traffic with no real runtime dependency on the observability stack.
- **FAIL:** something in the application depends on the observability stack being up — investigate whether some `initContainer`/sidecar/health check of the API queries Prometheus/Loki directly (it shouldn't). **Before accepting this conclusion, confirm that Prometheus/Alertmanager were actually scaled to zero** (`kubectl -n minitube-platform get statefulset` — both should appear in the list printed under "Workloads to scale to zero") — a `FAIL` with these two still up proves nothing about blast radius, only that something else happened during the window.
- At the end, check that the stack came back: `kubectl -n minitube-platform get deploy,statefulset` — all with original replica counts, and `kubectl -n argocd get applications kube-prometheus-stack loki` back to `Synced`/`Healthy` (`selfHeal` reconciles on its own once `syncPolicy` is restored).

## Run result (2026-07-26) — real bug found and fixed

First real run: paused `selfHeal` on both Applications, discovered and scaled the 5 correct workloads to zero (`kube-prometheus-stack-grafana`, `-kube-state-metrics`, `-operator`, `-operator-webhook`, `statefulset/loki`), confirmed the `node-exporter`s (DaemonSet, out of scope) still `Running` normally — and then **silently aborted** right after opening the `port-forward` to the API, skipping the entire traffic-generation and result section. The `trap cleanup EXIT` fired and correctly restored everything (replicas and `syncPolicy` back to original) — the cleanup part worked; the measurement part didn't.

**Root cause:** the script tried to discover a `video_id` with `curl -sf GET /api/videos` (expecting a JSON list) — but `app/api/main.py` only exposes `POST /api/videos` (upload) and `GET /api/videos/{video_id}`, never a listing route. The `GET` hit `405 Method Not Allowed`, `curl -sf` returned non-zero, and under `set -euo pipefail` the script aborted at that exact point, with no visible error message (the failure was inside a command substitution).

**Fixed:** the script now reuses `load/lib/find-or-create-video.sh` (the same lib used by `run-breakpoint-from-ec2.sh`/`run-waves-from-ec2.sh`), which finds an already-transcoded video directly in S3 — without depending on any listing route that never existed.

## Run result (2026-07-26, post-fix #1) — second real bug: Prometheus/Alertmanager were never taken down

Rerun after the `video_id` fix. This time the script ran to completion and reported `FAIL`: 6 out of 32 non-200 requests (`18.75%`) in the 60s window.

**Before accepting this conclusion, I checked the list of scaled workloads in both runs (the original and this one):** it never included the Prometheus or Alertmanager StatefulSet — only `kube-prometheus-stack-grafana`, `-kube-state-metrics`, `-operator`, `-operator-webhook` and `statefulset/loki`. **Prometheus (and Alertmanager) stayed up the whole time** — the experiment never actually tested what it claims to test, so the 18.75% `FAIL` can't be attributed to "the app depends on the observability stack" without more evidence.

**Root cause:** the original discovery included by `app.kubernetes.io/instance` (Helm label), which only covers resources templated directly by the chart — the Prometheus Operator creates the actual Prometheus/Alertmanager StatefulSet dynamically from the CRs, with its own operator labels, never seen by the original query.

**Fixed:** discovery now excludes by name the add-ons that aren't part of the experiment (`aws-load-balancer-controller`, `external-dns`, `cert-manager*`, `ebs-csi-controller`) and scales **everything else** in `minitube-platform` — covering Prometheus/Alertmanager regardless of how the operator labels them. The "wait" and post-scale-down state check were also switched from a pod selector (same problem) to direct polling of `.status.replicas` on each discovered workload.

## Run result (2026-07-26, post-fix #2) — real PASS, with one side effect fixed

Rerun with exclusion-based discovery. This time `statefulset/prometheus-kube-prometheus-stack-prometheus` and `statefulset/alertmanager-kube-prometheus-stack-alertmanager` appeared in the list and were actually scaled to zero, along with Grafana/kube-state-metrics/operator/operator-webhook/Loki.

- **Total requests (API + HLS playlist):** 60 (60s window).
- **Non-200:** 0.
- **Error rate:** 0%.

`PASS`: with Prometheus and Alertmanager genuinely down (confirmed, not assumed), the API and HLS kept serving 100% of the traffic — contained blast radius, as the experiment set out to prove.

**Side effect found and fixed:** the original exclusion list didn't include `metrics-server` (a separate Application from Phase 6/ADR 012, used only by the HPA — not part of the observability stack). It was swept up by discovery by mistake, and since the script never paused `selfHeal` on its Application (only on `kube-prometheus-stack`/`loki`), ArgoCD reverted the `scale --replicas=0` on its own before the 90s wait elapsed (`WARN: deployment/metrics-server still reports 1 replica(s) after 90s`) — harmless (it should never have been touched anyway, and was never actually down), but out of the experiment's scope. Added to the exclusion list.

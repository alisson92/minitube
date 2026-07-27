# Runbook — MiniTube API incident response

**Last updated:** 2026-07-26
**Environment:** `terraform/envs/lab` (ephemeral EKS, recreated per session)
**Estimated time:** 10-30 minutes, depending on the cause
**Risk level:** Low to medium (read/triage; any permanent mitigation is just a commit in `gitops/`, never a manual `kubectl apply`/`edit`)

---

## Objective

A general guide for how to detect, triage, and mitigate an incident in the MiniTube API/HLS — not a single procedure, but the entry point that directs you to the right runbook depending on the symptom. Complements (doesn't repeat) the validation runbooks (`docs/runbooks/validate-*.md`) and the three chaos experiments already exercised (`docs/runbooks/chaos-*.md`), which document the system's *expected* behavior under each type of failure.

---

## Prerequisites

- [ ] `AWS_PROFILE=cloudlab` configured and `aws sts get-caller-identity` returning the correct identity.
- [ ] `terraform/envs/lab` applied (cluster up) — without this there's nothing to triage.
- [ ] `kubectl`, `curl`, `jq` on `PATH`.
- [ ] Access to Grafana (`https://grafana.<domain>` — password via `terraform output -raw grafana_admin_password` in `terraform/envs/lab`, see [`docs/runbooks/access-argocd-ui.md`](access-argocd-ui.md) for the equivalent ArgoCD pattern).

---

## ⚠️ Points of attention

- **Never make a permanent `kubectl apply`/`edit`/`patch` to anything managed by ArgoCD.** Any mitigation that needs to survive the next sync must become a commit in `gitops/`. An uncommitted manual change gets reverted by `selfHeal` within seconds, and masks the real symptom.
- **`kubectl scale`/`cordon`/`drain`/`delete pod` are acceptable runtime operations** even under GitOps — they don't change the declared state, only the runtime state (same reasoning as the 3 scripts in `chaos/`). Used for temporary mitigation or to reproduce a test scenario, not to fix the root cause.
- **Never generate a persistent kubeconfig.** Always `aws eks update-kubeconfig --kubeconfig <temporary file>` — the same pattern used by every script in this repository (`scripts/validate-*.sh`, `chaos/*.sh`).
- **`terraform/envs/lab` is ephemeral.** If the incident is caused by infrastructure drift (not application drift), consider whether it's worth investigating the root cause in the Terraform code instead of chasing the symptom in the current environment, which will be destroyed at the end of the session anyway.

---

## Steps

### 1. Detect

Three official signals, all defined in [`gitops/platform/kube-prometheus-stack/slo-rules.yaml`](../../gitops/platform/kube-prometheus-stack/slo-rules.yaml) (`PrometheusRule minitube-api-slo`):

```bash
# Generates an ephemeral kubeconfig (repeat in any step below that needs it)
kubeconfig=$(mktemp)
aws eks update-kubeconfig --region us-east-1 \
  --name "$(terraform -chdir=terraform/envs/lab output -raw eks_cluster_name)" \
  --kubeconfig "$kubeconfig"

# Currently active alerts
kubectl --kubeconfig "$kubeconfig" -n minitube-platform port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s http://127.0.0.1:9090/api/v1/alerts | jq '.data.alerts[] | select(.state=="firing")'
```

| Alert | Meaning | Severity |
| --- | --- | --- |
| `APIAvailabilitySLOBreach` | Fewer than 1 `api` replica available for more than 5 minutes | `critical` |
| `APILatencyWarning` | p95 of `/api*` above 250ms for more than 5 minutes — still healthy, but rising | `warning` |
| `APILatencyCritical` | p95 of `/api*` above 800ms for more than 5 minutes — likely saturation at the current HPA ceiling (`maxReplicas: 6`) | `critical` |

Complement visually: the "game day" dashboard at `https://grafana.<domain>` (CDN hit ratio, p95/p99 latency, node saturation, ALB errors — the 4 signals from Phase 5's completion criterion).

**Expected result:** an identified alert (or the absence of any alert — in which case the reported symptom may be something outside the current SLO's scope, e.g. an error perceived by the user without showing up in the monitored metrics).

---

### 2. Triage

**Application state:**

```bash
kubectl --kubeconfig "$kubeconfig" -n minitube-app get pods -o wide
kubectl --kubeconfig "$kubeconfig" -n minitube-app get hpa api
kubectl --kubeconfig "$kubeconfig" -n minitube-app describe deployment api
```

**Logs (Loki, via `port-forward`, without depending on Grafana being reachable):**

```bash
kubectl --kubeconfig "$kubeconfig" -n minitube-platform port-forward svc/loki 3100:3100 &
curl -sf http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="minitube-app"} |= "ERROR"' \
  --data-urlencode "start=$(( $(date +%s) - 900 ))000000000" | jq
```

**Metrics (Prometheus, same `port-forward` from step 1):**

```bash
# Current p95 latency per handler
curl -s http://127.0.0.1:9090/api/v1/query --data-urlencode \
  'query=histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{handler=~"/api.*"}[5m])) by (le, handler))' | jq
```

**Expected result:** a root-cause hypothesis — a specific pod with an error, CPU saturation, a problematic node, or something outside the application (DNS, cert, ALB).

---

### 3. Act / mitigate

The Troubleshooting table below maps symptom → already-exercised scenario. If the symptom matches one of the three chaos experiments, the system's *expected* behavior (and what to check if it doesn't behave that way) is already documented in the corresponding runbook — don't repeat the investigation from scratch.

**Immediate mitigation (runtime, not committed) vs. definitive fix (commit in `gitops/`):** if the action to stabilize the system is something like `kubectl delete pod` (letting the ReplicaSet recreate it) or a temporary `kubectl scale --replicas=N`, that's acceptable as a stopgap. But if the incident recurs, the real fix (a resource limit, an HPA value, a probe) needs to become a commit — never leave a manual change as the permanent solution.

---

## Post-mitigation validation

```bash
# Alerts are back to not firing
curl -s http://127.0.0.1:9090/api/v1/alerts | jq '.data.alerts[] | select(.state=="firing")'

# Application healthy
kubectl --kubeconfig "$kubeconfig" -n minitube-app get pods
curl -sf "$(terraform -chdir=terraform/envs/lab output -raw app_url)/api/healthz"
```

**Success criteria:**
- [ ] No `firing` alert on `APIAvailabilitySLOBreach`/`APILatencySLOBreach`.
- [ ] All `api` pods `Running`/`Ready`.
- [ ] `/api/healthz` responds `200` through CloudFront (not just via `port-forward`).
- [ ] If the mitigation required a permanent change: commit opened/merged in `gitops/`, `kubectl -n argocd get applications` back to `Synced`/`Healthy`.

---

## Troubleshooting

| Symptom | Likely cause | Action |
| --- | --- | --- |
| `APIAvailabilitySLOBreach` firing, few pods `Running` | Loss of one or more API pods (deploy, OOM, node) | Compare with [`docs/runbooks/chaos/chaos-kill-api-pod.md`](chaos/chaos-kill-api-pod.md) — if recovery didn't follow the expected pattern (new replica `Ready` within seconds), investigate `kubectl describe pod`/events |
| Pods mass `Pending`, nodes low on capacity | Loss of a spot node, or HPA scaling beyond the remaining nodes' capacity | Compare with [`docs/runbooks/chaos/chaos-drain-spot-node.md`](chaos/chaos-drain-spot-node.md) — check `kubectl get nodes`, whether `desired_size` (Terraform) matches the actual number of `Ready` nodes |
| `APILatencySLOBreach` firing, all replicas `Ready` | CPU saturation under load (the HPA hasn't scaled enough yet, or the real capacity ceiling has been reached) | See [`docs/runbooks/load/run-k6-breakpoint.md`](load/run-k6-breakpoint.md) for the known capacity ceiling; `kubectl top pods -n minitube-app` |
| Dashboards/alerts don't show up, but the application responds normally | Observability stack down (not, by itself, an application outage) | Compare with [`docs/runbooks/chaos/chaos-disable-observability-stack.md`](chaos/chaos-disable-observability-stack.md) — confirm the impact is really contained to telemetry, not the application |
| ArgoCD `Application` in `OutOfSync`/`Degraded` | Sync error (CRD too large, webhook, etc.) | `kubectl -n argocd get application <name> -o yaml`, check `status.conditions` — bug classes already catalogued in ADRs 007-011 |
| `/api/*` responds 502/404 only via CloudFront, but works via `port-forward` | Edge routing issue (ALB, CloudFront origin, DNS) — not an application bug | See ADR 009 (decisions 3-4) for the bug class already solved once in this architecture |

---

## References

- [`gitops/platform/kube-prometheus-stack/slo-rules.yaml`](../../gitops/platform/kube-prometheus-stack/slo-rules.yaml) — definition of the two alerts.
- [`docs/runbooks/chaos/chaos-kill-api-pod.md`](chaos/chaos-kill-api-pod.md), [`chaos-drain-spot-node.md`](chaos/chaos-drain-spot-node.md), [`chaos-disable-observability-stack.md`](chaos/chaos-disable-observability-stack.md) — exercised scenarios.
- [`docs/runbooks/load/run-k6-breakpoint.md`](load/run-k6-breakpoint.md), [`run-k6-waves.md`](load/run-k6-waves.md) — behavior under load.
- [`docs/runbooks/validate/validate-observability.md`](validate/validate-observability.md) — how to validate the observability stack from scratch.
- [`docs/adr/012-hpa-cpu-autoscaling.md`](../adr/012-hpa-cpu-autoscaling.md) — HPA sizing.
- ADRs 007-011 — catalog of real bugs already found in this architecture (ArgoCD, edge routing, observability).

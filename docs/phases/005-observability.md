# Phase 5 — Observability

> Phase retrospective, written at its end. Does not repeat the content of ADRs and runbooks — links to them. Serves as input for the project's final documentation (see `CLAUDE.md`, "Repository structure" section).
>
> **Note on this file:** written as a backfill (Phase 6), based on the "Current state" section of `CLAUDE.md` and ADR 011 — the retrospective series stopped at `003-gitops.md` and was only resumed while planning Phase 6's closeout.

## Phase goal

Install `kube-prometheus-stack` and Loki via GitOps, with latency and availability SLOs defined **before** Phase 6's load tests. Completion criterion (`CLAUDE.md`): *"'Game day' dashboard showing CDN hit ratio, p95/p99 latency, saturation, and errors"*.

## What was delivered

| Deliverable | Where it lives | Persistent or ephemeral |
| --- | --- | --- |
| `3/3/3` node sizing (no Cluster Autoscaler) | `terraform/envs/lab/variables.tf` | Ephemeral |
| EBS CSI driver (dynamic volume provisioner, previously absent) | `gitops/platform/ebs-csi-driver/` | Ephemeral |
| kube-prometheus-stack (Prometheus, Alertmanager, Grafana) | `gitops/platform/kube-prometheus-stack/` | Ephemeral |
| Loki + Promtail (single-binary, filesystem storage via PVC) | `gitops/platform/{loki,promtail}/` | Ephemeral |
| 2 new IRSA roles (`ebs-csi-driver`, `grafana` — the latter with CloudWatch read access) | `terraform/envs/lab/iam-platform.tf` | Ephemeral |
| `/metrics` instrumentation on the API (`prometheus-fastapi-instrumentator`) | `app/api/main.py`, image `v0.1.3` | — |
| `PrometheusRule` with the 2 minimum viable SLOs (availability + latency) | `gitops/platform/kube-prometheus-stack/slo-rules.yaml` | Ephemeral |
| Grafana exposed via Ingress (`grafana.<domain>`) | `gitops/platform/kube-prometheus-stack/values.yaml` + Ingress | Ephemeral |
| New `Sid AttachEbsCsiManagedPolicy` in the operator's permission set | `terraform/bootstrap-iam/main.tf` | Persistent |

## Architecture decisions (ADRs)

- **[ADR 011](../adr/011-observability-stack.md)** — the phase's central decision. Four scoping decisions closed with the operator: node sizing `min=max=desired=3` (the real bottleneck is the 17-pods-per-node limit via VPC CNI, not CPU/memory; real autoscaler deliberately deferred to Phase 6, guided by k6 load data); Loki single-binary + filesystem (not distributed + S3, no benefit in an ephemeral environment); EBS CSI driver via GitOps (not `aws_eks_addon`, keeping a single add-on mechanism); Grafana with its own IRSA and CloudWatch read access (CDN hit ratio and ALB errors only exist there, not in Prometheus — without that role the phase's completion criterion can't be met). SLO defined as "minimum viable, not elaborate": availability for free via kube-state-metrics, latency with an **arbitrary** 500ms threshold, explicitly flagged for revision with real data in Phase 6.

## Real bugs found and fixed

None of these showed up in `helm template`/`terraform validate` — only when actually syncing against the cluster:

1. **The Loki chart fails to render** if `SingleBinary` and the `SimpleScalable` mode components (`write`/`read`/`backend`) have replicas > 0 at the same time — fixed by explicitly zeroing all three.
2. **Loki 3.x requires `compactor.delete_request_store`** when retention is enabled, otherwise `loki-0` enters `CrashLoopBackOff` — cascading effect: the 3 `promtail` instances had failing readiness because they couldn't reach a Loki that was down.
3. **Prometheus Operator's admission webhook via Helm Jobs stalls ArgoCD's sync** — the hook Jobs (`admission-create`/`admission-patch`) compete with ArgoCD's sync/prune cycle. Fixed by having cert-manager (already running since Phase 4) generate the certificate internally, eliminating the Jobs.
4. **Prometheus Operator CRDs too large for *client-side apply*** — `metadata.annotations: Too long: must have at most 262144 bytes`. Fixed with `ServerSideApply=true` in that Application's `syncOptions`.
5. **The operator only discovers CRDs at startup** — since it came up before the CRDs actually existed (a side effect of live troubleshooting, with multiple partial syncs), it kept running with a stale cache even after the CRDs applied. Required a manual `kubectl rollout restart`; not necessarily a structural bug (a candidate to monitor on a clean apply from scratch).
6. **Grafana admin password regenerated on every ArgoCD sync** — the chart generates the password via `randAlphaNum` in the template itself, safe under a real `helm install`/`upgrade`, but not under ArgoCD (renders statelessly on every sync). Fixed by generating the password once in real Terraform state (`random_password.grafana_admin`), injected via `helm.parameters`.

## How we validated it

[`docs/runbooks/validate/validate-observability.md`](../runbooks/validate/validate-observability.md) + `scripts/validate-observability.sh`: PVCs `Bound` via the EBS CSI driver, Prometheus with no targets down and scraping the API itself, Grafana accessible with a working login, Loki with real logs from `promtail`. The dashboard was visually checked by the operator — the 4 signals from the phase's completion criterion (CDN hit ratio, p95/p99 latency, saturation, errors). A full `apply`→`validate`→`destroy` cycle confirmed clean via `aws ec2 describe-volumes` — the theoretical risk of an orphaned EBS volume (the same class of bug as ADR 010) **did not materialize**.

## Lessons learned

- **A complex chart's `values.yaml` can produce non-obvious side effects on ArgoCD's lifecycle** (hook Jobs, large annotations) that only show up on a real sync, never in an isolated `helm template` — reinforces, once again, "exists vs. works" (`docs/engineering-standards.md` §11).
- **Kubernetes operators that do API discovery only at startup are sensitive to CRD apply ordering** — a partial/iterative sync (common during live troubleshooting) can leave a stale cache that only a restart fixes, even with the rest of the system already correct.
- **Secrets generated by a stateless Helm template (`randAlphaNum` and the like) are incompatible with stateless reconciliation (ArgoCD)** — whenever the value needs to be stable across syncs, generate it outside the chart (Terraform, secret manager) and inject it via parameter.

## Final state of the phase

- Completion criterion met: "game day" dashboard in Grafana, visually confirmed by the operator, with the 4 required signals.
- `terraform/bootstrap-iam/` gained the `Sid AttachEbsCsiManagedPolicy` (persistent); `terraform/envs/lab/` confirmed destroyed at the end of the session, with no orphaned EBS volumes.
- PR for this phase: #18 (`feat/phase-5-observability`).

## Next phase

[Phase 6 — Game day](../../CLAUDE.md#fases-do-projeto): k6 wave scenarios, HPA (and optionally KEDA), simple chaos experiments, incident runbook — completion criterion: a final report in `docs/` with charts, what broke first, and lessons learned.

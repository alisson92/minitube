# 012 — CPU-based HPA on the `api` Deployment, metrics-server via GitOps

## Status

Accepted

## Context

`CLAUDE.md` already anticipated, in Phase 6, deciding between HPA and Cluster Autoscaler/Karpenter "guided by real k6 load" — deliberately deferred from Phase 5 (ADR 011, decision 1) so as not to be premature engineering without data.

The data arrived in this session: the breakpoint test (`load/k6/breakpoint.js`), run from inside the VPC itself via `load/run-breakpoint-from-ec2.sh` (see `docs/runbooks/load/run-k6-breakpoint.md` for why it needs to run from inside AWS — local tests via WSL2/home network aborted too early due to network noise, masking any real signal), found a genuine bottleneck confirmed by three independent sources within the same time window (Prometheus + `kube_pod_container_status_restarts_total`):

- **CPU on the `api` pod rises monotonically and saturates ~98% of `limits.cpu: 500m`** exactly when the test aborts.
- **The API's own internal latency** (`http_request_duration_seconds`, instrumented via `prometheus-fastapi-instrumentator`, measured inside the pod — not by k6) stays stable at ~95ms p95 for over 6 minutes and only spikes in the last ~60 seconds, tracking the CPU curve.
- **Memory stays stable** (~100-120MB out of a `256Mi` limit) and **the node group's 3 nodes have huge headroom** (the busiest reaches only ~35% utilization) — ruling out memory and node capacity as the cause.

In other words: the ceiling is the single replica's CPU limit, not the node group. This decides the choice between HPA and Cluster Autoscaler/Karpenter with real data, not assumption.

## Decisions

### 1. CPU-based HPA, not Cluster Autoscaler/Karpenter

Cluster Autoscaler/Karpenter would solve a lack of *node* capacity — that's not the problem found (nodes confirmed with headroom). A CPU-based HPA on the `api` Deployment attacks exactly the measured bottleneck: more replicas spread the same aggregate CPU across more pods, within nodes that already have room to spare. Cluster Autoscaler/Karpenter stays out of scope until the day the HPA scales replicas enough to exhaust the current 3 nodes — a scenario far from the observed headroom.

### 2. metrics-server via GitOps (multi-source Application), not `aws_eks_addon`

CPU-based HPA depends on the `metrics.k8s.io` API, which the cluster didn't have (confirmed: no `aws_eks_addon`, no ArgoCD Application, zero mentions in the repository before this session). Installed as another `gitops/platform/metrics-server/` subdirectory + multi-source Application, the same form already used for `aws-load-balancer-controller`/`external-dns`/`cert-manager` (Phase 4) and `ebs-csi-driver` (Phase 5) — the latter had already recorded the same justification (ADR 011, decision 3): keep a single platform add-on installation mechanism in the repository, instead of two competing mechanisms (AWS's `aws_eks_addon` vs. GitOps).

No IRSA role, no PVC, no `finalizers` — metrics-server only does local *scraping* of the nodes' own `kubelet`s, no calls to the AWS API. Same minimal form already used by `promtail` (Phase 5).

### 3. `--kubelet-insecure-tls`

The *serving* certificates of the `kubelet` on EKS-managed nodes don't carry the SANs that metrics-server's default TLS verification requires — a known gap, documented by AWS itself for this component. The alternative (setting up a dedicated CA and reissuing compatible `kubelet` certificates) is disproportionate for an ephemeral cluster, recreated from scratch every session. Accepted as the standard community trade-off: this traffic never leaves the cluster's internal control plane (private VPC, EKS security groups) — it's not an externally exposed surface.

### 4. `minReplicas: 2` / `maxReplicas: 6` / `averageUtilization: 70`

- **`minReplicas: 2`**: eliminates the single point of failure that `replicas: 1` represents today — one of this project's own mandatory alert triggers (`replicas: 1` without a PDB). Only makes sense combined with decision 5 below.
- **`maxReplicas: 6`**: ~6x the load that saturated a single replica in the real test (~125-130 combined req/s from `/api/healthz` + `/api/videos/{id}`, interpolated from the point on the ramp where CPU saturated). The node group (3× `t3.medium`, headroom confirmed by real data) has plenty of room for this without getting close to any node limit.
- **`averageUtilization: 70`**: the value consolidated as the community standard for Kubernetes. Calculated over `requests.cpu: 100m` (not the `limits.cpu: 500m` that saturates) — triggers scale-out at ~70m average usage per pod, well before any replica gets close to the limit that caused the observed degradation.

### 5. PDB (`minAvailable: 1`) included alongside the HPA, not as a separate item

No PodDisruptionBudget existed in the repository before this session (confirmed by search). Since the HPA leads the Deployment to run with multiple replicas for the first time, a minimal PDB is a direct, low-risk extension of the same work — without it, a node rotation (spot, subject to interruption) or a concurrent `rollout` could take down all replicas at once, negating the availability gain `minReplicas: 2` is meant to provide.

### 6. `ignoreDifferences` on the `/spec/replicas` field of the `app` Application

Every Application in this project runs with `syncPolicy.automated.selfHeal = true`. Without handling this, ArgoCD would revert the `api` Deployment's `spec.replicas` back to the manifest's static value on every sync, fighting the HPA (which adjusts that same field in real time via the `scale` subresource). Resolved with `ignoreDifferences` (`terraform/envs/lab/argocd.tf`, `applications.app` block) pointing at `apps/Deployment`, `name: api`, `jsonPointers: ["/spec/replicas"]` — the pattern documented by ArgoCD itself for exactly this scenario (a Deployment managed by an HPA). `gitops/app/deployment.yaml` keeps `replicas: 1` as-is, valid only as the initial count before the HPA takes over the field.

## Validation

See `docs/runbooks/load/run-k6-breakpoint.md` for the revalidation result with `load/run-breakpoint-from-ec2.sh` after this implementation — the functional test for this deliverable is the HPA scaling replicas under real load and the breakpoint rising, not just a clean `apply` and the objects existing with the right attributes (post-apply functional validation pattern, `docs/engineering-standards.md` section 11).

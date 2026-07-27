# 011 — kube-prometheus-stack, Loki, and EBS CSI driver via GitOps

## Status

Accepted

## Context

Phase 5 (Observability) of the `CLAUDE.md` table: install `kube-prometheus-stack` and Loki via GitOps, with SLOs defined before Phase 6's load tests. The documented completion criterion is explicit — "'Game day' dashboard showing CDN hit ratio, p95/p99 latency, saturation, and errors" — not a generic observability goal, and this shapes several of the decisions below (especially 5 and 6).

None of this phase's components existed before: there was no EBS CSI driver, no StorageClass, no Grafana IRSA role, and no metrics instrumentation in the API. Four scope decisions were closed with the operator before implementation; the rest were technical, discovered by checking each chart and each real file in the repository (not speculative).

## Decisions

### 1. Node sizing: `min = max = desired = 3`, no Cluster Autoscaler

The node group (`t3.medium` spot) was at `desired=2, min=1, max=3`. The real bottleneck for this phase isn't CPU/memory — there's comfortable slack even with the 4 new add-ons — it's the **17 pods/node** limit of `t3.medium` via VPC CNI IP allocation (`(3 ENIs) × (6 IPs/ENI − 1) + 2 = 17`). With this phase's add-ons, the total pod count rises considerably (ArgoCD + 3 Phase 4 add-ons + kube-system + app + now ebs-csi-driver + kube-prometheus-stack + Loki + promtail) — 2 nodes (34 slots) left no room for rolling updates or the transcoding Job.

Fixed by raising `eks_node_desired_size`/`eks_node_min_size`/`eks_node_max_size` to `3` (51 slots), keeping the same instance type (`t3.medium` spot — cheap, aligned with the project's controlled-cost principle).

**Why `min = max = desired` instead of just raising `desired`:** there is no Cluster Autoscaler or Karpenter on this cluster. Without one of these components watching `Pending` pods to decide to scale, `min_size`/`max_size` different from `desired_size` have no effect at all — they're dead configuration, just node group validation limits. Setting all three equal makes the intent explicit: today it's a static fleet of 3 nodes.

**Deliberately deferred to Phase 6:** a real cluster autoscaler, sized with real k6 load data (`CLAUDE.md` itself already anticipates HPA/KEDA in that phase) — deciding this today, without real load data, would be premature engineering.

### 2. Loki: single-binary + filesystem via PVC, not distributed + S3

Avoids a new S3 bucket and an additional IRSA role for an environment that is destroyed at the end of every session — with no practical benefit from durable storage. Requires a dynamic volume provisioner, which didn't exist on this cluster (decision 3).

Two separate official charts (`grafana/loki` + `grafana/promtail`), not `loki-stack` (legacy/deprecated upstream, without granular per-component version pinning — that would break the pattern already used throughout `variables.tf`, where each component has its own `*_chart_version`).

**Real gotcha, only exposed via `helm template`:** `deploymentMode: SingleBinary` alone doesn't zero out the *SimpleScalable* mode components (`write`/`read`/`backend`, 3 replicas by default) — the chart fails to render (`templates/validate.yaml`) if both modes have replicas > 0 simultaneously. Fixed by explicitly zeroing all three. Also required `loki.useTestSchema: true` (the chart documents this toggle as the official shortcut "for testing or playing around" when there's no real object store backend — exactly this case) instead of writing a manual `schemaConfig` with no practical benefit here.

**Pod density:** `lokiCanary`, `chunksCache`, and `resultsCache` come enabled by default (3 extra pods — a DaemonSet + 2 memcached StatefulSets) — all disabled, with no real value at a lab's query volume and 3 more pods in an already-dense node group (decision 1).

**Real bug, only exposed on the first real deploy (`helm template` doesn't catch it — it's a runtime validation, not a render one):** `loki-0` entered `CrashLoopBackOff` with `CONFIG ERROR: invalid compactor config: compactor.delete-request-store should be configured when retention is enabled`. Loki 3.x now requires an explicit *delete request store* when `compactor.retention_enabled: true` is set (decision 2 already planned for 24h retention) — just enabling the flag isn't enough. Fixed with `loki.compactor.delete_request_store: filesystem`, the same backend already used in `loki.storage.type`. Cascading effect: the 3 `promtail` pods (DaemonSet) depend on the `loki` Service to ship logs — with `loki-0` down, they kept retrying `connection refused` indefinitely; the *readiness* failure reported on them wasn't a bug of their own, just the visible consequence of this one.

### 3. EBS CSI driver via GitOps, not `aws_eks_addon`

No dynamic volume provisioner existed (confirmed: no `aws_eks_addon`, no `StorageClass`, empty grep for `ebs`/`csi`/`storageclass` across all of `terraform/envs/lab/`) — needed for Prometheus's and Loki's PVCs.

Installed as another `gitops/platform/ebs-csi-driver/` subdirectory + multi-source Application, the same mechanism already used for `aws-load-balancer-controller`/`external-dns`/`cert-manager` in Phase 4, instead of `aws_eks_addon` (the AWS-managed alternative) — keeps a single platform add-on installation pattern in the repository, instead of two competing mechanisms.

IRSA role with AWS's official **managed** policy (`AmazonEBSCSIDriverPolicy`, via `aws_iam_role_policy_attachment`), not a custom inline policy — this is the pattern documented by AWS for this specific driver, unlike the other 3 platform add-ons (all with inline policies). This required a new `Sid` (`AttachEbsCsiManagedPolicy`) in the operator permission set's single inline policy (`terraform/bootstrap-iam/main.tf`) — `ManagePlatformIrsaRoles` only covered `iam:PutRolePolicy`/`DeleteRolePolicy` (inline policy actions), not `iam:AttachRolePolicy`/`DetachRolePolicy`. Scoped by `iam:PolicyARN` to exactly this managed policy, so the grant can't be used to attach anything broader to a `platform-*` role.

Only the *controller* (which talks to the AWS API) uses the IRSA role — the *node* DaemonSet only formats/mounts locally, with no AWS calls.

### 4. Known risk, checked on the real destroy: orphaned EBS volume

Same bug class already documented 4 times for the LBC's ALB (ADR 008 items 7-9 → ADR 009 decisions 5-6 → ADR 010): deleting a `PVC` only triggers a real `DeleteVolume` if the EBS CSI driver's controller pod is still alive and authorized at that instant. The `kube-prometheus-stack` and `loki` Applications (PVC owners) gained the same `resources-finalizer.argocd.argoproj.io` finalizer already used by `app`/`platform`, and the EBS CSI driver's policy (along with Grafana's) was added to `helm_release.argocd_apps`'s `depends_on`, the same preventive treatment already given to the LBC/external-dns policy in ADR 010. **There's no guaranteed order between sibling Applications within the same `helm_release`** (the same gap that ADR 010 decision 2 fixed for the `AppProject`) — the theoretical risk was the `ebs-csi-driver` pod being removed before the other two finished pruning their PVCs.

**Checked on this phase's first real `destroy`: not confirmed.** `aws ec2 describe-volumes` filtered by `tag:kubernetes.io/created-for/pvc/name` returned no volumes — clean `destroy`, no orphans. The preventive `depends_on` (low-cost mitigation, no downside) remains in the code; no further fix was necessary.

### 5. Grafana needs its own IRSA, with read access to CloudWatch

None of this phase's other components make AWS API calls — but Phase 5's completion criterion requires CDN (CloudFront) hit ratio and, in practice, ALB errors (5xx), which are `CloudWatch` metrics, absent from Prometheus. Without this role, the phase's completion criterion simply can't be met.

Inline policy with the minimal scope documented by Grafana's CloudWatch plugin (`GetMetricData`, `GetMetricStatistics`, `ListMetrics`, `DescribeAlarmsForMetric`, `tag:GetResources`), not the `CloudWatchReadOnlyAccess` managed policy (too broad — includes Logs/X-Ray/Synthetics), keeping the least-privilege pattern already used by cert-manager/external-dns in this file. `Resource = "*"` because these read-only metrics actions don't support ARN scoping.

Service Account name explicitly pinned (`grafana`, via `grafana.serviceAccount.name` in `values.yaml`) instead of relying on the name derived from the release — same design reasoning already used for the other add-ons: the IRSA role's trust policy can't depend on a name that changes if the Application is renamed in Terraform.

### 6. The API needs to expose `/metrics` — without it there's no real p95/p99 latency

`app/api/main.py` only had `/api/healthz`, `/api/videos`, `/api/videos/{id}` (confirmed by directly reading the file before implementing) — no latency metric existed. Added `prometheus-fastapi-instrumentator` (`app/api/requirements.txt`), instrumenting `/metrics` outside the `/api` prefix on purpose: it's only scraped internally by the `ServiceMonitor` via the `ClusterIP` Service (port 8000), never passing through CloudFront/ALB (which only forward `/api/*`).

**Real dependency bug, only exposed at build time:** `prometheus-fastapi-instrumentator==8.0.2` (the latest version at implementation time) requires `starlette>=1.0.0`, but `fastapi==0.115.6` (already pinned in the project) pins `starlette<0.42.0,>=0.40.0` — `ResolutionImpossible` in `pip install`. Fixed by pinning `prometheus-fastapi-instrumentator==7.1.0` (requires `starlette<1.0.0,>=0.30.0`, compatible). Validated locally before pushing: image build, running the real server (outside the standard Docker container, which fails to import `jobs.py` outside a real Pod — pre-existing behavior, not from this change) confirming `/metrics` responding with the `http_request_duration_seconds_bucket{handler,method,le}` histogram. Image published as `v0.1.3` in ECR.

The `api` Service (`gitops/app/service.yaml`) gained a named port (`http`) — `ServiceMonitor.spec.endpoints[].port` references a port by name, not by number.

### 7. Minimum viable SLO, not an elaborate one

Availability via `kube_deployment_status_replicas_available{namespace="minitube-app", deployment="api"} < 1` — free from kube-state-metrics, with no dependency on decision 6's instrumentation. Latency via `histogram_quantile(0.95, ...)` over `http_request_duration_seconds_bucket`, with an **arbitrary** 500ms threshold (a starting point for a lab, not a validated SLA) — to be revisited with real load data in Phase 6. No saturation/error rule elaborated in this phase: node CPU/memory (node-exporter, already free) and 5xx errors (CloudWatch ALB, already covered by decision 5) are enough for the completion criterion without inventing SLOs with no real data behind them.

### 8. Grafana exposed via Ingress, `grafana.<domain>`

Already a documented target URL in the project's architecture (`CLAUDE.md`). Same pattern as `argocd.<domain>` (ADR 008): TLS via the persistent wildcard ACM certificate, same shared ALB via `IngressGroup` (`group.name: minitube`), `group.order: "15"` — between ArgoCD (`10`, host-specific) and the API catch-all (`20`) so as not to break the already-established rule evaluation priority.

### 9. Real bug: the Prometheus Operator's admission webhook via a Helm Job hangs the ArgoCD sync

The `kube-prometheus-stack Application` got stuck permanently `OutOfSync`, with no real `Prometheus`/`Alertmanager` ever getting created by the operator. `operationState.message` revealed the cause: `Resource batch/Job/kube-prometheus-stack-admission-create is missing, it might have been deleted. Retrying attempt #5`. The chart's default configuration (`prometheusOperator.admissionWebhooks.patch.enabled: true`, `deployment.enabled: false`) generates the admission webhook's TLS certificate via a pair of Helm hook Jobs (`admission-create`/`admission-patch`, with their own `hook-delete-policy`) — the chart's own `values.yaml` already comments on the need to annotate them as ArgoCD hooks (`argocd.argoproj.io/hook: PreSync`), but this isn't enabled by default. Without this annotation, ArgoCD's sync/prune cycle (plus the `retry` this project already configures for this Application, a decision analogous to Phase 4's `cert-manager`) races against the Job's own lifecycle, and ArgoCD never considers the sync complete.

Fixed by eliminating the Jobs entirely, rather than annotating them: `prometheusOperator.admissionWebhooks.certManager.enabled: true` (cert-manager, already running since Phase 4, now generates the certificate via internal, self-signed `Issuer`/`Certificate` resources, without depending on the external Let's Encrypt `ClusterIssuer`) + `patch.enabled: false` (turns off the Jobs) + `deployment.enabled: true` (the operator now serves the webhook natively via a second, persistent `Deployment`, `kube-prometheus-stack-operator-webhook`, instead of the default TLS-via-patch-Job pattern). Confirmed with `helm template`: zero `Job`s generated, 2 `Certificate`/2 `Issuer` (self-signed) in their place. Cost: +1 pod (the new webhook Deployment) — accepted, it's the price of eliminating an entire class of race condition with ArgoCD, the same cost-benefit rationale already used in previous phases' real-bug decisions.

### 10. Real bug: Prometheus Operator CRDs too large for client-side apply

Even with decision 9 applied, the `kube-prometheus-stack Application` remained `OutOfSync` — this time for a totally different reason, only visible by looking at `status.resources[].status` resource by resource (the top-level `operationState.message` isn't specific enough). The 6 Prometheus Operator CRDs (`prometheuses`, `alertmanagers`, `alertmanagerconfigs`, `prometheusagents`, `scrapeconfigs`, `thanosrulers`) failed with `metadata.annotations: Too long: must have at most 262144 bytes`, with Kubernetes's own error message already suggesting the cause and the fix: *"This error usually means that you are trying to add a large resource on client side. Consider using Server-side apply"*. *Client-side apply* (ArgoCD's default) writes the entire manifest into the `kubectl.kubernetes.io/last-applied-configuration` annotation — and these specific CRDs (Prometheus Operator's extensive OpenAPI schemas) already exceed the Kubernetes API's 256 KiB limit for any annotation. With the CRDs not applied, the `Prometheus`/`Alertmanager` resources (which depend on them) failed in cascade with `no matches for kind "Prometheus" in version "monitoring.coreos.com/v1"` — which is why no real Prometheus or Alertmanager pod ever got created by the operator, even with the operator and webhook already `Running`.

Fixed by adding `"ServerSideApply=true"` to the `kube-prometheus-stack` Application's `syncOptions` (`terraform/envs/lab/argocd.tf`) — switches the apply mechanism to Kubernetes's native *Server-Side Apply*, which doesn't depend on this annotation. No other Application in this phase needed the same treatment — only `kube-prometheus-stack` ships CRDs large enough to blow the limit.

### 11. Real bug (operational, not code): the operator only discovers CRDs at startup

Even after decisions 9 and 10 were fixed and the `Application` reported `Synced`, the `Prometheus`/`Alertmanager` (the *custom resources*, already successfully created) never got a real `StatefulSet` — `kube-state-metrics`, `grafana`, and everything else working, but no `prometheus-...-0`/`alertmanager-...-0` pod appeared, and the Application oscillated between `Progressing`/`Degraded` indefinitely. Root cause, only visible in the operator's own pod logs: it did its API capability discovery **once, at startup** (`resource "prometheuses" (group: "monitoring.coreos.com/v1") not installed in the cluster`) — and that boot happened well before the CRDs actually existed (they only started applying successfully after decision 10, minutes later). Since the operator's `Deployment` didn't change spec in any of the subsequent fixes, Kubernetes never had a reason to recreate the pod — it kept running with this stale cache indefinitely, even with the `Application` fully `Synced`.

Fixed manually with `kubectl rollout restart deployment/kube-prometheus-stack-operator` — the new pod rediscovers the API from scratch, finds the CRDs (which by then actually existed) and creates both `StatefulSet`s within seconds. **Not a code bug in this repository** — it's a side effect of this session's iterative live-debugging process (multiple partial sync attempts, each progressing a bit further than the last), not necessarily something that repeats on a clean `apply` from scratch (where, with decisions 9-10 already in code, the CRDs should apply on the first try, before or alongside the operator's Deployment, without the 10+ minute window observed here). Left as a candidate to monitor: if it reappears in a clean `destroy`→`apply` cycle, an explicit sync-wave on the CRDs (so ArgoCD waits for `Established=True` before applying the rest) would be the next step — not implemented now for lack of confirmation that the problem is structural, not just from this session.

### 12. Real bug: Grafana password regenerated on every ArgoCD sync

Even with the entire stack `Healthy`, logging into Grafana failed with the password read via `kubectl get secret kube-prometheus-stack-grafana` — even when re-reading the secret on the spot, immediately before trying. Root cause: the chart generates the Grafana admin password with a `randAlphaNum` function in the Secret's own template whenever `grafana.adminPassword` isn't set — which is safe under a real `helm install`/`upgrade` (Helm's *state* guarantees the value doesn't change on a reapply), but **not** under ArgoCD: the Application here is rendered via `helm template` statelessly, from scratch, on every sync — with no `lookup` against the Secret already existing in the cluster. Every sync in this session (and there were many, because of decisions 9-11) wrote a **new** random password into the Secret via Server-Side Apply, while the already-running Grafana pod only reads that value **once, at startup** — exactly the same "stale cache" pattern as decision 11, but for a credential instead of an API discovery. The value `kubectl get secret` shows and what's actually active in Grafana's memory silently diverge on every sync.

Fixed by generating the password once in real Terraform state (`resource "random_password" "grafana_admin"`, `terraform/envs/lab/argocd.tf`) and injecting it via `helm.parameters` (`grafana.adminPassword`) — the same mechanism already used for the other add-ons' IRSA role ARNs. Since the chart no longer generates the password on its own, the value stays stable across syncs; exposed via `terraform output -raw grafana_admin_password` (sensitive), which becomes the trustworthy source — no longer `kubectl get secret`, which only reflects this value correctly because it now never changes, not because it's the correct way to read it.

**Update (security fix):** the fix above stabilized the password, but delivered it over an insecure channel. An ArgoCD `Application`'s `helm.parameters` become part of the resource's `spec` — the ArgoCD UI masks Kubernetes Secret data by default, but does **not** mask Helm parameters in the `Application`'s own spec, so the password sat in plain text for any principal with read RBAC on that resource (`kubectl get application kube-prometheus-stack -n argocd -o yaml`, or the UI's "Parameters" panel). Unlike ArgoCD's own password — which already used `set_sensitive` **and** only passed the bcrypt hash, never the plain text (`resource "helm_release" "argocd"` in the same file). Fixed by moving the value into a `kubernetes_secret_v1.grafana_admin` managed by Terraform (in a `minitube-platform` namespace now also explicitly created by Terraform, not just via `CreateNamespace=true`), referenced by the chart via `grafana.admin.existingSecret`/`userKey`/`passwordKey` — the Application's `helm.parameters` now only carries the Secret's *name*, never the value.

## Consequences

- `terraform/bootstrap-iam/main.tf`: new `Sid AttachEbsCsiManagedPolicy` in the operator permission set's single inline policy.
- `terraform/envs/lab/variables.tf`: `3/3/3` sizing; 4 new `*_chart_version` (ebs_csi_driver, kube_prometheus_stack, loki, promtail).
- `terraform/envs/lab/iam-platform.tf`: 2 new IRSA roles (`ebs_csi_driver`, `grafana`); `terraform/envs/lab/outputs.tf`: corresponding outputs.
- `terraform/envs/lab/argocd.tf`: AppProject's `sourceRepos` +3; 4 new multi-source Applications (`ebs-csi-driver`, `kube-prometheus-stack`, `loki`, `promtail`); `helm_release.argocd_apps`'s `depends_on` extended to the 2 new IAM policies.
- `gitops/platform/{ebs-csi-driver,kube-prometheus-stack,loki,promtail}/`: new, following the per-component subdirectory pattern already established in Phase 4.
- `app/api/main.py`, `app/api/requirements.txt`, `gitops/app/service.yaml`, `gitops/app/deployment.yaml`: `/metrics` instrumentation, named port, `v0.1.3` image.
- `terraform/envs/lab/scripts/validate-observability.sh`, `docs/runbooks/validate/validate-observability.md`: new.
- Decision 4's risk (orphaned EBS volume) remains open until the first real `destroy` cycle confirms or rules it out — if confirmed, it's a candidate for its own ADR 012, following the same pattern as ADR 010.

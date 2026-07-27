# Runbook — Observability stack functional validation (Phase 5)

> Establishes the "functional validation post-apply" standard described in [`docs/engineering-standards.md`](../../engineering-standards.md#11-post-apply-functional-validation). See also [`docs/adr/011-observability-stack.md`](../../adr/011-observability-stack.md).

## Why this exists

The 4 new ArgoCD `Application`s (`ebs-csi-driver`, `kube-prometheus-stack`, `loki`, `promtail`) reporting `Synced`/`Healthy` prove the charts were installed — they do not prove the stack works end to end. The questions that matter: did the EBS CSI driver provision real volumes (PVCs `Bound`, not stuck `Pending` forever)? Does Prometheus have real scrape targets, including the API itself (instrumented in this phase)? Is Grafana publicly reachable with valid TLS? Is Loki receiving real logs, or is it just standing up with nothing arriving?

This runbook documents `terraform/envs/lab/scripts/validate-observability.sh`, which confirms each of these questions with a functional proof, not a `describe-*`/`Synced` reading.

## Prerequisites

VPC + EKS + ArgoCD + CloudFront/DNS/TLS already validated (see [`validate-eks-cluster.md`](./validate-eks-cluster.md), [`validate-argocd-gitops.md`](./validate-argocd-gitops.md), and [`validate-cloudfront-dns-tls.md`](./validate-cloudfront-dns-tls.md)) — the observability stack is just another set of `Application`s in the same `terraform apply` of `envs/lab`, nothing changes in the previous setup flow.

Dependencies in your environment: `aws` CLI, `jq`, `terraform`, `kubectl`, `curl`, `dig`.

## Apply and run the test

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform validate
AWS_PROFILE=cloudlab terraform plan     # review: node group 2->3, 2 new IRSA roles, 4 new Applications, 2 new outputs
AWS_PROFILE=cloudlab terraform apply

AWS_PROFILE=cloudlab ./scripts/validate-observability.sh
```

⚠️ **If `kube-prometheus-stack` keeps flapping between `Progressing`/`Degraded` (never `Healthy`), with the `Prometheus`/`Alertmanager` CRs existing but no real `StatefulSet` created** (see [ADR 011, decision 11](../../adr/011-observability-stack.md)): the Prometheus operator only discovers which CRDs exist **at startup** of the pod. If it came up before the CRDs (common in `apply`s with retries/live troubleshooting, not expected in a clean from-scratch `apply`), it will never recognize `Prometheus`/`Alertmanager` on its own — it needs to restart:

```bash
kubectl -n minitube-platform rollout restart deployment/kube-prometheus-stack-operator
```

The `StatefulSet`s should show up within seconds of that.

⚠️ **Give ArgoCD time before running the script.** The 4 new `Application`s (especially `kube-prometheus-stack`, which brings in Prometheus Operator CRDs) may take a few minutes to sync and become `Healthy` after the first `apply` on a fresh environment — if the script fails on the first check (PVCs `Bound`), check `kubectl -n argocd get applications` before assuming a real bug.

## How to access the Grafana UI

```bash
# via the public Ingress (same pattern as ArgoCD, ADR 008)
open "https://grafana.minitube.projetodevops.com.br"
```

User `admin`, password generated once per session by Terraform (regenerated only when `envs/lab` is recreated from scratch, **not** on every ArgoCD sync):

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform output -raw grafana_admin_password; echo
```

⚠️ **Do not use `kubectl get secret kube-prometheus-stack-grafana` for this** (see [ADR 011, decision 12](../../adr/011-observability-stack.md)) — the chart generates that password via `randAlphaNum` every time Helm renders the template, and since ArgoCD renders via `helm template` statelessly on every sync (not a real `helm upgrade`), each sync wrote a new value into the Secret while the already-running Grafana pod kept the old password in memory — the two values silently diverged. The password is now generated once, in real Terraform state, and injected via `helm.parameters`, which also keeps the Secret stable — but the source of truth is `terraform output`, not the Secret.

## How the validation script works

- **Ephemeral kubeconfig**: generated via `aws eks update-kubeconfig` in a temporary file, without writing to the operator's `~/.kube/config`.
- **Checks performed:**
  1. All PVCs in `minitube-platform` reach `Bound` (up to 300s) — proof that the EBS CSI driver (new in this phase) provisioned real EBS volumes, not just that the `StorageClass` exists as an object.
  2. Prometheus (via port-forward) reports zero `down` scrape targets — catches both a broken configuration and a forgotten `kubeScheduler`/`kubeControllerManager`/`kubeEtcd: true` (invalid on EKS, whose control plane is AWS-managed).
  3. `up{job="api"} == 1` in Prometheus — proof that the API's `/metrics` instrumentation (`app/api/main.py`) and the dedicated `ServiceMonitor` (`gitops/platform/kube-prometheus-stack/servicemonitor-api.yaml`) work end to end.
  4. Grafana responds `200` at `https://grafana.<domain>/login` — Ingress, DNS (external-dns), and TLS (wildcard ACM certificate) all working together.
  5. **Central check — real log ingestion:** the script generates real traffic against `/api/healthz`, then polls Loki (via port-forward, bypassing Grafana) until a LogQL query for `{namespace="minitube-app"}` returns lines — proof that promtail is actually reading and shipping container logs, not just that the Loki pod is `Running`.
- **Guaranteed cleanup:** `trap cleanup EXIT` kills all open `port-forward`s (Prometheus, Loki, API — Grafana doesn't use port-forward, it goes straight through the Ingress); nothing here creates drift in the cluster, no reversion is needed.

## Expected output

```
PASS: All PVCs in minitube-platform reach Bound (up to 300s)
PASS: Prometheus reports zero down scrape targets
PASS: Prometheus scrapes app/api's /metrics (up{job="api"} == 1)
PASS: Grafana UI reachable via https://grafana.minitube.projetodevops.com.br
  [  10s] still waiting: log ingestion into Loki
  [  20s] still waiting: log ingestion into Loki
PASS: Loki has log lines for namespace=minitube-app (up to 180s, promtail shipping real logs)
=== All checks passed: PVCs bound via the EBS CSI driver, Prometheus scrapes real targets including the instrumented API, Grafana is reachable, and Loki holds real logs shipped by promtail. ===
```

Exit code `0` when everything passes, `1` if any check fails.

## Visual confirmation of Phase 5's completion criterion

The script proves that the stack *works*; the phase's completion criterion (`CLAUDE.md`) requires a dashboard showing 4 specific signals — confirm manually in Grafana after the script passes:

1. **CDN hit ratio** — CloudWatch datasource, namespace `AWS/CloudFront`, metrics `Requests`/`BytesDownloaded` (or the official CloudFront dashboard, if imported).
2. **API p95/p99 latency** — Prometheus datasource, `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{handler=~"/api.*"}[5m])) by (le))`.
3. **Saturation** — Prometheus datasource, `node-exporter` metrics (CPU/memory per node).
4. **Errors** — CloudWatch datasource, namespace `AWS/ApplicationELB`, metric `HTTPCode_Target_5XX_Count`.

## Destroy everything at the end of the test

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan -destroy   # review: removes the observability stack along with VPC/EKS/S3/IRSA/ArgoCD/CloudFront -- everything
AWS_PROFILE=cloudlab terraform destroy
```

⚠️ **Theoretical risk, checked but not confirmed in the first real cycle** (see [ADR 011, decision 4](../../adr/011-observability-stack.md)): the `kube-prometheus-stack` and `loki` `Application`s (PVC owners) got the same finalizer and `depends_on` protection already used for the LBC's ALB orphan (ADR 010), but there's no ordering guarantee between sibling `Application`s within the same `helm_release` — an EBS volume could, in theory, end up orphaned if the `ebs-csi-driver` pod were removed before PVC pruning finished. It didn't happen in this phase's first real `destroy`, but worth checking again every session until the pattern proves consistent:

```bash
aws ec2 describe-volumes --profile cloudlab --region us-east-1 \
  --filters "Name=tag:kubernetes.io/created-for/pvc/name,Values=*" \
  --query "Volumes[].{Id:VolumeId,State:State}"
```

If any volume shows up with `State: available` (not attached, not deleted), that's the predicted orphan — delete it manually (`aws ec2 delete-volume --volume-id <id>`) and record the occurrence in an ADR 012, following the same root-cause pattern as ADR 010.

`terraform/bootstrap/` (ECR, Route 53, ACM, SSM) and `terraform/bootstrap-iam/` (roles, permission set, budget alert) are **not** destroyed — they persist between sessions, with no relevant cost. Confirm nothing billable is left:

```bash
aws eks list-clusters --profile cloudlab --region us-east-1
aws ec2 describe-vpcs --profile cloudlab --region us-east-1 --filters "Name=tag:Name,Values=minitube-lab"
aws ec2 describe-nat-gateways --profile cloudlab --region us-east-1 --filter "Name=state,Values=available"
aws elbv2 describe-load-balancers --profile cloudlab --region us-east-1 --names minitube-app 2>&1 | grep -q "LoadBalancerNotFound" && echo "ALB: absent (expected)"
```

# gitops/platform

This directory is continuously synced by ArgoCD through the root
`platform` Application (declared in `terraform/envs/lab/argocd.tf`, chart
`argocd-apps`), under the `AppProject minitube-platform`. As of Phase 4, it
also hosts the static `values.yaml` files consumed by dedicated Applications
(one per add-on), declared in the same `argocd.tf`.

## Contents (Phase 4 — Edge, DNS and TLS)

- **`aws-load-balancer-controller/values.yaml`**, **`external-dns/values.yaml`**,
  **`cert-manager/values.yaml`** — static values for each add-on. They are not
  valid standalone Kubernetes manifests (which is why the `platform`
  Application excludes them via `directory.exclude` instead of trying to sync
  them as resources) — they are consumed as a second `source` (`ref: values`)
  by the dedicated multi-source Applications for each add-on.
- **`cert-manager/cluster-issuer.yaml`** — the only real plain manifest in
  this phase, synced normally by the `platform` Application.
- **`argocd/ingress.yaml`** — Ingress for `argocd-server`, sharing the
  same ALB as the `gitops/app/` Ingress (same `IngressGroup`).

Architecture decisions (multi-source Application vs. Kustomize `helmCharts`,
shared IngressGroup, ClusterIssuer with no public consumer yet) in
[`docs/adr/008-cloudfront-dns-tls.md`](../../docs/adr/008-cloudfront-dns-tls.md).

## Contents (Phase 5 — Observability)

- **`ebs-csi-driver/values.yaml`** + **`storageclass.yaml`** — dynamic
  volume provisioner (`StorageClass gp3`), a prerequisite for the PVCs
  below. No IRSA for the `node` DaemonSet (it only mounts/formats locally);
  only the `controller` talks to the AWS API.
- **`kube-prometheus-stack/values.yaml`** + **`ingress.yaml`** (Grafana,
  `grafana.<domain>`) + **`servicemonitor-api.yaml`** + **`slo-rules.yaml`**
  — Prometheus, Grafana (Loki + CloudWatch datasources) and Alertmanager,
  plus the API's own scrape config and SLO alerts.
- **`loki/values.yaml`** — single-binary, filesystem storage via PVC (not
  distributed/S3 — the environment is destroyed every session, so there's
  no practical durability benefit).
- **`promtail/values.yaml`** — the collection agent that ships container
  logs to Loki; without it, Loki receives nothing on its own.

Architecture decisions (node group sizing, Loki single-binary, Grafana's
IRSA for CloudWatch, the API's `/metrics` instrumentation, EBS CSI via
GitOps) in
[`docs/adr/011-observability-stack.md`](../../docs/adr/011-observability-stack.md).

## What's coming in future phases

- **Future candidate, not decided or implemented:** migrating ArgoCD's own
  installation to *self-management* (an Application here managing ArgoCD's
  own Helm release, currently done via `helm_release` in Terraform).
  Evaluated and dropped for now — see alternatives considered in
  [`docs/adr/007-argocd-gitops-bootstrap.md`](../../docs/adr/007-argocd-gitops-bootstrap.md).
- **Future candidate, not decided or implemented:** Cluster Autoscaler or
  Karpenter, sized with real k6 load data (Phase 6) — see
  [`docs/adr/011-observability-stack.md`](../../docs/adr/011-observability-stack.md), decision 1.

## AppProject

The `AppProject minitube-platform` (which restricts the destination and
the cluster-scoped resources allowed for anything synced from this
directory) is declared via Terraform, not as a manifest in here — see
ADR 007 for the rationale (avoids the chicken-and-egg problem where the
Application syncing this path would depend on a project that would only
exist after its own first sync).

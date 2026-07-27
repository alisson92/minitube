# MiniTube 📺

[![CI](https://github.com/alisson92/minitube/actions/workflows/ci.yml/badge.svg)](https://github.com/alisson92/minitube/actions/workflows/ci.yml)

A miniature video streaming platform built end to end as a **DevOps and SRE** learning project — inspired by the question: *"how did YouTube hold up under the record simultaneous audience of CazéTV's World Cup broadcasts?"*

The short answer: edge caching, layers that filter out traffic, and an origin that scales horizontally. This project reproduces that architecture in miniature on AWS and puts it through its own "game day" load tests. The full story is in [`docs/000-motivation.md`](docs/000-motivation.md).

## Stack

| Layer | Technology |
| ------ | ---------- |
| Infrastructure as code | Terraform (remote backend in S3) |
| Orchestration | Kubernetes (EKS, spot node group) |
| Edge / CDN | CloudFront serving HLS segments from S3 |
| Video | FFmpeg (transcoding → HLS) |
| GitOps | Argo CD + Kustomize/Helm |
| DNS and TLS | Route 53, external-dns, cert-manager (own domain) |
| Observability | Prometheus, Grafana, Loki, SLOs |
| Load testing | k6 (waves simulating the crowd) |

Detailed architecture, with diagrams (network/edge, GitOps, video flow, autoscaling/observability) and the reasoning behind each choice: [`docs/architecture.md`](docs/architecture.md).

## Core principle: ephemeral infrastructure

The environment comes up (`terraform apply`), gets tested and observed, and **is destroyed at the end of every session** (`terraform destroy`) — EKS bills for the control plane even when idle. Recreating everything from scratch should be painless: that's the code's real quality test.

## Layout

```
terraform/
  bootstrap/       # versioned/encrypted S3 state bucket with native locking; ECR repositories; persistent architecture showcase site
  bootstrap-iam/   # operator permission set (cloudlab-operator, via IAM Identity Center), EKS roles, budget alert
  modules/         # vpc, eks -- reusable modules called by envs/lab
  envs/lab/        # VPC, EKS, video S3, app IAM, CloudFront, DNS
gitops/      # app manifests (Kustomize) and platform manifests (Helm via multi-source Argo CD Applications), reconciled by Argo CD
app/         # API (FastAPI) and transcoder (FFmpeg) + Dockerfiles
site/        # static architecture showcase page, served independently of envs/lab
load/        # k6 scenarios
chaos/       # chaos experiments (kill pod, drain node, take down observability)
docs/        # motivation, ADRs, runbooks, and per-phase retrospectives
Makefile     # make validate-all -- runs the 6 functional checks in order, without stopping at the first failure
.github/workflows/  # CI: fmt/validate/tflint, trivy/gitleaks, yamllint/shellcheck/ruff/links -- static checks only, no AWS credentials
```

## Getting started

The full sequence — from a blank AWS account to `app.<domain>` serving video, and back to zero at the end of the session — is in [`docs/runbooks/run-the-project.md`](docs/runbooks/run-the-project.md). After `terraform apply`, `make validate-all` runs every functional check at once (`make help` lists the individual ones).

## Status

✅ **Roadmap complete — all 6 phases closed.** Terraform foundation: remote backend, VPC, EKS with a spot node group and a budget alert ([`docs/phases/001-terraform-foundation.md`](docs/phases/001-terraform-foundation.md)). Application: API (FastAPI) + transcoder (FFmpeg) as an EKS Job, writing HLS to S3 ([`docs/phases/002-application.md`](docs/phases/002-application.md)). GitOps: Argo CD reconciling `gitops/app/` and `gitops/platform/` from Git, with zero manual `kubectl apply` ([`docs/phases/003-gitops.md`](docs/phases/003-gitops.md)). Edge/DNS/TLS: CloudFront + Route 53 + cert-manager serving `app.<domain>` over valid HTTPS ([`docs/phases/004-edge-dns-tls.md`](docs/phases/004-edge-dns-tls.md)). Observability: "game day" dashboard with CDN hit ratio, p95/p99 latency, saturation, and errors ([`docs/phases/005-observability.md`](docs/phases/005-observability.md)). Game day: k6 load tests, CPU-based HPA, and chaos experiments, with a final "what broke first" report ([`docs/phases/006-game-day.md`](docs/phases/006-game-day.md)). Further work is optional — see "Next steps" in [`CLAUDE.md`](CLAUDE.md).

Live, interactive system-design walkthrough: **[system-design.minitube.projetodevops.com.br](https://system-design.minitube.projetodevops.com.br)** — stays up even with `envs/lab` destroyed.

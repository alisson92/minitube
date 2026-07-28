# CLAUDE.md — MiniTube

> Project context for Claude Code. Read this file in full before any task.
> This is a living file: the **Current state** section is a snapshot of the present, not a session diary — the history of decisions, bugs, and retrospectives lives in `docs/adr/` and `docs/phases/`.

## What this project is

**MiniTube** is a miniature video streaming platform built end to end as a personal **DevOps and SRE** learning project. It reproduces, in miniature, the architecture that lets YouTube withstand massive events — inspired by the record simultaneous audience during the World Cup matches broadcast live by CazéTV.

The full motivation story is in [`docs/000-motivation.md`](docs/000-motivation.md). In short: understand **why** streaming architecture works at scale (edge caching, layers that filter traffic, an autoscaling origin) by building a reduced version of it and putting it through load tests — "game day."

## Learning goals

Practice, in an integrated way: **Terraform**, **Kubernetes/EKS**, **GitOps with Argo CD**, **observability** (Prometheus, Grafana, Loki, SLOs), and **reliability engineering** (load testing with k6, autoscaling, incident response).

## Non-negotiable principles

1. **Ephemeral infrastructure.** The cycle is: `apply` → test/observe → `destroy`. EKS bills for the control plane even when idle, so **no session ends with infrastructure left standing**, except for an explicit decision recorded here. Recreating the environment from scratch must be painless — if it hurts, the code isn't good enough yet.
2. **Everything is code.** Infrastructure (Terraform), deploys (GitOps manifests), budget alerts, and dashboards. No manual changes in the console — if one happens in an emergency, it must be codified right after.
3. **Continuous documentation.** Every relevant milestone creates or updates documentation in `docs/`. Architecture decisions become short ADRs (`docs/adr/`).
4. **Controlled cost.** A budget alert on the account (created via Terraform in phase 1), small spot instances, a single NAT Gateway. Estimated cost must be mentioned in the plan for any new resource.
5. **Learning before speed.** The author wants to understand every layer from the ground up. Explain the *why* before the *how*; prefer writing your own modules over copying ready-made ones when the goal is didactic.

## Target architecture

```
Viewers (k6) ──▶ CloudFront (CDN, edge cache) ──▶ S3 (HLS segments — origin)
                            │
                            └──(dynamic routes)──▶ ALB ──▶ EKS (private VPC)
                                                            ├── app: API + transcoder (FFmpeg → HLS → S3)
                                                            └── platform: Argo CD, kube-prometheus-stack, Loki
```

- **Video flow:** the transcoder reads the raw video, generates HLS variants with FFmpeg, and writes the segments to S3; CloudFront serves the segments with edge caching. The vast majority of requests should die at the CDN — hit ratio is a central metric of the project.
- **Dynamic flow:** API and pages go through the ALB to EKS.
- **DNS and TLS:** the author owns an **active custom domain**. Hosted zone in Route 53 (or a delegated subdomain), with `external-dns` publishing records and `cert-manager` issuing Let's Encrypt certificates. Target URLs: `grafana.<domain>`, `argocd.<domain>`, `app.<domain>`. The DNS zone may be the only resource persisted across sessions (low, fixed cost) — a decision recorded in an ADR in phase 4.

This block is the quick summary. Detailed diagrams (network/edge, GitOps, video flow, autoscaling/observability) and the reasoning behind each decision are in [`docs/architecture.md`](docs/architecture.md).

## Repository structure

```
minitube/
├── CLAUDE.md               # this file — context and living state
├── README.md               # overview and quick start
├── Makefile                # make validate-all — runs the 6 functional checks in order, without stopping at the first failure
├── .github/workflows/      # ci.yml — fmt/validate/tflint, security (trivy/gitleaks), lint (yaml/shell/python/markdown)
├── docs/
│   ├── 000-motivation.md   # why the project exists
│   ├── architecture.md     # diagrams and reasoning behind the target architecture
│   ├── engineering-standards.md  # reusable standards (git, gitops, iac) — imported by CLAUDE.md
│   ├── showcase-urls.md    # inventory of demoable URLs, portfolio/LinkedIn prep
│   ├── adr/                # architecture decisions (short, numbered)
│   ├── runbooks/           # bootstrap/, validate/, chaos/, load/ (by category) + access-argocd-ui.md, incident-response.md at the root
│   └── phases/             # retrospective of each completed phase, input for the project's final write-up
├── terraform/
│   ├── bootstrap/          # remote backend: S3 state bucket (versioned, with lock); ECR repositories; persistent architecture showcase site (ADR 017)
│   ├── bootstrap-iam/      # IAM roles, operator permission set, budget alert (persistent, admin-only)
│   ├── modules/            # vpc, eks — reusable modules called by envs/lab (ADR 013)
│   └── envs/lab/           # VPC, EKS, video S3, app IAM (IRSA), CloudFront, DNS
├── gitops/
│   ├── platform/           # kube-prometheus-stack, loki (Helm/Kustomize, phase 5) — Argo CD itself is installed via terraform/envs/lab/
│   └── app/                # api and transcoder (Kustomize, reconciled by Argo CD)
├── app/
│   ├── api/                # FastAPI: upload + triggers the transcoding Job
│   └── transcoder/         # FFmpeg → HLS, runs as a Kubernetes Job
├── site/
│   ├── architecture/       # static architecture showcase page, served via terraform/bootstrap/ (ADR 017) — deployed via terraform/bootstrap/scripts/deploy-architecture-site.sh
│   └── player/             # watch page (app.<domain>/?v=<video_id>), served via terraform/envs/lab/ (ADR 019) — deployed automatically by terraform apply
├── load/                   # k6 scenarios ("crowd waves")
├── chaos/                  # simple chaos experiments (phase 6)
└── scripts/                # check-markdown-links.py — used by CI and manually during reorganizations
```

## Project phases

Each phase has an explicit completion criterion. Don't move to the next phase without closing and documenting it.

| Phase | Deliverable | Completion criterion |
| ---- | ---------- | --------------------- |
| **0 — Documentation** | `docs/000-motivation.md`, `README.md`, this `CLAUDE.md` | Repository created with the documentation baseline committed |
| **1 — Terraform foundation** | Remote backend bootstrap; own VPC module (public/private subnets, 1 NAT); EKS with a spot node group; budget alert | Full `terraform destroy` followed by a clean `apply`, no manual steps |
| **2 — Application** | Minimal API + transcoding job (FFmpeg → HLS variants → S3), with Dockerfiles | A test video transcoded and readable segments in S3 |
| **3 — GitOps** | Argo CD installed; app and platform synced from `gitops/` | Zero manual `kubectl apply` — every deploy comes from Git |
| **4 — Edge, DNS, and TLS** | CloudFront in front of S3; Route 53 + external-dns + cert-manager with the custom domain | `app.<domain>` serving video via CDN with valid HTTPS; ADR on DNS zone persistence |
| **5 — Observability** | kube-prometheus-stack, Loki, dashboards; latency and availability SLOs defined **before** testing | "Game day" dashboard showing CDN hit ratio, p95/p99 latency, saturation, and errors |
| **6 — Game day** | k6 wave scenarios; HPA (optionally KEDA); simple chaos experiments; incident runbook | Final report in `docs/` with charts, what broke first, and lessons learned |

## Working conventions (for Claude Code)

- **Engineering standards:** this project fully follows @docs/engineering-standards.md (branches, commits, GitOps, IaC, security) — Claude Code imports that file automatically.
- **Language:** directory/file names, commits, branches, code, and identifiers always in **English**; documentation content (`docs/`, README, this file) also in **English**.
- **Official documentation first:** when implementing with any tool (Terraform, Kubernetes, Argo CD, CI/CD...), follow its official documentation and best-practice guides; when in doubt, check current documentation before implementing.
- **Didactic:** the author prefers understanding from the ground up. Before applying something new, briefly explain the concept and the reasoning behind the choice. Prepare well before implementing.
- **Terraform:** always a reviewed `terraform plan` before any `apply`. Never `apply -auto-approve` on new resources.
- **Destructive commands:** always dry-run or prior review (e.g., `terraform plan -destroy` before `destroy`; check the kubectl context before deleting resources).
- **Commits and branches:** Conventional Commits **in English** and trunk-based development with short branches, per `docs/engineering-standards.md` — e.g., `feat(terraform): add vpc module`, branch `feat/vpc-module`.
- **Secrets:** never commit credentials, kubeconfig, or `*.tfstate`. State lives in the remote S3 backend; ensure a proper `.gitignore` from the first commit.
- **End of session:** produce a summary of what was done; update the **Current state** section only when the snapshot actually changes (infrastructure standing, next steps) — an architecture decision becomes an ADR, a phase retrospective becomes a `docs/phases/` entry, not a new entry here. Confirm that infrastructure was destroyed (or explicitly record what was left standing and why).

## Session quick-reference runbook

**Stand up:** `cd terraform/envs/lab` → `terraform plan` (review) → `terraform apply` → validate cluster access → Argo CD syncs the rest.

**Tear down:** confirm nothing needs to persist → `terraform plan -destroy` (review) → `terraform destroy` → verify via console/CLI that no billable resources remain (EKS, NAT, ALB, EC2, EIP) → update Current state.

Full detailed sequence (including the one-time account bootstrap) in [`docs/runbooks/run-the-project.md`](docs/runbooks/run-the-project.md).

## Current state

> Snapshot of the present — not a diary. The history of decisions, real bugs, and each phase's retrospective lives in `docs/adr/` (001–017) and `docs/phases/` (001–006).

- **Roadmap complete.** All 6 phases closed and functionally validated (completion criteria met, see table above). Further work is optional, listed below.
- **Infrastructure persistent across sessions** (no meaningful cost — see ADR 001, 004, 005): S3 state bucket; IAM Identity Center (`cloudlab-operator` permission set, EKS roles, smoke-test role, budget alert) in `terraform/bootstrap-iam/`; two ECR repositories, Route 53 hosted zone, wildcard ACM certificate, the Argo CD deploy key's SSM parameter, and the architecture showcase site (S3 + CloudFront, `system-design.<domain>`, [ADR 017](docs/adr/017-persistent-architecture-showcase-site.md)) in `terraform/bootstrap/`.
- **`terraform/envs/lab/`** (VPC, EKS, video S3, Argo CD, CloudFront, observability) is ephemeral by design: comes up at the start of a session, is fully destroyed at the end, always confirmed free of orphaned resources via the AWS API directly. Current state: **destroyed**.
- **Repository organized for public release:** file/directory names standardized in English; own Terraform modules `vpc`/`eks` ([ADR 013](docs/adr/013-terraform-vpc-eks-modules.md)); `docs/runbooks/` organized by category; [`docs/runbooks/run-the-project.md`](docs/runbooks/run-the-project.md) covering the full sequence from account bootstrap to `destroy`; and full documentation translated from Portuguese to English. The repository is now public — see [`docs/showcase-urls.md`](docs/showcase-urls.md) for the demoable-URL inventory.
- **`make validate-all`** runs `envs/lab`'s 6 functional checks in dependency order, continuing past failures, with a `PASS`/`FAIL` summary and a non-zero exit code on any failure (`make help` lists individual targets, including `validate-budget` for `bootstrap-iam/`).
- **CI (`.github/workflows/ci.yml`), static checks only** (explicit decision: no AWS credentials in CI, no real `plan`/`apply`): `terraform fmt`; `validate` + `tflint` across all 5 Terraform directories (`-backend=false`); `security` (`trivy config`, `gitleaks`); `lint` (`yamllint`, `shellcheck`, `ruff`, `scripts/check-markdown-links.py`). `.trivyignore` and `.gitleaks.toml` document why each finding is accepted.
- **Next steps (optional, no formal phase attached):**
  1. Find the exact capacity ceiling beyond the already-confirmed `PEAK_RATE=800`/`maxReplicas: 6` (push further, or raise `maxReplicas`).
  2. KEDA as an alternative to CPU-based HPA.
  3. Enable CloudFront's "Additional metrics" if the dashboard's real hit ratio becomes important.

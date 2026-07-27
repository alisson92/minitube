# Phase 4 — Edge, DNS and TLS

> Phase retrospective, written at its end. Does not repeat the content of ADRs and runbooks — links to them. Serves as input for the project's final documentation (see `CLAUDE.md`, "Repository structure" section).
>
> **Note on this file:** written as a backfill (Phase 6), based on the "Current state" section of `CLAUDE.md` and ADRs 007-010 — the retrospective series stopped at `003-gitops.md` and was only resumed while planning Phase 6's closeout.

## Phase goal

CloudFront in front of S3 (HLS segments); Route 53 + `external-dns` + `cert-manager` with the operator's own domain. Completion criterion (`CLAUDE.md`): *"`app.<domain>` serving video via CDN with valid HTTPS"*.

## What was delivered

| Deliverable | Where it lives | Persistent or ephemeral |
| --- | --- | --- |
| Route 53 hosted zone (`minitube.projetodevops.com.br`) + wildcard ACM certificate | `terraform/bootstrap/dns.tf` | Persistent |
| SSM parameter for the ArgoCD deploy key | `terraform/bootstrap/ssm.tf` | Persistent |
| CloudFront (S3 default + `/api/*` → ALB) | `terraform/envs/lab/cloudfront.tf` | Ephemeral |
| 3 platform IRSA roles (aws-load-balancer-controller, external-dns, cert-manager) | `terraform/envs/lab/iam-platform.tf` | Ephemeral |
| Add-ons via ArgoCD multi-source Application | `gitops/platform/{aws-load-balancer-controller,external-dns,cert-manager}/` | Ephemeral |
| Shared Ingress (`IngressGroup`) for `app` and `argocd.<domain>` | `gitops/app/ingress.yaml`, `gitops/platform/argocd/ingress.yaml` | Ephemeral |
| `ManagePlatformIrsaRoles` IAM grant | `terraform/bootstrap-iam/main.tf` | Persistent |

## Architecture decisions (ADRs)

- **[ADR 008](../adr/008-cloudfront-dns-tls.md)** — the phase's central decision. Covers: CloudFront alias via Terraform (not `external-dns`); `argocd.<domain>` going straight to the ALB, no CDN; a single ACM certificate (`us-east-1`) for both CloudFront and ALB; a shared `IngressGroup` (a single ALB); add-ons via multi-source Application (official chart + values from the repo itself); persistence of the SSH deploy key via SSM Parameter Store (replacing the `TF_VAR` re-exported every session from ADR 007).
- **[ADR 009](../adr/009-eks-access-entries-and-api-edge-routing.md)** — pre-existing bugs from Phases 1 and 4, only exposed when testing `/api/*` through CloudFront end to end for the first time: `bootstrap_cluster_creator_admin_permissions` turned off (cluster access 100% declared by Terraform); a 30s `time_sleep` for real access-entry propagation; API routes under `/api` (an application decision, not an edge one); CloudFront origin pointing to its own Route 53 record (not the ALB's raw DNS, outside the wildcard certificate's SAN).
- **[ADR 010](../adr/010-lbc-orphan-cleanup-and-alb-wait.md)** — only closed in a following session (before Phase 5 actually started), but is technical debt originating in this phase: a `null_resource` polling the ALB before `apply` proceeds; `AppProject` in its own `helm_release`, destroyed last; `resources-finalizer.argocd.argoproj.io` finalizer on the `app`/`platform` Applications; `depends_on` covering the full network path and the LBC/external-dns IAM policies. Definitively closes the LBC orphan on `destroy` (see "Real bugs" below).

## Real bugs found and fixed

None of these showed up in `terraform plan`/`validate` — only in a real ArgoCD sync and real public requests against the domain:

1. **`AppProject.sourceRepos` didn't allow the add-ons' Helm repositories** — `InvalidSpecError`, fixed by adding the 3 chart URLs.
2. **`AppProject.destinations` didn't allow `kube-system`** — cert-manager creates leader-election RBAC there by upstream default.
3. **`aws-load-balancer-controller` can't discover the VPC ID on its own** on this cluster (IMDS fails) — fixed by injecting `vpcId` via `helm.parameters`.
4. **Inverted rule priority on the shared ALB (`group.order`)** — the `app`'s catch-all rule had higher priority than ArgoCD's host-specific rule; `argocd.<domain>` responded with the API's own 404.
5. **Access entry collision** — `bootstrap_cluster_creator_admin_permissions=true` automatically creates an access entry for whoever calls `CreateCluster`; collides with the explicit one when that identity is `cloudlab-operator`. Fixed by turning off the flag (ADR 009).
6. **Access entry propagation race** — a side effect of bug 5: the EKS API returns success before the *authorizer* actually accepts the new principal. Fixed with a 30s `time_sleep`.
7. **Public API on `/api/*` always 404** — CloudFront forwards the path without rewriting, but the API only responded to root-level routes; never detected because validation always used a direct `port-forward` to the Service. Fixed by moving the routes under `APIRouter(prefix="/api")`, with `readinessProbe`/`healthcheck-path` adjusted accordingly.
8. **CloudFront 502 on the ALB origin** — CloudFront validates the TLS hostname against the origin's `domain_name`, which pointed to the ALB's raw DNS, outside the wildcard certificate's SAN. Fixed with its own Route 53 alias (`alb-origin.<domain>`), covered by the wildcard.
9. **`terraform import` of the access entry failing because of an unrelated data source** — `terraform import` evaluates every data source in the module, including `data.aws_lb.app_shared` (which doesn't resolve in a VPC without an ALB yet). Worked around by temporarily moving `cloudfront.tf` out of the directory during the `import`.
10. **Process bug: a local session without commit/push corrupted the SSM parameter** for the deploy key — a parallel CloudShell session, with a stale checkout, saw the parameter as "in state but not in code" and destroyed it on apply. Fixed by the habit of committing/pushing the branch before requesting any Terraform operation from another environment against the same backend.
11. **`terraform destroy` leaves orphaned AWS resources when `aws-load-balancer-controller` is involved** — the ALB and 2 security groups survive the destroyed node group (`DependencyViolation`); the `argocd` namespace stuck in `Terminating` due to LBC finalizers with no live controller to remove them. Recovered manually in this phase (via `aws elbv2 delete-load-balancer` + `aws ec2 delete-security-group` + manual finalizer removal); **definitively fixed only in ADR 010**, in a following session, after reappearing 2 more times (ADR 009 decisions 5-6).

## How we validated it

[`docs/runbooks/validate/validate-cloudfront-dns-tls.md`](../runbooks/validate/validate-cloudfront-dns-tls.md) + `scripts/validate-cloudfront-dns-tls.sh`, 9 checks — the central proof: a real HLS playlist served via `https://app.minitube.projetodevops.com.br`, with CloudFront's `X-Cache` header and a TLS chain issued by Amazon. Revalidated after ADR 009 closed with a real end-to-end upload (`POST /api/videos`, transcoding, `GET /hls/<id>/playlist.m3u8` via CDN, video played back in VLC) and, again, after ADR 010, with 4 complete `apply`→`destroy` cycles from scratch.

## Lessons learned

- **`data` sources that depend on resources provisioned outside Terraform (an ALB via an in-cluster controller) expose real circular dependencies**, not capturable only by `depends_on` between Terraform resources — they need active waiting (polling) or a two-step reapply.
- **Functional validation that takes a shortcut (a direct `port-forward` to the Service) can mask real edge-routing bugs** — only testing through the full public path (CloudFront → ALB → Service) exposed bugs 7 and 8.
- **`terraform destroy` with in-cluster controllers that provision AWS resources outside Terraform (LBC) is a recurring class of risk**, not an isolated incident — motivated ADR 010 and the practice of always confirming cleanup via the direct AWS API, not just `terraform state list`.

## Final state of the phase

- Completion criterion met: `app.minitube.projetodevops.com.br` serves video via CDN with valid HTTPS.
- `terraform/bootstrap/` gained the hosted zone, the wildcard ACM certificate, and the SSM parameter (persistent); `terraform/bootstrap-iam/` gained the `ManagePlatformIrsaRoles` grant. `terraform/envs/lab/` confirmed destroyed at the end of every session in this phase.
- PRs: #12 (`feat/route53-zone-and-cert`), #13 (`feat/cloudfront-dns-tls`), #14 (`fix/eks-access-entry-and-api-healthcheck`) — plus #17 (`fix/lbc-orphan-finalizer-and-alb-wait`), which closes bug 11's technical debt in a following session, before Phase 5 effectively started.

## Next phase

[Phase 5 — Observability](../../CLAUDE.md#fases-do-projeto): kube-prometheus-stack, Loki, dashboards; latency and availability SLOs defined before Phase 6's load tests.

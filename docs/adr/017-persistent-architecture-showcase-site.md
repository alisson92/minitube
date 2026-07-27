# 017 — Persistent architecture page (`system-design.<domain>`)

## Status

Accepted

## Context

`docs/architecture.md` already existed as "base material for outreach" (see `docs/showcase-urls.md`), intended since Phase 4 to become portfolio/LinkedIn content at the end of the project (underlying decision recorded in [ADR 007](007-argocd-gitops-bootstrap.md)). The original plan was just a visually richer HTML version of these diagrams, to attach to a post.

In this session the operator proposed going further: hosting this page **persistently**, on its own subdomain (`system-design.minitube.projetodevops.com.br`), so the architecture stays browsable even with `envs/lab` destroyed — the project's normal state between sessions (`CLAUDE.md` principle 1). In other words, a showcase that survives exactly when the rest of the system isn't up to be shown live.

## Decisions

### 1. New resource in `terraform/bootstrap/`, not in `envs/lab/`

`terraform/bootstrap/` is already the place for low, fixed-cost resources that survive the ephemeral cycle — the state bucket, ECR repositories, the Route 53 hosted zone, the wildcard ACM certificate, the ArgoCD deploy key's SSM parameter ([ADR 001](001-terraform-state-backend.md), [008](008-cloudfront-dns-tls.md)). A page that needs to stay up independent of `envs/lab` belongs in the same category — this isn't a new exception to the ephemeral infrastructure principle, it's one more member of it.

### 2. Same already-validated S3 + OAC + CloudFront pattern, reused within the same state

`terraform/bootstrap/architecture-site.tf` replicates the shape of `envs/lab/cloudfront.tf` (the `s3-video` origin: private bucket, no direct public access, `Origin Access Control`, policy scoped by the distribution's `source-arn`) — already in production, with no reinventing. Only real difference: since the bucket, the distribution, and the wildcard certificate now live **in the same state**, `viewer_certificate` references `aws_acm_certificate_validation.wildcard.certificate_arn` directly, with no need for a cross-module `data source` like `envs/lab` needs.

**Discarded alternative:** GitHub Pages (or any free external hosting). Rejected because the entire needed foundation — hosted zone, wildcard certificate, the CloudFront+S3+OAC pattern itself — already exists, is already tested in production, and is already this repository's code; introducing a new hosting platform just for this page would add an unnecessary external dependency, against the project's didactic goal (learning by building, not outsourcing the part you already know how to do).

### 3. Content outside Terraform

The HTML/CSS/JS (`site/architecture/index.html`) is a static file versioned in the repository, **not** an `aws_s3_object` managed by Terraform — synced to the bucket by `terraform/bootstrap/scripts/deploy-architecture-site.sh` (`aws s3 sync` + CloudFront invalidation), run manually whenever the content changes. Keeps `bootstrap/`'s `apply` (an infrastructure resource, touched rarely) decoupled from content/design tweaks (expected more frequently during the outreach phase).

### 4. Self-contained page, no external CDN dependency

`site/architecture/index.html` is a single file with inline CSS/JS, with no `<script src>`/`<link>` to external resources (no web font, no chart library) — the 4 diagrams from `docs/architecture.md` were redesigned as custom HTML/CSS components (not Mermaid's default rendering), styled for the page's visual theme instead of inheriting Mermaid's generic palette. Goal: robustness and load speed for a public page that any LinkedIn visitor might open at any time, without depending on third-party availability.

**Single (dark) theme, deliberate:** the page embraces the visual concept of a night-game broadcast, under floodlights — a light theme would misrepresent the core idea itself, not just the palette. Documented as a conscious choice in the file itself (a comment in the `<style>`), not an unaddressed accessibility gap.

## Consequences

- `terraform/bootstrap/architecture-site.tf` (new): `aws_s3_bucket`, `aws_s3_bucket_public_access_block`, `aws_s3_bucket_server_side_encryption_configuration`, `aws_cloudfront_origin_access_control`, `aws_s3_bucket_policy`, `aws_cloudfront_distribution`, `aws_route53_record` — all with the `architecture_site` suffix/name.
- `terraform/bootstrap/outputs.tf`: `architecture_site_url`, `architecture_site_bucket_name`, `architecture_site_cloudfront_distribution_id`.
- `terraform/bootstrap/scripts/deploy-architecture-site.sh` (new): syncs `site/architecture/` to the bucket and invalidates the cache, reading bucket/distribution via `terraform output` (no magic values).
- `site/architecture/index.html` (new `site/` directory at the root): a single page, content derived from `docs/architecture.md`/`docs/000-motivation.md`, not a 1:1 copy of the Markdown.
- `docs/showcase-urls.md`: new section listing this URL as the only one that doesn't depend on `envs/lab` being up.
- `CLAUDE.md` ("Current state"): resource added to the list of infrastructure persistent between sessions.
- **Estimated cost:** close to zero — S3 (a few KB of HTML/CSS/JS) and CloudFront billed only per request/transfer; expected portfolio traffic (tens/hundreds of visits). No new fixed cost beyond what already exists in `terraform/bootstrap/`.
- **Known pending item, out of scope for this decision:** the GitHub repository is still private (already recorded as a next step in `CLAUDE.md`/ADR 007) — the page links to it, but the link only works for visitors once the repository is made public.
- Real functional validation done in this same session: `terraform apply` in `bootstrap/` followed by the first run of `scripts/deploy-architecture-site.sh` — `https://system-design.minitube.projetodevops.com.br` responds `HTTP/2 200`, valid HTTPS, served by CloudFront/S3.

# 019 — A real watch page at `app.<domain>`

## Status

Accepted

## Context

`app.<domain>` never served a real interface — `terraform/envs/lab/cloudfront.tf` only ever defined two behaviors: `/api/*` to the ALB (FastAPI, 3 routes: `healthz`, `POST /videos`, `GET /videos/{id}`), and everything else straight to the video S3 bucket, with no `default_root_object`. The root path returned `403`. "Watching" a video meant manually building the playlist URL (`/hls/<video_id>/playlist.m3u8`) and pointing an external player at it — fine for a functional check, but not something worth sharing as a URL, and not a real simulation of the "client watching YouTube" side of the project's own premise (`docs/000-motivation.md`).

This came up directly while planning a screen recording of a real load test for a LinkedIn post: without a real page, `app.<domain>` had nothing to show as the "client side" of the demo. Decided, with the project's operator, to build a small real watch page instead of a throwaway local file — versioned, part of the product, not just a recording prop.

## Decisions

### 1. Lives in `envs/lab`, not `bootstrap/` (unlike the architecture showcase site)

[ADR 017](017-persistent-architecture-showcase-site.md) put the architecture page in `terraform/bootstrap/` specifically because it needed to outlive `envs/lab`'s destroy/apply cycle. This page is the opposite case: it only makes sense while `envs/lab` — and the video bucket/API it depends on — actually exists. Same S3+OAC+CloudFront shape, reused from the distribution that already exists (`aws_cloudfront_distribution.app`), not a new one.

### 2. Content *is* Terraform-managed here, unlike ADR 017's `site/architecture/`

ADR 017 deliberately kept `site/architecture/index.html` out of Terraform, synced by a manual script (`deploy-architecture-site.sh`) — because that bucket is persistent and content changes independently of infrastructure changes. The video bucket is the opposite: `force_destroy = true`, recreated from scratch every session. Managing `site/player/index.html` as a plain `aws_s3_object` (`terraform/envs/lab/s3.tf`) means the watch page is published automatically by the same `terraform apply` that stands up the rest of the environment — no extra manual step to remember every session, one step closer to `CLAUDE.md` principle 1 ("recreating the environment from scratch must be painless").

### 3. `?v=<video_id>` on the bucket root, not a `/watch` path

`aws_cloudfront_distribution.app` gains `default_root_object = "index.html"` — it only affects requests to the exact root (`/`), leaving `/hls/*` (exact object keys) and `/api/*` (separate `ordered_cache_behavior`/origin) untouched. The page reads `?v=` client-side via `URLSearchParams`; CloudFront/S3 never need to know about the query string, since it isn't part of key resolution. A dedicated `/watch` path would need a CloudFront Function to rewrite the request — new infrastructure for a cosmetic gain over `youtube.com/watch?v=...`'s own shape, not adopted (YAGNI).

### 4. `hls.js` via a version-pinned CDN script tag, not vendored inline

Unlike `site/architecture/index.html` (ADR 017, decision 4: no external dependency at all, by design — that page has no equivalent third-party need), this page has a genuine dependency: real HLS playback in browsers without native support (every non-Safari browser) requires a real HLS parser, and hand-rolling one is out of scope. Chose a pinned version (`hls.js@1.5.15`, jsdelivr), the same "pinned versions" convention already used for every tool in `.github/workflows/ci.yml` (`TERRAFORM_VERSION`, `TFLINT_VERSION`, `TRIVY_VERSION`, etc.) — never `@latest`. Discussed with the operator; the alternative (vendoring the ~50-60KB minified build inline) was discarded for having no easy update path and no real robustness gain proportional to the added repo weight, for a single-purpose demo/portfolio page.

### 5. No listing, no gallery, no new API route

The page never lists videos — there's no `GET /api/videos` and none was added. `video_id` always comes from the existing `POST /api/videos` response and is passed manually in the URL, the same way a YouTube video link is shared. Kept the change entirely inside `terraform/envs/lab/` and `site/player/` — zero changes to `app/api/`.

### 6. Narrow bucket policy grant

`aws_s3_bucket_policy.video_cloudfront_read`'s `Resource` changed from a single `hls/*` prefix to a list adding the exact key `index.html` — nothing else at the bucket root becomes readable, `raw/` stays inaccessible to CloudFront as before.

## Consequences

- `site/player/index.html` (new): single self-contained page (inline CSS, one external `<script src>`), same dark "night match under floodlights" theme as `site/architecture/index.html` for visual consistency across the project's two public pages.
- `terraform/envs/lab/cloudfront.tf`: `aws_cloudfront_distribution.app` gains `default_root_object`; `aws_s3_bucket_policy.video_cloudfront_read`'s `Resource` becomes a list.
- `terraform/envs/lab/s3.tf`: new `aws_s3_object.player_page`.
- `docs/showcase-urls.md`: the "player streaming a real video" checklist item now points at a real URL (`https://app.<domain>/?v=<video_id>`) instead of "open an external player".
- `CLAUDE.md`: `site/player/` added to the repository structure tree.
- `docs/runbooks/run-the-project.md`: a line added to "Use the environment" (2.5), same format as the existing ArgoCD/Grafana bullets.
- No change to `app/api/`, `gitops/`, or `.github/workflows/ci.yml` (a single static HTML file, same as `site/architecture/index.html` today — no HTML-specific lint configured in this project either way).

## Validation

`terraform fmt`, `terraform validate`, and `tflint` clean in `terraform/envs/lab/` (`-backend=false`, matching the CI job). Functional validation deferred to the next real `terraform apply`: `curl -I https://app.<domain>/` expected to return `200` (currently `403`), and `https://app.<domain>/?v=<video_id>` expected to play a real HLS stream in the browser with the Network tab showing `.ts`/`.m3u8` segments and an `X-Cache` header from CloudFront — the same evidence already tracked in `docs/showcase-urls.md`.

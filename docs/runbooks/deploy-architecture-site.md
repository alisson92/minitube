# Runbook — Deploying the architecture page

> Updates the content of `https://system-design.minitube.projetodevops.com.br`. Not to be confused with the main runbook (`run-the-project.md`) — this resource lives in `terraform/bootstrap/`, persistent, outside of `envs/lab`'s daily `apply`/`destroy` cycle. See [ADR 017](../adr/017-persistent-architecture-showcase-site.md).

## When to run

Whenever `site/architecture/index.html` changes. The infrastructure (`terraform/bootstrap/architecture-site.tf`) only needs `apply` once (or when the Terraform resource itself changes) — content and infrastructure are deployed separately on purpose.

## First time (only when the infrastructure doesn't yet exist)

```bash
cd terraform/bootstrap
terraform plan   # review before applying, even though it's a persistent module
terraform apply
```

## Content deploy (every time the page changes)

```bash
cd terraform/bootstrap
AWS_PROFILE=cloudlab ./scripts/deploy-architecture-site.sh
```

The script reads `bucket`/`distribution_id` via `terraform output` (never hardcoded), syncs `site/architecture/` to S3, and invalidates the CloudFront cache — the change becomes visible within seconds, without waiting for the cache TTL.

## Functional validation

After the first `apply` + first deploy:

```bash
curl -sI https://system-design.minitube.projetodevops.com.br | head -5
```

Expected: `HTTP/2 200`, a valid certificate (no `curl` error), `content-type: text/html`. Open it in the browser to check visually — "apply with no error" doesn't prove the page renders correctly (`docs/engineering-standards.md` §11).

## Notes

- `terraform/bootstrap/` is never destroyed — there's no "destroy" runbook for this resource.
- The content (`site/architecture/index.html`) is not managed by Terraform — changes to it require running the deploy script, not `terraform apply`.

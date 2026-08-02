# 001 — Terraform remote backend: single S3 bucket with native locking

## Status

Accepted

## Context

All MiniTube environments (`terraform/envs/lab/...` and future ones) need a remote state backend, with locking, to allow safe work (even though today it's a single operator) and recovery in case of failure. This backend cannot be created by the environment that will use it — it's the classic "chicken and egg" problem of Terraform bootstrapping.

Historically, HashiCorp's recommendation for state locking in S3 was an S3 bucket (state) + a dedicated DynamoDB table (lock via `LockID`). Since Terraform 1.10, the `s3` backend supports **native locking** via `use_lockfile = true`, using the S3 bucket itself with conditional writes (`If-None-Match`), without depending on DynamoDB.

## Decision

1. Create a single S3 bucket (`terraform/bootstrap/`) to host the state of all project environments: `minitube-tfstate-<account-id>`.
2. Use **native S3 locking** (`use_lockfile = true` in the `backend "s3"` block of each environment), instead of a DynamoDB table. Reasons:
   - It's the current guidance from HashiCorp's official documentation for new S3 backends.
   - Avoids an additional AWS resource (table + eventual extra IAM) for a cost-controlled lab project.
   - Reduces the bootstrap's surface to a single main resource.
3. The bucket is created with:
   - Versioning enabled (recovery/audit of previous states).
   - SSE-S3 encryption (`AES256`) by default — no KMS cost.
   - Full public access block (`aws_s3_bucket_public_access_block`).
   - Policy denying any access outside TLS (`aws:SecureTransport = false` → `Deny`).
   - Expiration of non-current versions after 90 days, to avoid accumulating storage cost indefinitely.
   - `lifecycle { prevent_destroy = true }`, to prevent accidental destruction.
4. The bootstrap itself uses a **local backend** on the first `apply` (there's nowhere else to store the state before the bucket exists). Once created, a `backend "s3"` block is added pointing to the bucket itself, and `terraform init -migrate-state` migrates the bootstrap's state into it — the bootstrap starts managing its own state remotely. Procedure documented in `docs/runbooks/bootstrap/bootstrap-remote-backend.md`.

### Alternative considered: S3 bucket + DynamoDB table

Discarded for this project for adding an extra resource and IAM dependency with no practical benefit in a single-operator scenario. Worth noting that this is the traditional approach (and still widely documented, including in Terraform Associate certification content) — it can be reevaluated if the project evolves to multiple operators/CI with a need for more granular lock auditing.

## Consequences

- **Exception to the project's ephemeral infrastructure principle** (see `CLAUDE.md`): the state bucket is the only resource that needs to persist between sessions — without it, there would be nowhere for future environments to write/retrieve their state history. This persistence is intentional and is recorded in the "Current state" section of `CLAUDE.md`, analogous to the decision planned for the DNS zone in Phase 4.
- Any new environment (`terraform/envs/<env>/backend.tf`) must reference this bucket with `use_lockfile = true`, without depending on a DynamoDB table.
- Destroying this bucket requires manually removing `prevent_destroy` — it's a deliberate barrier against accidents, not a permanent lock.

## Update — 2026-08-02

The persistence decision above is reverted. An unexpected ~R$600 charge against the project prompted a full teardown of every remaining resource, including everything under `terraform/bootstrap/`. `prevent_destroy` was removed from `aws_s3_bucket.terraform_state` so `terraform destroy` can proceed normally.

A first destroy attempt still failed on non-empty resources: both S3 buckets (`terraform_state`, `architecture_site`) had objects/versions in them, and both `aws_ecr_repository` resources still had pushed images — neither `force_destroy` nor `force_delete` was set. Added `force_destroy = true` to both buckets and `force_delete = true` to both ECR repositories so `terraform destroy` removes their contents instead of erroring out.

A second destroy run then failed with `NoSuchBucket` while writing the final state: `aws_s3_bucket.terraform_state` was destroyed mid-run, but this module's own remote backend (`backend.tf`) lives in that same bucket — Terraform had nowhere left to persist the updated state. This is the inherent risk of a backend that stores its own state: **the last resource a bootstrap module's `destroy` can safely remove is the bucket backing its own backend.** Terraform wrote the recovery state to `errored.tfstate` as designed. Recovery: temporarily point at a local backend (remove/rename `backend.tf`, copy `errored.tfstate` to `terraform.tfstate`, `rm -rf .terraform && terraform init`), confirm with `terraform plan -destroy` (not `terraform plan`, which would show creating everything already-destroyed as missing from state), then `terraform destroy` against the local backend to finish the remaining resources (`aws_route53_zone.minitube`, `aws_acm_certificate.wildcard`). All 20 resources were confirmed destroyed and the AWS account confirmed empty of MiniTube resources via the CLI afterward.

If `terraform/bootstrap/` is ever re-applied from scratch, follow `docs/runbooks/bootstrap/bootstrap-remote-backend.md` again: start on a local backend, create the bucket, then migrate to the S3 backend — the same sequencing problem would otherwise repeat on the next teardown.

This doesn't invalidate the reasoning above — native S3 locking without DynamoDB is still the right call for a single-operator lab — it just means the state bucket (and the rest of `terraform/bootstrap/`: ECR, Route 53 zone, ACM certificate, architecture showcase site) no longer gets a persistence exception. If the project resumes, `terraform/bootstrap/` is re-applied from scratch like any other environment, and re-issuing the wildcard certificate means re-delegating NS records at the domain registrar again (see ADR 008).

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

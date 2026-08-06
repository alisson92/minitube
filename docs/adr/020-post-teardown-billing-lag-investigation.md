# 020 — Post-teardown billing lag investigation

## Status

Accepted

## Context

Four days after the 2026-08-02 full teardown (ADR 001's update), the AWS Billing "Bills" screen showed **USD 1.60** in active charges across 9 services, most non-zero: EBS (USD 0.58, a 7.257 GB-Mo gp3 volume), Route 53 (USD 0.50, 1 HostedZone), plus non-zero request/storage counters on S3, CloudFront, ECR, and KMS. This directly contradicted the teardown's "confirmed empty via the AWS CLI" claim in `CLAUDE.md`'s Current state, so it was treated as a real leak, not dismissed.

Investigating required admin AWS CLI access, which the usual `cloudlab` SSO profile no longer had (`ForbiddenException: No access`) — expected, since `terraform/bootstrap-iam/` (the module provisioning the `cloudlab-operator` permission set) was itself part of the same teardown. AWS CloudShell was used instead, inheriting the root/admin console session directly.

## Investigation

1. A remediation script (`scripts/remediate-billing-leak.sh`, this session, not merged) was written to discover and delete the 6 suspect resources: S3 bucket, CloudFront distribution, Route 53 hosted zone, ECR repo, orphaned EBS volume, KMS customer-managed key.
2. Getting the script into CloudShell intact took three failed attempts before landing on the fix: pasting multi-line content into the CloudShell terminal (via direct paste, a heredoc, and even a single-line base64 blob echoed through `base64 -d`) kept getting corrupted or silently swallowed by the browser terminal's line handling. What actually worked was pushing the script to a short-lived branch (`chore/remediate-billing-leak`) and `git clone --single-branch` from CloudShell — bytes come straight from GitHub, no terminal paste involved.
3. Running the script's read-only discovery phase (Phase 1) returned **empty for all 6 categories** — no S3 buckets, no CloudFront distributions, no Route 53 zones, no ECR repos, no available EBS volumes, no enabled customer-managed KMS keys.
4. Cross-checked with explicit `--region us-east-1` (the region shown in the billing screenshot) to rule out a CloudShell default-region mismatch hiding region-scoped resources (EBS, ECR, KMS are region-scoped; S3/CloudFront/Route 53 listings are global and already ruled this out on their own). Same empty result.
5. The only resources KMS `list-keys` returned were 2 AWS-managed keys (`Manager: AWS`) — the account's default keys for SSM parameters and ACM private keys. These are permanent, free, and not deletable; they explain the USD 0.00 KMS line in the bill (19 free-tier requests) and are unrelated to MiniTube.

## Decision

**No orphaned resource existed at investigation time.** The USD 1.60 was residual billing for the hours those 6 resources existed *before* the 2026-08-02 teardown finished destroying them — AWS's Bills view shows the billing-period-to-date total, not live resource state, so a same-month bill keeps showing charges for since-deleted resources. The original teardown claim in `CLAUDE.md` was correct; the confusion was mistaking a historical cost report for a live-state check.

No cleanup action was taken (nothing to clean up). The remediation script and its branch are being closed without merge — it served its one-time diagnostic purpose. If a similar gap is suspected again, prefer this ADR's method (discovery-only, `--region` pinned explicitly, cross-checked via `git clone` into CloudShell rather than pasting) over building a fresh delete script from scratch.

## Consequences

- No infrastructure or Terraform state changed. `CLAUDE.md`'s Current state stands as previously recorded — no update needed there.
- **Lesson for future teardown verification:** confirming "no billable resources remain" via the Billing/Cost Explorer UI needs a same-day or next-day check at the earliest — checking days later without also cross-referencing live resource listings (`describe-*`/`list-*` calls, not the Bills total) risks reading stale accrued cost as an active leak.
- **Lesson on CloudShell paste reliability:** multi-line pastes (raw, heredoc, or single-line base64) were all corrupted or silently dropped by the CloudShell terminal in this session. For any future one-off script needed inside CloudShell, push to a short-lived branch and `git clone --single-branch` rather than pasting — it's slower to set up but the only method that worked cleanly here.
- `scripts/remediate-billing-leak.sh` and the `chore/remediate-billing-leak` branch are deleted after this ADR merges — kept only in git history for reference, not as a reusable tool (its resource-discovery logic assumed a specific set of 6 services; a next incident may have a different profile and deserves its own fresh discovery pass).

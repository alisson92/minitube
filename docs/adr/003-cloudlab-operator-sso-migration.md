# 003 — Migration of `cloudlab-operator` to IAM Identity Center (SSO)

## Status

Accepted

## Context

ADR 002 created `cloudlab-operator` as an `aws_iam_user` with an `aws_iam_access_key` — a static, long-lived credential, configured manually via `aws configure --profile cloudlab`. This gap had already been recorded as a pending item in `CLAUDE.md`: AWS itself recommends IAM Identity Center for human operators, since `aws sso login` generates temporary credentials that expire on their own, eliminating the need for manual access key rotation.

The decision was to bring this migration forward to the beginning of Phase 1, while only two resources depended on the static credential (the state bucket and the IAM user itself) — before any other module (VPC, EKS) started depending on the local profile.

## Decision

1. **Completely remove** `aws_iam_user.operator`, its policy attachment, and its `aws_iam_access_key` in `terraform/bootstrap-iam/`. No static operator credential remains in the account.
2. **Enable IAM Identity Center** on the account (a single manual step, done via console with a root session — AWS doesn't expose service activation via Terraform).
3. **Create the operator user in Identity Center manually** (`alisson.cloudlab@gmail.com`), also via console — creating it via `aws_identitystore_user` doesn't trigger the password invite/activation flow, so the user is created once via console and only **referenced** via `data "aws_identitystore_user"` in Terraform.
4. **Model access via an IAM Identity Center Permission Set**, with the same managed policy `PowerUserAccess` already used before (`aws_ssoadmin_permission_set` + `aws_ssoadmin_managed_policy_attachment` + `aws_ssoadmin_account_assignment`), preserving the same privilege level and the same IAM/Organizations exclusion from the original design.
5. **Keep the module separation from ADR 002**: `terraform/bootstrap-iam/` remains admin-only (applied via CloudShell/root), since the `aws_ssoadmin_*`/`aws_identitystore_*` resources are also not covered by the daily operator's `PowerUserAccess`. `terraform/bootstrap/` remains daily-use, unchanged.
6. **The local `cloudlab` profile switches to `sso-session`** (the same pattern already in use in this environment for another project/account), authenticating via `aws sso login --profile cloudlab` instead of a static access key stored in `~/.aws/credentials`.

### Alternatives considered

- **Keep `aws_iam_user` as a break-glass, without an active access key:** discarded — would add one more resource and exception to document and keep consistent, with no real benefit in a single-operator project where root via CloudShell already covers any recovery scenario.
- **Create the Identity Center user via Terraform (`aws_identitystore_user`):** discarded — doesn't trigger AWS's invite/password-setting flow, making first access more fragile than creating it once via console.

## Consequences

- No static human operator credential exists in the account anymore; local authentication expires on its own every session (`session_duration = "PT4H"` on the permission set).
- Enabling Identity Center and creating the user remain single manual steps per account — documented in [`docs/runbooks/bootstrap/aws-account-bootstrap.md`](../runbooks/bootstrap/aws-account-bootstrap.md) — consistent with the same type of exception already accepted for account/root creation in ADR 002.
- Any future access change (new permission set, new user) still requires a root/CloudShell session in `terraform/bootstrap-iam/`, with no change in flow relative to ADR 002.
- The pending item recorded in `CLAUDE.md` about the SSO migration is resolved.

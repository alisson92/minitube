# 002 — Dedicated AWS account and IAM bootstrap via Terraform

## Status

Accepted

## Context

The first attempt to `terraform apply` the state bucket failed: the locally configured IAM user (`lab-operator`, account `455162168775`) didn't have `s3:CreateBucket` permission, and there was no record of which account/administrator originally created it — the account was neither traceable nor documented.

## Decision

1. **New, dedicated AWS account**, with its own email (`alisson.cloudlab@gmail.com`), used to manage multiple personal cloud lab projects — not tied only to MiniTube.
2. **No long-lived credentials for root.** Root is only used to: set the password, enable MFA, and open AWS CloudShell once. CloudShell inherits the console session's temporary credentials, allowing `terraform apply` to run without ever generating a root access key (a practice discouraged by AWS itself).
3. **Operational user created via Terraform, not manually:** `cloudlab-operator` (`terraform/bootstrap-iam/`), with the managed policy `PowerUserAccess` — broad access to most AWS services, but excludes IAM/Organizations management. This exclusion is what maintains the privilege separation between the administrative identity (root, very rare use) and the daily-use identity.
4. **IAM resources isolated in their own module (`terraform/bootstrap-iam/`), separate from the state bucket (`terraform/bootstrap/`).** In the first attempt, the two lived in the same state, and `cloudlab-operator` couldn't even run `terraform plan` there — the state refresh tries to read `aws_iam_user.operator`, and `PowerUserAccess` itself forbids that (`iam:GetUser` denied). Separating the states solves this: `terraform/bootstrap/` (S3 bucket) is daily-use and smooth for `cloudlab-operator`; `terraform/bootstrap-iam/` (user, policy, access key) can only be planned/applied with an admin session (CloudShell), which is consistent with item 3 already being a rare event.

### Alternatives considered

- **Custom policy, growing per phase:** more aligned with the least-privilege principle, but would require reopening a root/CloudShell session every time a phase touched a new AWS service — operational friction discarded for a single-operator personal project.
- **AdministratorAccess for the daily operator:** discarded for completely removing the separation between the admin identity and the operational identity, which violates the least-privilege principle even in a personal lab context.

## Consequences

- Any future IAM change (new policy, new user) requires repeating the manual CloudShell procedure inside `terraform/bootstrap-iam/` — a rare event, documented in [`docs/runbooks/bootstrap/aws-account-bootstrap.md`](../runbooks/bootstrap/aws-account-bootstrap.md), not part of the normal `apply`/`destroy` flow of sessions.
- `terraform/bootstrap/` (state bucket) can be planned/applied normally by `cloudlab-operator`, locally, without CloudShell — it's the only directory in the project with this characteristic in Phase 1, since the others (VPC, EKS, etc.) also don't touch IAM.
- The old account (`455162168775`, `lab-operator`) is abandoned; no cleanup is necessary there beyond, eventually, closing it if it has no further use.
- The `operator_secret_access_key` output is sensitive and should only be read once, at the moment of configuring the local profile — it must never appear in logs or be committed.

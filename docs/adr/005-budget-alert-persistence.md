# 005 — Persistence of the budget alert in `bootstrap-iam`

## Status

Accepted

## Context

The last pending deliverable of Phase 1 is the budget alert (`CLAUDE.md`, "Project phases" section). Its purpose is to notify about unexpected spending on the AWS account (`479213212405`) — including infrastructure accidentally left running, outside the normal `apply`/`destroy` cycle of `terraform/envs/lab/`. This raises the same question already answered by ADRs 001, 002, and 004 for other resources: what should survive between sessions, despite the project's ephemeral infrastructure principle?

## Decision

The budget alert (`aws_budgets_budget`) lives in `terraform/bootstrap-iam/`, alongside the state bucket and the IAM roles — persistent, applied once, outside the `apply`/`destroy` cycle of `envs/lab/`. It covers the account's total cost (no `cost_filter`), with two direct email notifications (`subscriber_email_addresses`, no SNS topic): 80% of the monthly limit (`FORECASTED`, preventive alert) and 100% (`ACTUAL`, limit already exceeded). Monthly limit: **10 USD**. Email: `alisson.cloudlab@gmail.com` (same SSO user as the daily operator).

## Alternatives considered

- **Placing it in `terraform/envs/lab/`:** discarded. If the budget were destroyed every session along with the VPC/EKS, it would lose exactly the coverage that matters most — detecting spending when no one is actively watching the account, between test sessions.
- **SNS topic instead of direct email in the notification:** discarded. The `aws_budgets_budget` resource natively accepts `subscriber_email_addresses`, without requiring subscription confirmation (unlike an SNS subscription). An SNS topic would only be justified for multi-channel fan-out (e.g., Slack via Lambda) — not the case today. It can be added later without breaking what exists.
- **Dedicated `terraform/bootstrap-budget/` module:** discarded. The AWS Budgets API doesn't depend on the IAM restrictions that force `bootstrap-iam/` to be admin-only (`PowerUserAccess` doesn't block `budgets:*`), but creating a third module just for a single resource would be over-engineering. Reusing the already-established flow (CloudShell/root session) for `bootstrap-iam/` keeps a single mental place for "persistent, low-change-frequency things."

## Consequences

- The budget alert is never destroyed between sessions; any change to the limit or email goes through the already-existing admin-only flow (CloudShell/root session) of `bootstrap-iam/`.
- AWS Budgets has an evaluation lag (AWS recalculates actual/forecasted spend periodically, not instantly after `apply` or a config change — typically every few hours). The post-apply functional validation (`scripts/validate-budget.sh`, `docs/runbooks/validate/validate-budget-alert.md`) confirms the **configuration** via API (`describe-budgets`, `describe-notifications-for-budget`), not the actual alert firing — that can only be confirmed organically, by observing the inbox over normal account usage.
- Closes Phase 1's completion criterion: all deliverables in the `CLAUDE.md` phases table are now implemented and validated.

# Runbook — Budget alert functional validation

> Establishes the "functional validation post-apply" standard described in [`docs/engineering-standards.md`](../../engineering-standards.md#11-post-apply-functional-validation). See also [`docs/adr/005-budget-alert-persistence.md`](../../adr/005-budget-alert-persistence.md).

## Why this exists

`terraform apply` without error and `aws budgets describe-budgets` showing the created resource prove that the budget **exists with the expected attributes** — they do not prove that it **notifies correctly**. The question that matters: is the monthly limit correct, and are the two notifications (80% forecasted, 100% actual) configured with the right email?

## Known limitation: the real alert firing cannot be forced

AWS Budgets recalculates actual and forecasted spend **on its own schedule** (not instantly after `apply` or a configuration change — typically a few hours). There is no command to force this reevaluation on demand. Because of this, `scripts/validate-budget.sh` validates **configuration** via the API (`describe-budgets`, `describe-notifications-for-budget`, `describe-subscribers-for-notification`), not the actual firing of the alert email. Confirming that the alert really fires is only possible organically: watching the inbox (`alisson.cloudlab@gmail.com`) during normal account usage, when spend actually crosses 80%/100% of the limit.

## How the script works

- **Checks performed:**
  1. The budget (`minitube-monthly-cost-alert`) exists in the account.
  2. The limit is `10 USD`/`MONTHLY` (value read from `var.budget_limit_usd`).
  3. The `FORECASTED` notification at 80% (`GREATER_THAN`) is configured.
  4. The `ACTUAL` notification at 100% (`GREATER_THAN`) is configured.
  5. The subscriber email (`alisson.cloudlab@gmail.com`) is actually on the subscriber list for the 100% notification.
- Creates and destroys no resources — read-only via `aws budgets describe-*`, so it needs no cleanup `trap`.

## Apply and run the test

```bash
# Root/CloudShell session — bootstrap-iam is admin-only (see ADR 002/003)
cd terraform/bootstrap-iam
terraform init
terraform plan     # review: 1 new resource (aws_budgets_budget), nothing else changes
terraform apply

./scripts/validate-budget.sh
```

Dependencies: `aws` CLI, `jq`, `terraform`.

## Expected output

```
PASS: budget 'minitube-monthly-cost-alert' exists in account 479213212405
PASS: budget limit is 10.0 USD / MONTHLY
PASS: 80% FORECASTED notification is configured
PASS: 100% ACTUAL notification is configured
PASS: notifications subscribe 'alisson.cloudlab@gmail.com'
=== All checks passed: budget alert is configured as expected. ===
NOTE: this validates configuration only. AWS Budgets recalculates spend
on its own schedule (not instantly), so a real alert firing can only be
confirmed organically over time -- see docs/runbooks/validate/validate-budget-alert.md.
```

Exit code `0` when everything passes, `1` if any check fails.

## Changing the limit or the email

Edit `budget_limit_usd`/`budget_notification_email` in `terraform/bootstrap-iam/variables.tf` (or pass via `-var`), then repeat the `plan` → `apply` → `validate-budget.sh` flow above, always via CloudShell/root session.

## Persistence

The budget alert is **not** destroyed between sessions — it lives in `terraform/bootstrap-iam/`, alongside the IAM roles and the operator permission set, outside the ephemeral cycle of `terraform/envs/lab/` (see ADR 005). No action is needed when ending a VPC/EKS test session.

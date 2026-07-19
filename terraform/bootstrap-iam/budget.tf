# Account-wide cost guardrail, persistent by design (see
# docs/adr/005-budget-alert-persistence.md) — lives here, not in envs/lab, so
# it keeps watching spend even when the ephemeral lab environment is
# destroyed between sessions. No cost_filter: tracks the whole account (VPC,
# EKS, future CloudFront/S3, etc.), not a single service.
resource "aws_budgets_budget" "account_cost" {
  name         = "${var.project}-monthly-cost-alert"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Early warning: projected spend is trending past the limit.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_notification_email]
  }

  # Hard alert: actual spend has already crossed the limit.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_notification_email]
  }
}

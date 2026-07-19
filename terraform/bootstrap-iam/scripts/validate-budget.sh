#!/usr/bin/env bash
# Functional check for the account-wide budget alert: confirms the budget
# exists with the expected limit and that both notifications (80% forecasted,
# 100% actual) are wired to the right email -- not just that `terraform apply`
# exited 0. AWS Budgets recalculates actual/forecasted spend on its own
# schedule (not instantly after apply), so this script validates
# configuration, not a real alert firing -- see
# docs/runbooks/validate-budget-alert.md.
#
# Usage: AWS_PROFILE=cloudlab ./scripts/validate-budget.sh
# Run from terraform/bootstrap-iam/ (the script also cds there automatically).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

for bin in aws jq terraform; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

run_check() {
  local description="$1"
  shift
  echo "--- Check: $description ---"
  if "$@"; then
    echo "PASS: $description"
    return 0
  else
    echo "FAIL: $description" >&2
    return 1
  fi
}

echo "Reading Terraform outputs..."
budget_name=$(terraform output -raw budget_name)
account_id=$(aws sts get-caller-identity --query Account --output text)
expected_email=$(terraform console <<< "var.budget_notification_email" 2>/dev/null | tr -d '"' || echo "")
expected_limit=$(terraform console <<< "var.budget_limit_usd" 2>/dev/null | tr -d '"' || echo "")

overall=0

budget_json=$(aws budgets describe-budgets --account-id "$account_id" \
  --query "Budgets[?BudgetName=='${budget_name}'] | [0]" --output json)

check_budget_exists() {
  [[ "$budget_json" != "null" ]]
}
run_check "budget '$budget_name' exists in account $account_id" check_budget_exists || overall=1

if [[ "$budget_json" != "null" ]]; then
  actual_limit=$(jq -r '.BudgetLimit.Amount' <<< "$budget_json")
  actual_unit=$(jq -r '.BudgetLimit.Unit' <<< "$budget_json")
  actual_time_unit=$(jq -r '.TimeUnit' <<< "$budget_json")

  check_limit() {
    [[ "$actual_unit" == "USD" && "$actual_time_unit" == "MONTHLY" ]] \
      && { [[ -z "$expected_limit" ]] || [[ "$actual_limit" == "$expected_limit"* ]]; }
  }
  run_check "budget limit is ${actual_limit} ${actual_unit} / ${actual_time_unit}" check_limit || overall=1

  notifications_json=$(aws budgets describe-notifications-for-budget \
    --account-id "$account_id" --budget-name "$budget_name" --output json)

  check_forecasted_80() {
    jq -e '.Notifications[] | select(.NotificationType=="FORECASTED" and .Threshold==80 and .ComparisonOperator=="GREATER_THAN")' \
      <<< "$notifications_json" >/dev/null
  }
  run_check "80% FORECASTED notification is configured" check_forecasted_80 || overall=1

  check_actual_100() {
    jq -e '.Notifications[] | select(.NotificationType=="ACTUAL" and .Threshold==100 and .ComparisonOperator=="GREATER_THAN")' \
      <<< "$notifications_json" >/dev/null
  }
  run_check "100% ACTUAL notification is configured" check_actual_100 || overall=1

  if [[ -n "$expected_email" ]]; then
    check_subscriber_email() {
      local subs
      subs=$(aws budgets describe-subscribers-for-notification \
        --account-id "$account_id" --budget-name "$budget_name" \
        --notification ComparisonOperator=GREATER_THAN,NotificationType=ACTUAL,Threshold=100,ThresholdType=PERCENTAGE \
        --query "Subscribers[].Address" --output text)
      grep -qi "$expected_email" <<< "$subs"
    }
    run_check "notifications subscribe '$expected_email'" check_subscriber_email || overall=1
  fi
fi

if (( overall == 0 )); then
  echo "=== All checks passed: budget alert is configured as expected. ==="
  echo "NOTE: this validates configuration only. AWS Budgets recalculates spend"
  echo "on its own schedule (not instantly), so a real alert firing can only be"
  echo "confirmed organically over time -- see docs/runbooks/validate-budget-alert.md."
else
  echo "=== One or more checks FAILED -- see output above. ===" >&2
fi

exit $overall

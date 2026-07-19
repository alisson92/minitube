output "permission_set_arn" {
  description = "ARN of the IAM Identity Center permission set for the daily-use Terraform operator"
  value       = aws_ssoadmin_permission_set.operator.arn
}

output "sso_instance_arn" {
  description = "ARN of the IAM Identity Center instance used by this account"
  value       = tolist(data.aws_ssoadmin_instances.this.arns)[0]
}

output "smoke_test_instance_profile_name" {
  description = "Name of the instance profile ephemeral smoke-test EC2 instances should assume (SSM access only)"
  value       = aws_iam_instance_profile.network_smoke_test.name
}

output "eks_cluster_role_name" {
  description = "Name of the IAM role the EKS control plane assumes, referenced by name from envs/lab via a data source"
  value       = aws_iam_role.eks_cluster.name
}

output "eks_node_role_name" {
  description = "Name of the IAM role EKS worker nodes assume, referenced by name from envs/lab via a data source"
  value       = aws_iam_role.eks_node.name
}

output "budget_name" {
  description = "Name of the account-wide AWS Budgets cost alert"
  value       = aws_budgets_budget.account_cost.name
}

output "budget_arn" {
  description = "ARN of the account-wide AWS Budgets cost alert"
  value       = aws_budgets_budget.account_cost.arn
}

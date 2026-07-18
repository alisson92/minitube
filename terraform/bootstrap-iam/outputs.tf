output "permission_set_arn" {
  description = "ARN of the IAM Identity Center permission set for the daily-use Terraform operator"
  value       = aws_ssoadmin_permission_set.operator.arn
}

output "sso_instance_arn" {
  description = "ARN of the IAM Identity Center instance used by this account"
  value       = tolist(data.aws_ssoadmin_instances.this.arns)[0]
}

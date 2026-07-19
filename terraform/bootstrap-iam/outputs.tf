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

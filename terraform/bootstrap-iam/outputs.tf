output "operator_access_key_id" {
  description = "Access key ID for the daily-use Terraform operator"
  value       = aws_iam_access_key.operator.id
}

output "operator_secret_access_key" {
  description = "Secret access key for the daily-use Terraform operator"
  value       = aws_iam_access_key.operator.secret
  sensitive   = true
}

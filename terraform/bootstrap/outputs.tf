output "state_bucket_name" {
  description = "Name of the S3 bucket used as the remote state backend. Use it in the backend \"s3\" block of the other environments."
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_region" {
  description = "Region of the state bucket"
  value       = var.aws_region
}

output "operator_access_key_id" {
  description = "Access key ID for the daily-use Terraform operator"
  value       = aws_iam_access_key.operator.id
}

output "operator_secret_access_key" {
  description = "Secret access key for the daily-use Terraform operator"
  value       = aws_iam_access_key.operator.secret
  sensitive   = true
}

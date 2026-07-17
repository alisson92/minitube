output "state_bucket_name" {
  description = "Name of the S3 bucket used as the remote state backend. Use it in the backend \"s3\" block of the other environments."
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_region" {
  description = "Region of the state bucket"
  value       = var.aws_region
}

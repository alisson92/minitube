output "state_bucket_name" {
  description = "Name of the S3 bucket used as the remote state backend. Use it in the backend \"s3\" block of the other environments."
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_region" {
  description = "Region of the state bucket"
  value       = var.aws_region
}

output "ecr_api_repository_url" {
  description = "URL of the ECR repository for the API image, used by docker build/push and the Kubernetes Deployment manifest"
  value       = aws_ecr_repository.api.repository_url
}

output "ecr_transcoder_repository_url" {
  description = "URL of the ECR repository for the transcoder image, used by docker build/push and the Job spec built by the API"
  value       = aws_ecr_repository.transcoder.repository_url
}

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

output "route53_zone_id" {
  description = "Hosted zone ID of the delegated subdomain, looked up by terraform/envs/lab (data \"aws_route53_zone\") and hardcoded into gitops/plataforma/cert-manager's ClusterIssuer solver"
  value       = aws_route53_zone.minitube.zone_id
}

output "route53_zone_name_servers" {
  description = "NS records to add manually at the root domain's registrar to delegate the subdomain to this hosted zone. Required before any DNS resolution under domain_name works — see docs/runbooks/validate-cloudfront-dns-tls.md"
  value       = aws_route53_zone.minitube.name_servers
}

output "acm_certificate_arn" {
  description = "ARN of the wildcard ACM certificate (*.<domain_name>), looked up by terraform/envs/lab (data \"aws_acm_certificate\") for the CloudFront distribution and the ArgoCD ALB Ingress"
  value       = aws_acm_certificate_validation.wildcard.certificate_arn
}

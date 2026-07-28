output "vpc_id" {
  description = "ID of the lab VPC"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, one per AZ"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, one per AZ"
  value       = module.vpc.private_subnet_ids
}

output "nat_gateway_id" {
  description = "ID of the single NAT Gateway shared by all private subnets"
  value       = module.vpc.nat_gateway_id
}

output "availability_zones" {
  description = "Availability zones used by this environment"
  value       = module.vpc.availability_zones
}

output "smoke_test_instance_profile_name" {
  description = "Instance profile name for ephemeral network validation instances (see scripts/validate-network.sh)"
  value       = data.aws_iam_instance_profile.network_smoke_test.name
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "API server endpoint of the EKS cluster"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the EKS cluster, used to build a kubeconfig"
  value       = module.eks.cluster_certificate_authority_data
}

output "eks_oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for the cluster, consumed by future IRSA roles"
  value       = module.eks.oidc_provider_arn
}

output "eks_oidc_provider_url" {
  description = "Issuer URL of the cluster's OIDC provider, without the https:// prefix, used in IRSA trust policy condition keys"
  value       = module.eks.oidc_provider_url
}

output "s3_video_bucket_name" {
  description = "Name of the S3 bucket storing raw uploads and HLS output"
  value       = aws_s3_bucket.video.id
}

output "app_irsa_role_arn" {
  description = "ARN of the shared IRSA role for the app's API and transcoder service accounts"
  value       = module.app_irsa.role_arn
}

output "argocd_namespace" {
  description = "Namespace where ArgoCD is installed"
  value       = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "aws_load_balancer_controller_role_arn" {
  description = "ARN of the IRSA role for the aws-load-balancer-controller add-on"
  value       = module.aws_load_balancer_controller_irsa.role_arn
}

output "external_dns_role_arn" {
  description = "ARN of the IRSA role for the external-dns add-on"
  value       = module.external_dns_irsa.role_arn
}

output "cert_manager_role_arn" {
  description = "ARN of the IRSA role for the cert-manager add-on"
  value       = module.cert_manager_irsa.role_arn
}

output "ebs_csi_driver_role_arn" {
  description = "ARN of the IRSA role for the aws-ebs-csi-driver add-on"
  value       = module.ebs_csi_driver_irsa.role_arn
}

output "grafana_role_arn" {
  description = "ARN of the IRSA role for Grafana's CloudWatch datasource"
  value       = module.grafana_irsa.role_arn
}

output "grafana_admin_password" {
  description = "Grafana admin password (terraform-generated, stable across every ArgoCD sync -- see docs/adr/011-observability-stack.md decision 12). Read via `terraform output -raw grafana_admin_password`, not `kubectl get secret`."
  value       = random_password.grafana_admin.result
  sensitive   = true
}

output "argocd_admin_password" {
  description = "ArgoCD admin password (terraform-generated, stable across every session -- see docs/runbooks/access-argocd-ui.md). Read via `terraform output -raw argocd_admin_password`, not `kubectl get secret argocd-initial-admin-secret` (pre-seeding the password this way means that secret is never populated)."
  value       = random_password.argocd_admin.result
  sensitive   = true
}

output "cloudfront_distribution_id" {
  description = "ID of the CloudFront distribution in front of the video bucket and the ALB, used by the cache invalidation and validation scripts"
  value       = aws_cloudfront_distribution.app.id
}

output "cloudfront_distribution_domain_name" {
  description = "CloudFront-assigned domain name (aliased to app.<domain_name> via aws_route53_record.app)"
  value       = aws_cloudfront_distribution.app.domain_name
}

output "app_url" {
  description = "Public HTTPS URL for the app, served via CloudFront -- the Phase 4 completion criterion"
  value       = "https://app.${var.domain_name}"
}

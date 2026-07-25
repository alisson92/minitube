output "vpc_id" {
  description = "ID of the lab VPC"
  value       = aws_vpc.lab.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, one per AZ"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, one per AZ"
  value       = aws_subnet.private[*].id
}

output "nat_gateway_id" {
  description = "ID of the single NAT Gateway shared by all private subnets"
  value       = aws_nat_gateway.lab.id
}

output "availability_zones" {
  description = "Availability zones used by this environment"
  value       = local.azs
}

output "smoke_test_instance_profile_name" {
  description = "Instance profile name for ephemeral network validation instances (see scripts/validate-network.sh)"
  value       = data.aws_iam_instance_profile.network_smoke_test.name
}

output "eks_cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.lab.name
}

output "eks_cluster_endpoint" {
  description = "API server endpoint of the EKS cluster"
  value       = aws_eks_cluster.lab.endpoint
}

output "eks_cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the EKS cluster, used to build a kubeconfig"
  value       = aws_eks_cluster.lab.certificate_authority[0].data
}

output "eks_oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for the cluster, consumed by future IRSA roles"
  value       = aws_iam_openid_connect_provider.lab.arn
}

output "eks_oidc_provider_url" {
  description = "Issuer URL of the cluster's OIDC provider, without the https:// prefix, used in IRSA trust policy condition keys"
  value       = local.oidc_provider_url
}

output "s3_video_bucket_name" {
  description = "Name of the S3 bucket storing raw uploads and HLS output"
  value       = aws_s3_bucket.video.id
}

output "app_irsa_role_arn" {
  description = "ARN of the shared IRSA role for the app's API and transcoder service accounts"
  value       = aws_iam_role.app.arn
}

output "argocd_namespace" {
  description = "Namespace where ArgoCD is installed"
  value       = kubernetes_namespace_v1.argocd.metadata[0].name
}

output "aws_load_balancer_controller_role_arn" {
  description = "ARN of the IRSA role for the aws-load-balancer-controller add-on"
  value       = aws_iam_role.aws_load_balancer_controller.arn
}

output "external_dns_role_arn" {
  description = "ARN of the IRSA role for the external-dns add-on"
  value       = aws_iam_role.external_dns.arn
}

output "cert_manager_role_arn" {
  description = "ARN of the IRSA role for the cert-manager add-on"
  value       = aws_iam_role.cert_manager.arn
}

output "ebs_csi_driver_role_arn" {
  description = "ARN of the IRSA role for the aws-ebs-csi-driver add-on"
  value       = aws_iam_role.ebs_csi_driver.arn
}

output "grafana_role_arn" {
  description = "ARN of the IRSA role for Grafana's CloudWatch datasource"
  value       = aws_iam_role.grafana.arn
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

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

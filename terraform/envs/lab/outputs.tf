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

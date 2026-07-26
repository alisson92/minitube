output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
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
  value       = aws_nat_gateway.this.id
}

output "availability_zones" {
  description = "Availability zones used by this VPC"
  value       = local.azs
}

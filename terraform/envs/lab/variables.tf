variable "project" {
  description = "Project name, used as a prefix for resource names and tags"
  type        = string
  default     = "minitube"
}

variable "aws_region" {
  description = "AWS region where the lab environment is deployed"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across. EKS requires at least 2."
  type        = number
  default     = 2
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets, one per AZ (hosts the NAT Gateway and, later, the ALB)"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == var.az_count
    error_message = "public_subnet_cidrs must have exactly az_count entries."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets, one per AZ (hosts EKS nodes and pods, sized larger for VPC CNI pod IPs)"
  type        = list(string)
  default     = ["10.0.16.0/20", "10.0.32.0/20"]

  validation {
    condition     = length(var.private_subnet_cidrs) == var.az_count
    error_message = "private_subnet_cidrs must have exactly az_count entries."
  }
}

variable "project" {
  description = "Project name, used as a prefix for resource names and tags"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster that will run inside this VPC, used to tag subnets so the cluster and the AWS Load Balancer Controller can auto-discover them (kubernetes.io/cluster/<name> = shared). Passed in rather than derived here, since naming the cluster isn't this module's concern."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across. EKS requires at least 2."
  type        = number
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets, one per AZ (hosts the NAT Gateway and, later, the ALB)"
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_cidrs) == var.az_count
    error_message = "public_subnet_cidrs must have exactly az_count entries."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets, one per AZ (hosts EKS nodes and pods, sized larger for VPC CNI pod IPs)"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_cidrs) == var.az_count
    error_message = "private_subnet_cidrs must have exactly az_count entries."
  }
}

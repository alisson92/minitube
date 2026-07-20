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

variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster. Check currently supported versions (aws eks describe-cluster-versions) before each apply — EKS drops standard support for old versions over time."
  type        = string
  default     = "1.31"
}

variable "eks_node_instance_types" {
  description = "EC2 instance types for the spot node group, in order of preference"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_node_desired_size" {
  description = "Desired number of worker nodes in the spot node group"
  type        = number
  default     = 2
}

variable "eks_node_min_size" {
  description = "Minimum number of worker nodes in the spot node group"
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "Maximum number of worker nodes in the spot node group"
  type        = number
  default     = 3
}

variable "operator_role_arn" {
  description = "IAM role ARN backing the daily operator's IAM Identity Center permission set, granted cluster-admin via an EKS access entry (aws_eks_access_entry.operator). Only changes if the cloudlab-operator permission set is recreated — find it via `aws iam get-role --role-name AWSReservedSSO_cloudlab-operator_<hash> --query Role.Arn --output text` (CloudShell/root, read-only)."
  type        = string
  default     = "arn:aws:iam::479213212405:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_cloudlab-operator_05e61e8d7c72bcd9"
}

variable "argocd_repo_ssh_private_key" {
  description = "SSH private key (OpenSSH format) for the dedicated, read-only GitHub deploy key ArgoCD uses to clone this repository. Sourced from TF_VAR_argocd_repo_ssh_private_key at apply time — never committed, never given a default. See docs/runbooks/validate-argocd-gitops.md for how to generate and register the key."
  type        = string
  sensitive   = true
}

variable "argocd_chart_version" {
  description = "Pinned version of the argo-cd Helm chart (https://artifacthub.io/packages/helm/argo/argo-cd). Check for a newer stable release before bumping."
  type        = string
  default     = "10.1.4"
}

variable "argocd_apps_chart_version" {
  description = "Pinned version of the argocd-apps Helm chart (https://artifacthub.io/packages/helm/argo/argocd-apps), used to declare the root Applications/AppProject via Terraform values instead of a manually-applied Application manifest."
  type        = string
  default     = "2.0.5"
}

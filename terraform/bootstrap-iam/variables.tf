variable "project" {
  description = "Project name, used as a prefix for resource names and tags"
  type        = string
  default     = "minitube"
}

variable "aws_region" {
  description = "AWS region for this module's resources"
  type        = string
  default     = "us-east-1"
}

variable "operator_username" {
  description = "IAM username for the daily-use Terraform operator across all personal lab projects in this account"
  type        = string
  default     = "cloudlab-operator"
}

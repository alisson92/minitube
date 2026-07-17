variable "project" {
  description = "Project name, used as a prefix for resource names and tags"
  type        = string
  default     = "minitube"
}

variable "aws_region" {
  description = "AWS region where the state bucket will be created"
  type        = string
  default     = "us-east-1"
}

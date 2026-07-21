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

variable "domain_name" {
  description = "Fully-qualified delegated subdomain for the project, used as the Route 53 hosted zone name and the ACM wildcard certificate's base domain. Not a secret (it's a public DNS name), so it's fine to commit as a default — override via TF_VAR_domain_name if ever needed. After apply, delegate this subdomain by adding the zone's NS records (see route53_zone_name_servers output) at the registrar of the root domain (projetodevops.com.br)."
  type        = string
  default     = "minitube.projetodevops.com.br"
}

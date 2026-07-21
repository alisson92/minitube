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
  description = "Fully-qualified delegated subdomain for the project (e.g. minitube.example.com), used as the Route 53 hosted zone name and the ACM wildcard certificate's base domain. Sourced from TF_VAR_domain_name at apply time — never committed, no default. After apply, delegate this subdomain by adding the zone's NS records (see route53_zone_name_servers output) at the registrar of the root domain."
  type        = string
}

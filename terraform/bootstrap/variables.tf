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

variable "argocd_repo_ssh_private_key" {
  description = "SSH private key (OpenSSH format) for the read-only GitHub deploy key ArgoCD uses to clone this repo. Only ever needs a real value on the one-time apply that (re)creates ssm.tf's aws_ssm_parameter -- its `lifecycle.ignore_changes` means Terraform never touches the stored value again after that, regardless of what this variable holds on later applies. Safe to leave at the default (empty) on every apply after the first. See docs/adr/008-cloudfront-dns-tls.md and docs/runbooks/validate/validate-argocd-gitops.md."
  type        = string
  sensitive   = true
  default     = ""
}

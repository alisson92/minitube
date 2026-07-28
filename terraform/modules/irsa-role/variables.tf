variable "role_name" {
  description = "Full name of the IAM role (this module doesn't prefix or derive it -- naming is the caller's concern)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's EKS OIDC provider (module.eks.oidc_provider_arn), used as the trust policy's Federated principal"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the cluster's EKS OIDC provider without the https:// prefix (module.eks.oidc_provider_url), used as the trust policy's condition key prefix"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace the service account(s) live in"
  type        = string
}

variable "service_account_names" {
  description = "Kubernetes service account name(s) allowed to assume this role via IRSA. Most roles need just one; the app role shares one role across api+transcoder, hence a list."
  type        = list(string)

  validation {
    condition     = length(var.service_account_names) > 0
    error_message = "service_account_names must have at least one entry."
  }
}

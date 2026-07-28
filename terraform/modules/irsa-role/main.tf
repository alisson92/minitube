# Shared trust-policy shape for every IRSA role in this project (app +
# platform add-ons, see envs/lab/iam-app.tf and envs/lab/iam-platform.tf) --
# a role assumable only by the given service account(s), via the cluster's
# own OIDC provider. Attaching the actual permissions (inline policy or
# managed policy) is left to the caller: those differ per consumer and
# aren't this module's concern.
resource "aws_iam_role" "this" {
  name = var.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "${var.oidc_provider_url}:sub" = [
            for sa in var.service_account_names :
            "system:serviceaccount:${var.namespace}:${sa}"
          ]
        }
      }
    }]
  })
}

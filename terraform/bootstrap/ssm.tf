# Persists the ArgoCD repo SSH private key across sessions, decoupled from
# envs/lab's ephemeral apply/destroy cycle -- so recreating the environment
# never requires regenerating the deploy key or re-exporting a TF_VAR by
# hand. Lives here (not bootstrap-iam) because SSM Parameter Store isn't
# restricted by the operator's PowerUserAccess policy the way IAM is.
#
# `ignore_changes` on value means this resource is only ever really written
# once: the apply that creates it needs a real
# TF_VAR_argocd_repo_ssh_private_key, but every apply after that is safe to
# run with the variable's default (empty) -- Terraform won't try to
# overwrite the stored value. Supersedes the original approach in
# docs/adr/007-argocd-gitops-bootstrap.md (decision 4), which required
# re-exporting the private key on every single session. See
# docs/adr/008-cloudfront-dns-tls.md.
resource "aws_ssm_parameter" "argocd_repo_ssh_private_key" {
  name        = "/${var.project}/argocd-repo-ssh-private-key"
  description = "Read-only GitHub deploy key ArgoCD (envs/lab) uses to clone this repo"
  type        = "SecureString"
  value       = var.argocd_repo_ssh_private_key

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "${var.project}-argocd-repo-ssh-private-key"
  }
}

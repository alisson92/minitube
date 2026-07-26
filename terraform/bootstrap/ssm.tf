# Persists the ArgoCD deploy key across sessions, decoupled from envs/lab's
# ephemeral cycle -- recreating the environment never needs regenerating it.
# `ignore_changes` on value means only the first apply needs a real
# TF_VAR_argocd_repo_ssh_private_key; every apply after that is safe with
# the empty default. See docs/adr/008-cloudfront-dns-tls.md.
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

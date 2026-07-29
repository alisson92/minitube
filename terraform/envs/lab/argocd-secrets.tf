# Generated once here, not left to the chart's own randAlphaNum default --
# under ArgoCD's stateless `helm template` per sync, that default rotates
# the password every sync while Grafana's running pod keeps the old one in
# memory. See docs/adr/011-observability-stack.md (decision 12).
resource "random_password" "grafana_admin" {
  length  = 24
  special = false # kept alphanumeric -- avoids any shell/YAML-escaping surprises when read back via `terraform output`
}

# Without this, the chart auto-generates its own initial password on first
# deploy, meaning a fresh `kubectl` lookup every session just to log in.
# Setting it here makes `terraform output -raw argocd_admin_password`
# always work, same as Grafana's above. See docs/runbooks/access-argocd-ui.md.
resource "random_password" "argocd_admin" {
  length  = 24
  special = false
}

# ArgoCD needs the password pre-seeded as a bcrypt hash (argocd-secret),
# not plaintext. Terraform's `bcrypt()` re-salts on every evaluation, so
# using it directly in helm_release.argocd's values (argocd.tf) would show
# as changed on every plan -- freezing hash+mtime here via ignore_changes
# avoids that; only recomputed when the password itself changes
# (triggers_replace).
resource "terraform_data" "argocd_admin_password_hash" {
  triggers_replace = [random_password.argocd_admin.result]

  input = {
    hash  = bcrypt(random_password.argocd_admin.result)
    mtime = timestamp()
  }

  lifecycle {
    ignore_changes = [input]
  }
}

# Delivered to Grafana via `grafana.admin.existingSecret` (see the
# kube-prometheus-stack Application in argocd-apps.tf), never as a plaintext
# `grafana.adminPassword` Helm parameter -- the ArgoCD UI masks Secret data
# by default, but does not mask helm.parameters on an Application's own
# spec, which is readable in cleartext by anyone with read RBAC on that
# Application (`kubectl get application ... -o yaml`, or the ArgoCD UI's own
# "Parameters" panel). See docs/adr/011-observability-stack.md, decision 12.
resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin-credentials"
    namespace = kubernetes_namespace_v1.platform.metadata[0].name
  }

  type = "Opaque"

  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin.result
  }
}

# Read from SSM (terraform/bootstrap/ssm.tf), not a TF_VAR, so the key
# persists across sessions instead of being re-exported each time. See
# docs/adr/008-cloudfront-dns-tls.md.
data "aws_ssm_parameter" "argocd_repo_ssh_private_key" {
  name            = "/${var.project}/argocd-repo-ssh-private-key"
  with_decryption = true
}

# Standalone resource (ArgoCD's Secret-based repository credential format)
# rather than the chart's configs.repositories value, so the key's lifecycle
# isn't coupled to argo-cd chart upgrades.
resource "kubernetes_secret_v1" "argocd_repo_credentials" {
  metadata {
    name      = "minitube-repo-ssh"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  type = "Opaque"

  data = {
    type          = "git"
    url           = local.gitops_repo_url
    sshPrivateKey = data.aws_ssm_parameter.argocd_repo_ssh_private_key.value
  }
}

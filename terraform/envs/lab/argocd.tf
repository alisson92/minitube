locals {
  argocd_namespace   = "argocd"
  platform_namespace = "minitube-platform"
  gitops_repo_url    = "git@github.com:alisson92/minitube.git"
  gitops_revision    = var.argocd_gitops_revision
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = local.argocd_namespace
    labels = {
      "app.kubernetes.io/part-of"    = "minitube"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  # No implicit ordering with module.eks -- without this, a `destroy` once
  # tore down the operator's EKS access entry before this namespace (and
  # everything depending on it), revoking kubectl mid-destroy. Forces both
  # directions: access ready (module.eks's own null_resource.wait_for_operator_access)
  # before k8s resources are created, torn down only after.
  depends_on = [module.eks]
}

# Created explicitly here (not left to the platform Applications' own
# `syncOptions: CreateNamespace=true` in argocd-apps.tf) so
# kubernetes_secret_v1.grafana_admin (argocd-secrets.tf) has somewhere to
# live at `apply` time -- ArgoCD only creates the namespace asynchronously,
# well after Terraform returns. CreateNamespace=true stays on the
# Applications too; it's a no-op once the namespace already exists.
resource "kubernetes_namespace_v1" "platform" {
  metadata {
    name = local.platform_namespace
    labels = {
      "app.kubernetes.io/part-of"    = "minitube"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = kubernetes_namespace_v1.argocd.metadata[0].name
  create_namespace = false

  values          = [file("${path.module}/values/argocd.yaml")]
  timeout         = 600
  wait            = true
  atomic          = true
  cleanup_on_fail = true

  # Stable admin login across sessions -- see random_password.argocd_admin
  # and terraform_data.argocd_admin_password_hash in argocd-secrets.tf, and
  # docs/runbooks/access-argocd-ui.md. `set`/`set_sensitive` are list
  # attributes in helm provider v3.x, not repeatable blocks like in v2.x.
  set_sensitive = [
    {
      name  = "configs.secret.argocdServerAdminPassword"
      value = terraform_data.argocd_admin_password_hash.output.hash
    },
  ]
  set = [
    {
      name  = "configs.secret.argocdServerAdminPasswordMtime"
      value = terraform_data.argocd_admin_password_hash.output.mtime
    },
  ]

  # wait=true would otherwise time out waiting for pods to schedule on a
  # spot node group that's still scaling up from zero.
  depends_on = [module.eks]
}

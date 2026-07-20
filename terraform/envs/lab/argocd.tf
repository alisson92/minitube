locals {
  argocd_namespace   = "argocd"
  platform_namespace = "minitube-platform"
  gitops_repo_url    = "git@github.com:alisson92/minitube.git"
  gitops_revision    = "main"
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = local.argocd_namespace
    labels = {
      "app.kubernetes.io/part-of"    = "minitube"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# Repository credentials in the format ArgoCD expects for a Secret-based repo
# credential (docs: Operator Manual > Declarative Setup > Repositories).
# Kept as a standalone resource rather than under the chart's
# `configs.repositories` value so the private key's lifecycle isn't coupled
# to argo-cd chart upgrades.
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
    sshPrivateKey = var.argocd_repo_ssh_private_key
  }
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

  # wait=true would otherwise time out waiting for pods to schedule on a
  # spot node group that's still scaling up from zero.
  depends_on = [aws_eks_node_group.lab_spot]
}

# Declares the root "app of apps" (2 Applications + 1 AppProject) via Helm
# values instead of a manually-applied Application manifest — the bootstrap
# itself stays declarative, closing the gap left open by ADR 006 item 7.
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  depends_on = [helm_release.argocd, kubernetes_secret_v1.argocd_repo_credentials]

  values = [yamlencode({
    projects = {
      minitube-platform = {
        namespace   = local.argocd_namespace
        description = "Platform components (kube-prometheus-stack/Loki in Phase 5). ArgoCD self-management is a future candidate, not implemented — see ADR 007."
        sourceRepos = [local.gitops_repo_url]
        destinations = [
          {
            namespace = local.platform_namespace
            server    = "https://kubernetes.default.svc"
          },
        ]
        # kube-prometheus-stack brings CRDs/ClusterRoles in Phase 5 —
        # allowing cluster-scoped resources now avoids reopening this
        # AppProject just for that later.
        clusterResourceWhitelist = [
          {
            group = "*"
            kind  = "*"
          },
        ]
      }
    }

    applications = {
      app = {
        namespace = local.argocd_namespace
        project   = "default"
        source = {
          repoURL        = local.gitops_repo_url
          targetRevision = local.gitops_revision
          path           = "gitops/app"
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "minitube-app"
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
          syncOptions = ["CreateNamespace=true"]
        }
      }

      platform = {
        namespace = local.argocd_namespace
        project   = "minitube-platform"
        source = {
          repoURL        = local.gitops_repo_url
          targetRevision = local.gitops_revision
          path           = "gitops/plataforma"
          directory = {
            recurse = true
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = local.platform_namespace
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
          syncOptions = ["CreateNamespace=true"]
        }
      }
    }
  })]
}

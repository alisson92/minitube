locals {
  argocd_namespace   = "argocd"
  platform_namespace = "minitube-platform"
  gitops_repo_url    = "git@github.com:alisson92/minitube.git"
  gitops_revision    = var.argocd_gitops_revision
}


# EKS access entries return success from CreateAccessEntry/AssociateAccessPolicy
# in ~1s, but the control plane's authorizer takes some extra seconds to
# actually start accepting the new principal -- there's no describe/wait
# call exposed by the API to confirm propagation. This never surfaced while
# bootstrap_cluster_creator_admin_permissions was true, because that grant is
# baked into cluster creation itself (~10 minutes, plenty of time to
# propagate); now that access is 100% explicit (see comment on
# aws_eks_cluster.lab in eks.tf), nothing else buffers that delay.
resource "time_sleep" "operator_access_propagation" {
  depends_on      = [aws_eks_access_entry.operator, aws_eks_access_policy_association.operator_admin]
  create_duration = "30s"
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = local.argocd_namespace
    labels = {
      "app.kubernetes.io/part-of"    = "minitube"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  # Neither resource is referenced by this one, so Terraform has no implicit
  # ordering between them -- without this, a `destroy` can (and did, once)
  # tear down the operator's EKS access entry before this namespace and
  # everything that depends on it (the repo secret, both helm_releases),
  # revoking kubectl access mid-destroy and leaving the k8s-side resources
  # stuck ("cannot delete resource secrets"). This depends_on forces the
  # correct order both ways: access granted (and propagated, via the
  # time_sleep above) before k8s resources are created, and k8s resources
  # torn down before access is revoked.
  depends_on = [time_sleep.operator_access_propagation]
}

# Read from SSM Parameter Store (terraform/bootstrap/ssm.tf), not a TF_VAR --
# the key persists across every envs/lab apply/destroy cycle instead of
# needing to be regenerated and re-exported each session. See
# docs/adr/008-cloudfront-dns-tls.md.
data "aws_ssm_parameter" "argocd_repo_ssh_private_key" {
  name            = "/${var.project}/argocd-repo-ssh-private-key"
  with_decryption = true
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
    sshPrivateKey = data.aws_ssm_parameter.argocd_repo_ssh_private_key.value
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
        # Each add-on's second source (its official Helm chart repo, Phase 4)
        # must be explicitly allow-listed here too -- AppProject.sourceRepos
        # restricts every source of every Application under this project, not
        # just the Git one. Missing this causes InvalidSpecError ("repo ...
        # is not permitted in project"), discovered on the first real sync.
        sourceRepos = [
          local.gitops_repo_url,
          "https://aws.github.io/eks-charts",
          "https://kubernetes-sigs.github.io/external-dns/",
          "https://charts.jetstack.io",
        ]
        destinations = [
          {
            namespace = local.platform_namespace
            server    = "https://kubernetes.default.svc"
          },
          {
            # gitops/plataforma/argocd/ingress.yaml (the argocd-server
            # Ingress, Phase 4) targets the argocd namespace itself, not
            # minitube-platform.
            namespace = local.argocd_namespace
            server    = "https://kubernetes.default.svc"
          },
          {
            # The cert-manager chart's leader-election Role/RoleBinding are
            # hardcoded by upstream to live in kube-system, regardless of
            # where the rest of the chart is installed -- discovered on the
            # first real sync ("namespace kube-system is not permitted").
            namespace = "kube-system"
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
            # The 3 add-ons' values.yaml files (Phase 4) are Helm value
            # files consumed as a second `ref: values` source by the
            # dedicated Applications below, not standalone K8s manifests --
            # excluded here so directory-mode doesn't try to parse them.
            exclude = "**/values.yaml"
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

      # The 3 platform add-ons below share the same multi-source shape:
      # source[0] pulls this repo's static values.yaml (Git, versioned),
      # source[1] pulls the chart straight from its official Helm repo,
      # parameterized with the ARN of the add-on's own IRSA role (known only
      # to Terraform at apply time). See docs/adr/008-cloudfront-dns-tls.md.
      "aws-load-balancer-controller" = {
        namespace = local.argocd_namespace
        project   = "minitube-platform"
        sources = [
          {
            repoURL        = local.gitops_repo_url
            targetRevision = local.gitops_revision
            ref            = "values"
          },
          {
            repoURL        = "https://aws.github.io/eks-charts"
            chart          = "aws-load-balancer-controller"
            targetRevision = var.aws_load_balancer_controller_chart_version
            helm = {
              valueFiles = ["$values/gitops/plataforma/aws-load-balancer-controller/values.yaml"]
              parameters = [
                {
                  name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
                  value = aws_iam_role.aws_load_balancer_controller.arn
                },
                {
                  # Without this, the controller falls back to discovering
                  # the VPC via EC2 instance metadata (IMDS), which fails
                  # ("context deadline exceeded") on this cluster's spot
                  # nodes -- discovered on the first real sync. The VPC ID
                  # changes every session (envs/lab is recreated from
                  # scratch), so it's injected here rather than hardcoded in
                  # gitops/plataforma/aws-load-balancer-controller/values.yaml.
                  name  = "vpcId"
                  value = aws_vpc.lab.id
                },
              ]
            }
          },
        ]
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

      "external-dns" = {
        namespace = local.argocd_namespace
        project   = "minitube-platform"
        sources = [
          {
            repoURL        = local.gitops_repo_url
            targetRevision = local.gitops_revision
            ref            = "values"
          },
          {
            repoURL        = "https://kubernetes-sigs.github.io/external-dns/"
            chart          = "external-dns"
            targetRevision = var.external_dns_chart_version
            helm = {
              valueFiles = ["$values/gitops/plataforma/external-dns/values.yaml"]
              parameters = [
                {
                  name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
                  value = aws_iam_role.external_dns.arn
                },
              ]
            }
          },
        ]
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

      "cert-manager" = {
        namespace = local.argocd_namespace
        project   = "minitube-platform"
        sources = [
          {
            repoURL        = local.gitops_repo_url
            targetRevision = local.gitops_revision
            ref            = "values"
          },
          {
            repoURL        = "https://charts.jetstack.io"
            chart          = "cert-manager"
            targetRevision = var.cert_manager_chart_version
            helm = {
              valueFiles = ["$values/gitops/plataforma/cert-manager/values.yaml"]
              parameters = [
                {
                  name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
                  value = aws_iam_role.cert_manager.arn
                },
              ]
            }
          },
        ]
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = local.platform_namespace
        }
        # retry/backoff (not sync-waves/App-of-Apps) covers the case where
        # this Application's ClusterIssuer manifest (synced by the
        # "platform" Application, a separate Application with no ordering
        # guarantee relative to this one) reconciles before the cert-manager
        # CRDs this chart installs actually exist on first sync.
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
          syncOptions = ["CreateNamespace=true"]
          retry = {
            limit = 5
            backoff = {
              duration    = "10s"
              factor      = 2
              maxDuration = "3m"
            }
          }
        }
      }
    }
  })]
}

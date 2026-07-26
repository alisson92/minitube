locals {
  argocd_namespace   = "argocd"
  platform_namespace = "minitube-platform"
  gitops_repo_url    = "git@github.com:alisson92/minitube.git"
  gitops_revision    = var.argocd_gitops_revision
}

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
# using it directly in helm_release.argocd's values would show as changed
# on every plan -- freezing hash+mtime here via ignore_changes avoids that;
# only recomputed when the password itself changes (triggers_replace).
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
  # directions: access ready (module.eks's own time_sleep) before k8s
  # resources are created, torn down only after.
  depends_on = [module.eks]
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
  # and terraform_data.argocd_admin_password_hash above, and
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

# Split out from helm_release.argocd_apps below so Terraform's dependency
# graph (not Helm's uninstall order) controls destroy ordering -- a single
# release once deleted this AppProject before the Applications referencing
# it finished pruning, permanently breaking ArgoCD ("project ... not
# found"). See docs/adr/010-lbc-orphan-cleanup-and-alb-wait.md.
resource "helm_release" "argocd_project" {
  name       = "argocd-project"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  depends_on = [helm_release.argocd]

  values = [yamlencode({
    projects = {
      minitube-platform = {
        namespace   = local.argocd_namespace
        description = "Platform components (kube-prometheus-stack/Loki in Phase 5). ArgoCD self-management is a future candidate, not implemented — see ADR 007."
        # Every add-on's chart repo must be allow-listed here too --
        # sourceRepos covers every source of every Application under this
        # project, not just the Git one. Missing one: InvalidSpecError.
        sourceRepos = [
          local.gitops_repo_url,
          "https://aws.github.io/eks-charts",
          "https://kubernetes-sigs.github.io/external-dns/",
          "https://charts.jetstack.io",
          "https://kubernetes-sigs.github.io/aws-ebs-csi-driver",
          "https://prometheus-community.github.io/helm-charts",
          "https://grafana.github.io/helm-charts",
          "https://kubernetes-sigs.github.io/metrics-server/",
        ]
        destinations = [
          {
            namespace = local.platform_namespace
            server    = "https://kubernetes.default.svc"
          },
          {
            # gitops/platform/argocd/ingress.yaml (the argocd-server
            # Ingress, Phase 4) targets the argocd namespace itself, not
            # minitube-platform.
            namespace = local.argocd_namespace
            server    = "https://kubernetes.default.svc"
          },
          {
            # cert-manager's leader-election Role/RoleBinding are hardcoded
            # by upstream to live in kube-system regardless of install namespace.
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
  })]
}

# Declares the root "app of apps" (the Applications themselves) via Helm
# values instead of a manually-applied Application manifest — the bootstrap
# itself stays declarative, closing the gap left open by ADR 006 item 7.
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  # wait=true (provider default, made explicit) blocks `destroy` until the
  # Application CRs are gone -- load-bearing since "app"/"platform" carry
  # resources-finalizer below, so this is what lets ArgoCD prune the
  # shared-ALB Ingress before the node group disappears. timeout raised for
  # that headroom. See docs/adr/010-lbc-orphan-cleanup-and-alb-wait.md.
  wait    = true
  timeout = 600

  # Nothing in this release's values references the network path or the
  # add-ons' IAM *policies* (roles are already implicit via ARNs in
  # helm.parameters below), so without this, `destroy` tore each down mid-
  # cleanup across three separate real runs -- isolated NAT gateway losing
  # egress, LBC/external-dns policies ripped away while still deregistering
  # ALB targets/DNS records. module.vpc covers the whole egress path at
  # once (see docs/adr/010-lbc-orphan-cleanup-and-alb-wait.md and
  # docs/adr/013-terraform-vpc-eks-modules.md); the ebs-csi-driver/grafana
  # policies get the same treatment pre-emptively for PVC deletion
  # (docs/adr/011-observability-stack.md), not yet confirmed to bite.
  depends_on = [
    helm_release.argocd,
    helm_release.argocd_project,
    kubernetes_secret_v1.argocd_repo_credentials,
    module.vpc,
    aws_iam_role_policy.aws_load_balancer_controller,
    aws_iam_role_policy.external_dns,
    aws_iam_role_policy_attachment.ebs_csi_driver,
    aws_iam_role_policy.grafana,
  ]

  values = [yamlencode({
    applications = {
      app = {
        namespace = local.argocd_namespace
        project   = "default"
        # Forces ArgoCD to prune this Application's managed resources
        # (gitops/app/ingress.yaml, sharing the ALB via IngressGroup) before
        # removing the Application CR itself on `destroy` -- without it,
        # deleting the CR orphans the Ingress/ALB instead of cleaning them
        # up. See docs/adr/010-lbc-orphan-cleanup-and-alb-wait.md.
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = local.gitops_repo_url
          targetRevision = local.gitops_revision
          path           = "gitops/app"
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "minitube-app"
        }
        # gitops/app/hpa.yaml PATCHes spec.replicas at runtime -- without
        # this, selfHeal would revert it to the manifest's static value on
        # every sync. Standard ArgoCD pattern for HPA-managed Deployments.
        ignoreDifferences = [
          {
            group        = "apps"
            kind         = "Deployment"
            name         = "api"
            namespace    = "minitube-app"
            jsonPointers = ["/spec/replicas"]
          },
        ]
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
        # Same rationale as applications.app above -- this Application owns
        # gitops/platform/argocd/ingress.yaml, the other Ingress sharing
        # the ALB.
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = local.gitops_repo_url
          targetRevision = local.gitops_revision
          path           = "gitops/platform"
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
              valueFiles = ["$values/gitops/platform/aws-load-balancer-controller/values.yaml"]
              parameters = [
                {
                  name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
                  value = aws_iam_role.aws_load_balancer_controller.arn
                },
                {
                  # Without this the controller falls back to VPC discovery
                  # via IMDS, which fails on this cluster's spot nodes. VPC
                  # ID changes every session, so injected here instead of
                  # hardcoded in values.yaml.
                  name  = "vpcId"
                  value = module.vpc.vpc_id
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
              valueFiles = ["$values/gitops/platform/external-dns/values.yaml"]
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
              valueFiles = ["$values/gitops/platform/cert-manager/values.yaml"]
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

      # Phase 5 (Observability): kube-prometheus-stack + Loki need a
      # dynamic StorageClass for their PVCs -- installed the same way as the
      # 3 add-ons above (multi-source Application), not via aws_eks_addon,
      # to keep a single add-on installation mechanism in this repo. Only
      # the controller needs an IRSA role (AWS API calls); the node
      # DaemonSet only formats/mounts locally.
      "ebs-csi-driver" = {
        namespace = local.argocd_namespace
        project   = "minitube-platform"
        sources = [
          {
            repoURL        = local.gitops_repo_url
            targetRevision = local.gitops_revision
            ref            = "values"
          },
          {
            repoURL        = "https://kubernetes-sigs.github.io/aws-ebs-csi-driver"
            chart          = "aws-ebs-csi-driver"
            targetRevision = var.ebs_csi_driver_chart_version
            helm = {
              valueFiles = ["$values/gitops/platform/ebs-csi-driver/values.yaml"]
              parameters = [
                {
                  name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
                  value = aws_iam_role.ebs_csi_driver.arn
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

      "kube-prometheus-stack" = {
        namespace = local.argocd_namespace
        project   = "minitube-platform"
        # Owns PVCs (Prometheus/Alertmanager storage) -- same rationale as
        # applications.app/platform above: prune them (triggering real EBS
        # volume deletion) before this Application CR disappears, not after.
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        sources = [
          {
            repoURL        = local.gitops_repo_url
            targetRevision = local.gitops_revision
            ref            = "values"
          },
          {
            repoURL        = "https://prometheus-community.github.io/helm-charts"
            chart          = "kube-prometheus-stack"
            targetRevision = var.kube_prometheus_stack_chart_version
            helm = {
              valueFiles = ["$values/gitops/platform/kube-prometheus-stack/values.yaml"]
              parameters = [
                {
                  name  = "grafana.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
                  value = aws_iam_role.grafana.arn
                },
                {
                  name  = "grafana.adminPassword"
                  value = random_password.grafana_admin.result
                },
              ]
            }
          },
        ]
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = local.platform_namespace
        }
        # retry/backoff (not sync-waves) covers the PVCs racing the
        # ebs-csi-driver Application above -- no ordering guarantee exists
        # between sibling Applications, same reasoning as cert-manager's
        # retry policy below for its ClusterIssuer.
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
          # Load-bearing: this chart's Prometheus Operator CRDs are too
          # large for client-side apply's last-applied-configuration
          # annotation (262144-byte limit) -- every CRD failed to sync
          # until this was set. See docs/adr/011-observability-stack.md.
          syncOptions = ["CreateNamespace=true", "ServerSideApply=true"]
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

      "loki" = {
        namespace = local.argocd_namespace
        project   = "minitube-platform"
        # Owns a PVC (single-binary storage) -- same rationale as
        # kube-prometheus-stack above.
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        sources = [
          {
            repoURL        = local.gitops_repo_url
            targetRevision = local.gitops_revision
            ref            = "values"
          },
          {
            repoURL        = "https://grafana.github.io/helm-charts"
            chart          = "loki"
            targetRevision = var.loki_chart_version
            helm = {
              valueFiles = ["$values/gitops/platform/loki/values.yaml"]
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

      # No IRSA role (never calls the AWS API) and no PVC (positions file
      # lives on the node's local filesystem, disposable) -- unlike the 3
      # Applications above, needs neither helm.parameters nor a finalizer.
      "promtail" = {
        namespace = local.argocd_namespace
        project   = "minitube-platform"
        sources = [
          {
            repoURL        = local.gitops_repo_url
            targetRevision = local.gitops_revision
            ref            = "values"
          },
          {
            repoURL        = "https://grafana.github.io/helm-charts"
            chart          = "promtail"
            targetRevision = var.promtail_chart_version
            helm = {
              valueFiles = ["$values/gitops/platform/promtail/values.yaml"]
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

      # Phase 6: provides the metrics.k8s.io API the HPA on the api
      # Deployment (gitops/app/hpa.yaml) reads CPU utilization from -- no HPA
      # works without it. Same shape as promtail above: no AWS API calls (pure
      # in-cluster kubelet scraping), no PVC, no IRSA role, no finalizer.
      "metrics-server" = {
        namespace = local.argocd_namespace
        project   = "minitube-platform"
        sources = [
          {
            repoURL        = local.gitops_repo_url
            targetRevision = local.gitops_revision
            ref            = "values"
          },
          {
            repoURL        = "https://kubernetes-sigs.github.io/metrics-server/"
            chart          = "metrics-server"
            targetRevision = var.metrics_server_chart_version
            helm = {
              valueFiles = ["$values/gitops/platform/metrics-server/values.yaml"]
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
    }
  })]
}

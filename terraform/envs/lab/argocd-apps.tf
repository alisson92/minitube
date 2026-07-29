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

# Destroying helm_release.argocd_apps prunes the metrics-server Application,
# but the metrics-server APIService itself (v1beta1.metrics.k8s.io,
# cluster-scoped, registered by the metrics-server chart, not by ArgoCD or
# Terraform) survives pointing at a backend that no longer exists. While
# that stale APIService exists, cluster-wide API discovery fails
# (DiscoveryFailed), which blocks the namespace-finalization controller for
# every namespace, not just metrics-server's -- stalling the argocd/platform
# namespace destroys below for 5min+ until `context deadline exceeded`.
# Previously required a manual `kubectl delete apiservice` + re-running
# `destroy` (see docs/runbooks/run-the-project.md before this fix). Uses the
# AWS CLI/kubectl directly, not the kubernetes provider, because destroy-time
# provisioners may only reference the resource's own `self` attributes --
# cluster_name/aws_region are threaded through `triggers` for that reason.
# See docs/adr/015-destroy-stale-metrics-apiservice-automation.md.
resource "null_resource" "cleanup_stale_metrics_apiservice" {
  # Must run after argocd_apps is destroyed (so the Application is already
  # pruned and the APIService is actually stale) and before the namespaces
  # are destroyed (so their finalizers don't hang). See helm_release.argocd_apps's
  # own depends_on below for the other half of this ordering.
  depends_on = [kubernetes_namespace_v1.argocd, kubernetes_namespace_v1.platform]

  triggers = {
    cluster_name = module.eks.cluster_name
    aws_region   = var.aws_region
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      kubeconfig_file=$(mktemp)
      trap 'rm -f "$kubeconfig_file"' EXIT
      aws eks update-kubeconfig \
        --name "${self.triggers.cluster_name}" \
        --region "${self.triggers.aws_region}" \
        --kubeconfig "$kubeconfig_file" >/dev/null
      kubectl --kubeconfig "$kubeconfig_file" delete apiservice v1beta1.metrics.k8s.io --ignore-not-found
    EOT
  }
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
    # Forces this release to be destroyed *before* the cleanup runs --
    # see null_resource.cleanup_stale_metrics_apiservice's own comment above.
    null_resource.cleanup_stale_metrics_apiservice,
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
        # retry/backoff covers this Application's PrometheusRule
        # (kube-prometheus-stack/slo-rules.yaml) racing the
        # kube-prometheus-stack Application's operator webhook below --
        # same "no ordering guarantee between sibling Applications" reasoning
        # as that Application's own retry policy (PVCs vs ebs-csi-driver) and
        # cert-manager's (ClusterIssuer vs CRDs). Confirmed live: on a fresh
        # cluster, the operator webhook Service had no ready endpoints yet
        # when this Application's first sync attempted to apply the
        # PrometheusRule, exhausting ArgoCD's default retries before the pod
        # came up.
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
                  value = module.aws_load_balancer_controller_irsa.role_arn
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
                  value = module.external_dns_irsa.role_arn
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
                  value = module.cert_manager_irsa.role_arn
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
                  value = module.ebs_csi_driver_irsa.role_arn
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
                  value = module.grafana_irsa.role_arn
                },
                {
                  # Points the chart at kubernetes_secret_v1.grafana_admin
                  # (argocd-secrets.tf) instead of setting
                  # grafana.adminPassword directly -- only a Secret *name*
                  # rides through this Application's spec, never the
                  # credential itself. See the comment on that resource.
                  name  = "grafana.admin.existingSecret"
                  value = kubernetes_secret_v1.grafana_admin.metadata[0].name
                },
                {
                  name  = "grafana.admin.userKey"
                  value = "admin-user"
                },
                {
                  name  = "grafana.admin.passwordKey"
                  value = "admin-password"
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

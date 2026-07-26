locals {
  argocd_namespace   = "argocd"
  platform_namespace = "minitube-platform"
  gitops_repo_url    = "git@github.com:alisson92/minitube.git"
  gitops_revision    = var.argocd_gitops_revision
}

# The kube-prometheus-stack chart auto-generates Grafana's admin password
# (randAlphaNum in its own Secret template) whenever grafana.adminPassword
# is left unset -- fine under a real `helm install`/`upgrade` (Helm's own
# release state keeps the value stable across upgrades), but NOT under
# ArgoCD: the Application here is rendered via a stateless `helm template`
# on every sync (no lookup against the live Secret), so a fresh random
# password got baked in and re-applied on every single sync, while
# Grafana's live pod only reads the secret once at startup -- the password
# a `kubectl get secret` shows and the one actually active in Grafana's
# already-running pod silently drifted apart. Confirmed on this session's
# first real login attempt: the freshly-fetched secret didn't work. Fixed
# by generating the password once here, in real Terraform state, and
# injecting it via helm.parameters (same mechanism as the IRSA role ARNs
# below) -- stable across every sync, because it isn't re-derived by the
# chart at all anymore. See docs/adr/011-observability-stack.md.
resource "random_password" "grafana_admin" {
  length  = 24
  special = false # kept alphanumeric -- avoids any shell/YAML-escaping surprises when read back via `terraform output`
}

# Same underlying problem as random_password.grafana_admin above, applied to
# ArgoCD's own admin login: helm_release.argocd (below) is a real Helm
# release Terraform manages directly -- not re-templated statelessly on
# every sync like the Applications further down -- so it wouldn't drift the
# way Grafana's did. But without this, the chart auto-generates its own
# initial password into argocd-initial-admin-secret on first deploy, which
# means fetching a fresh value via kubectl every session just to log into
# the UI (see docs/runbooks/access-argocd-ui.md's previous version). Setting
# it here instead means `terraform output -raw argocd_admin_password` always
# works, the same way it already does for Grafana.
resource "random_password" "argocd_admin" {
  length  = 24
  special = false
}

# ArgoCD only accepts the admin password pre-seeded as a bcrypt hash in
# argocd-secret (keys admin.password/admin.passwordMtime -- see the Operator
# Manual's FAQ on the admin password), not plaintext like Grafana's
# grafana.adminPassword. Terraform's own `bcrypt()` function embeds a fresh
# random salt on every evaluation (its docs warn about this explicitly), so
# passing it straight into helm_release.argocd's values would make that
# release look changed on every single future `terraform plan`, even with
# nothing real different -- freezing the computed hash (and a matching
# mtime) into state once via `terraform_data` + `ignore_changes` avoids
# that; both are only recomputed when the underlying password itself
# changes (tracked via `triggers_replace`), never on a bare re-evaluation.
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
  depends_on = [aws_eks_node_group.lab_spot]
}

# Split out from helm_release.argocd_apps below into its own release --
# discovered on a real `destroy` that a single release deletes all its
# templated resources with no ordering guarantee between different CRD
# kinds. With the AppProject and the Applications that reference it in the
# same release, `helm uninstall` deleted the AppProject before the "app"/
# "platform" Applications' resources-finalizer finished pruning, and ArgoCD
# permanently failed with `error getting app project "minitube-platform":
# ... not found` -- the Applications never finished deleting. Terraform's
# own dependency graph (see depends_on on helm_release.argocd_apps below)
# gives an explicit, reliable ordering that Helm's uninstall alone can't:
# this release is destroyed only *after* argocd_apps, so the project
# outlives every Application that references it. See
# docs/adr/010-lbc-orphan-cleanup-and-alb-wait.md.
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

  # wait=true is already the provider default (made explicit here); on
  # `destroy` it makes `helm uninstall` block until the Application CRs are
  # actually gone -- load-bearing now that "app"/"platform" carry the
  # resources-finalizer below, since that's what makes ArgoCD prune the
  # shared-ALB Ingress/TargetGroupBinding (and the LBC deprovision the ALB)
  # while the node group is still up, instead of orphaning them. timeout
  # bumped past the provider's 300s default to give that prune + AWS
  # cleanup enough headroom. See docs/adr/010-lbc-orphan-cleanup-and-alb-wait.md.
  wait    = true
  timeout = 600

  # None of the networking resources on the egress path are referenced by
  # this release's values, so nothing forced them to survive past it --
  # discovered on two separate real `destroy` runs. First attempt: only the
  # NAT gateway/private route/private associations were pinned here, but
  # the NAT gateway's own subnet is *public* -- its route to the internet
  # gateway (aws_route.public_internet_gateway) and the public route table
  # associations had no dependency on this release either, so Terraform
  # destroyed them within the first minute regardless. The NAT gateway
  # itself survived (per this fix) but sat isolated with nowhere to send
  # traffic, so the LBC pods (private subnet) still lost all AWS API
  # connectivity mid-cleanup, permanently stalling the resources-finalizer
  # the same way. Pinning the *entire* egress path -- both the private side
  # (NAT gateway, its route, its subnet associations) and the public side
  # the NAT gateway itself depends on (internet gateway, the public route,
  # its subnet associations) -- is what actually keeps egress alive for the
  # whole lifetime of this release, in both directions: created before it
  # (nodes/pods need egress from the start anyway) and destroyed only after
  # it. See docs/adr/010-lbc-orphan-cleanup-and-alb-wait.md.
  # aws_iam_role.aws_load_balancer_controller/aws_iam_role.external_dns
  # are already implicitly protected -- their ARNs are referenced directly
  # in the values below (helm.parameters), which makes this release
  # implicitly depend on them. Their *policies* (aws_iam_role_policy.*) are
  # separate resources that nothing references, so they had no such
  # protection -- discovered on a third real `destroy` where the LBC's
  # policy was ripped away mid-cleanup (role still assumable, but every
  # ELBv2 call started failing with AccessDenied instead of the earlier
  # timeout) while it was still deregistering targets and deleting the
  # shared ALB. external-dns's policy gets the same treatment pre-emptively
  # -- it needs it to delete the argocd.<domain> record for the pruned
  # argocd-server Ingress, which would otherwise silently orphan a Route53
  # record pointing at an ALB that's about to be gone.
  #
  # Same reasoning extends to the ebs-csi-driver's managed-policy attachment
  # and grafana's inline policy (Phase 5): the "kube-prometheus-stack" and
  # "loki" Applications below own PVCs, and deleting a PVC only triggers a
  # real EBS DeleteVolume call if the ebs-csi-driver controller pod is still
  # alive *and* still authorized when that happens -- the exact same race
  # class as the ALB orphan bug, just for EBS volumes instead of load
  # balancers. Not yet confirmed to bite in practice (no live ordering
  # guarantee exists between sibling Applications within this one release,
  # same gap ADR-010 decision 2 fixed for the AppProject) -- this depends_on
  # is the cheap, known-good half of the mitigation; watch for orphaned EBS
  # volumes on the first real destroy cycle (see
  # docs/adr/011-observability-stack.md).
  depends_on = [
    helm_release.argocd,
    helm_release.argocd_project,
    kubernetes_secret_v1.argocd_repo_credentials,
    aws_nat_gateway.lab,
    aws_route.private_nat_gateway,
    aws_route_table_association.private,
    aws_internet_gateway.lab,
    aws_route.public_internet_gateway,
    aws_route_table_association.public,
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
        # Phase 6: gitops/app/hpa.yaml drives spec.replicas on the api
        # Deployment directly (a HorizontalPodAutoscaler doesn't own the
        # field, it just PATCHes it in real time). Without this, selfHeal
        # would fight the HPA -- reverting replicas back to the manifest's
        # static value on every sync. Standard, ArgoCD-documented pattern
        # for a Deployment managed by an HPA.
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
                  # Without this, the controller falls back to discovering
                  # the VPC via EC2 instance metadata (IMDS), which fails
                  # ("context deadline exceeded") on this cluster's spot
                  # nodes -- discovered on the first real sync. The VPC ID
                  # changes every session (envs/lab is recreated from
                  # scratch), so it's injected here rather than hardcoded in
                  # gitops/platform/aws-load-balancer-controller/values.yaml.
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
          # ServerSideApply=true is load-bearing, not a style choice: the
          # Prometheus Operator CRDs (prometheuses/alertmanagers/etc.) this
          # chart installs are large enough that client-side apply's
          # kubectl.kubernetes.io/last-applied-configuration annotation
          # exceeds Kubernetes' 262144-byte limit -- discovered on the first
          # real sync (SyncFailed on every CRD, then every Prometheus/
          # Alertmanager CR cascading with "no matches for kind ... ensure
          # CRDs are installed first", since the CRDs never actually
          # applied). Server-side apply doesn't use that annotation at all.
          # See docs/adr/011-observability-stack.md.
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

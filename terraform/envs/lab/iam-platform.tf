# IRSA roles for the platform add-ons. Live here, not in bootstrap-iam, for
# the same reason as module.app_irsa (iam-app.tf): trust policy bound to
# this cluster's OIDC provider, recreated every session. Requires the
# "ManagePlatformIrsaRoles" grant in terraform/bootstrap-iam/main.tf. See
# docs/adr/008-cloudfront-dns-tls.md. Trust-policy shape shared via
# ../../modules/irsa-role.
locals {
  platform_service_accounts = {
    aws_load_balancer_controller = "aws-load-balancer-controller"
    external_dns                 = "external-dns"
    cert_manager                 = "cert-manager"
    # Chart's own default SA name, not overridden in
    # gitops/platform/ebs-csi-driver/values.yaml.
    ebs_csi_driver = "ebs-csi-controller-sa"
    # Overridden explicitly via grafana.serviceAccount.name in
    # gitops/platform/kube-prometheus-stack/values.yaml, instead of relying
    # on the chart's release-name-derived default -- keeps this trust policy
    # stable regardless of what the Application/release is named.
    grafana = "grafana"
  }
}

module "aws_load_balancer_controller_irsa" {
  source = "../../modules/irsa-role"

  role_name             = "${var.project}-platform-lbc-irsa-role"
  oidc_provider_arn     = module.eks.oidc_provider_arn
  oidc_provider_url     = local.oidc_provider_url
  namespace             = local.platform_namespace
  service_account_names = [local.platform_service_accounts.aws_load_balancer_controller]
}

# Vendored from the upstream install guide
# (https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/installation/)
# rather than hand-trimmed -- it's broad on purpose (covers every annotation
# combination the controller might see) and drifting from upstream is a
# common source of subtle permission bugs. Re-download before bumping
# var.aws_load_balancer_controller_chart_version to a new minor version.
resource "aws_iam_role_policy" "aws_load_balancer_controller" {
  name   = "${var.project}-platform-lbc-policy"
  role   = module.aws_load_balancer_controller_irsa.role_id
  policy = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
}

module "external_dns_irsa" {
  source = "../../modules/irsa-role"

  role_name             = "${var.project}-platform-external-dns-irsa-role"
  oidc_provider_arn     = module.eks.oidc_provider_arn
  oidc_provider_url     = local.oidc_provider_url
  namespace             = local.platform_namespace
  service_account_names = [local.platform_service_accounts.external_dns]
}

resource "aws_iam_role_policy" "external_dns" {
  name = "${var.project}-platform-external-dns-policy"
  role = module.external_dns_irsa.role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "route53:ChangeResourceRecordSets"
        Resource = "arn:aws:route53:::hostedzone/${data.aws_route53_zone.minitube.zone_id}"
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets"]
        Resource = "*"
      },
    ]
  })
}

module "cert_manager_irsa" {
  source = "../../modules/irsa-role"

  role_name             = "${var.project}-platform-cert-manager-irsa-role"
  oidc_provider_arn     = module.eks.oidc_provider_arn
  oidc_provider_url     = local.oidc_provider_url
  namespace             = local.platform_namespace
  service_account_names = [local.platform_service_accounts.cert_manager]
}

# Scoped for the DNS-01 challenge against Route53 only (docs:
# https://cert-manager.io/docs/configuration/acme/dns01/route53/) -- no
# consumer issues a real Certificate from this ClusterIssuer yet in this
# phase (see docs/adr/008-cloudfront-dns-tls.md), but the IAM side is fully
# functional so the ClusterIssuer itself reaches Ready.
resource "aws_iam_role_policy" "cert_manager" {
  name = "${var.project}-platform-cert-manager-policy"
  role = module.cert_manager_irsa.role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        Resource = "arn:aws:route53:::hostedzone/${data.aws_route53_zone.minitube.zone_id}"
      },
      {
        Effect   = "Allow"
        Action   = "route53:ListHostedZonesByName"
        Resource = "*"
      },
    ]
  })
}

module "ebs_csi_driver_irsa" {
  source = "../../modules/irsa-role"

  role_name             = "${var.project}-platform-ebs-csi-irsa-role"
  oidc_provider_arn     = module.eks.oidc_provider_arn
  oidc_provider_url     = local.oidc_provider_url
  namespace             = local.platform_namespace
  service_account_names = [local.platform_service_accounts.ebs_csi_driver]
}

# AWS-managed policy (the officially documented way to grant this driver),
# not an inline policy like the other 3 add-ons above -- requires the
# "AttachEbsCsiManagedPolicy" grant in terraform/bootstrap-iam/main.tf, which
# only permits attaching this exact managed policy ARN.
resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = module.ebs_csi_driver_irsa.role_name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "grafana_irsa" {
  source = "../../modules/irsa-role"

  role_name             = "${var.project}-platform-grafana-irsa-role"
  oidc_provider_arn     = module.eks.oidc_provider_arn
  oidc_provider_url     = local.oidc_provider_url
  namespace             = local.platform_namespace
  service_account_names = [local.platform_service_accounts.grafana]
}

# Read-only access for the CloudWatch datasource -- CDN hit ratio and ALB
# errors live there, not in Prometheus. Scoped to exactly what Grafana's
# CloudWatch plugin needs, not the broader CloudWatchReadOnlyAccess managed
# policy. These actions don't support resource-level scoping.
resource "aws_iam_role_policy" "grafana" {
  name = "${var.project}-platform-grafana-policy"
  role = module.grafana_irsa.role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarmsForMetric",
          "tag:GetResources",
        ]
        Resource = "*"
      },
    ]
  })
}

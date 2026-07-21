# IRSA roles for the 3 platform add-ons (aws-load-balancer-controller,
# external-dns, cert-manager). Live here, not in bootstrap-iam, for the same
# reason as aws_iam_role.app (iam-app.tf): their trust policy is bound to
# this cluster's OIDC provider, recreated every session. Requires the
# "ManagePlatformIrsaRoles" grant in terraform/bootstrap-iam/main.tf, scoped
# by the "${var.project}-platform-*" name prefix. See
# docs/adr/008-cloudfront-dns-tls.md.
locals {
  platform_service_accounts = {
    aws_load_balancer_controller = "aws-load-balancer-controller"
    external_dns                 = "external-dns"
    cert_manager                 = "cert-manager"
  }
}

resource "aws_iam_role" "aws_load_balancer_controller" {
  name = "${var.project}-platform-lbc-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.lab.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "${local.oidc_provider_url}:aud" = "sts.amazonaws.com" }
        StringLike   = { "${local.oidc_provider_url}:sub" = "system:serviceaccount:${local.platform_namespace}:${local.platform_service_accounts.aws_load_balancer_controller}" }
      }
    }]
  })
}

# Vendored from the upstream install guide
# (https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/installation/)
# rather than hand-trimmed -- it's broad on purpose (covers every annotation
# combination the controller might see) and drifting from upstream is a
# common source of subtle permission bugs. Re-download before bumping
# var.aws_load_balancer_controller_chart_version to a new minor version.
resource "aws_iam_role_policy" "aws_load_balancer_controller" {
  name   = "${var.project}-platform-lbc-policy"
  role   = aws_iam_role.aws_load_balancer_controller.id
  policy = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
}

resource "aws_iam_role" "external_dns" {
  name = "${var.project}-platform-external-dns-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.lab.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "${local.oidc_provider_url}:aud" = "sts.amazonaws.com" }
        StringLike   = { "${local.oidc_provider_url}:sub" = "system:serviceaccount:${local.platform_namespace}:${local.platform_service_accounts.external_dns}" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "external_dns" {
  name = "${var.project}-platform-external-dns-policy"
  role = aws_iam_role.external_dns.id

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

resource "aws_iam_role" "cert_manager" {
  name = "${var.project}-platform-cert-manager-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.lab.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "${local.oidc_provider_url}:aud" = "sts.amazonaws.com" }
        StringLike   = { "${local.oidc_provider_url}:sub" = "system:serviceaccount:${local.platform_namespace}:${local.platform_service_accounts.cert_manager}" }
      }
    }]
  })
}

# Scoped for the DNS-01 challenge against Route53 only (docs:
# https://cert-manager.io/docs/configuration/acme/dns01/route53/) -- no
# consumer issues a real Certificate from this ClusterIssuer yet in this
# phase (see docs/adr/008-cloudfront-dns-tls.md), but the IAM side is fully
# functional so the ClusterIssuer itself reaches Ready.
resource "aws_iam_role_policy" "cert_manager" {
  name = "${var.project}-platform-cert-manager-policy"
  role = aws_iam_role.cert_manager.id

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

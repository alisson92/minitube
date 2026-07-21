# CloudFront distribution: default behavior serves HLS segments straight
# from S3 (edge cache is the whole point of the project, see
# docs/000-motivation.md); /api/* is routed uncached to the ALB the
# aws-load-balancer-controller provisions from gitops/app/ingress.yaml.
# app.<domain_name> aliased here is the Phase 4 completion criterion.
# See docs/adr/008-cloudfront-dns-tls.md.

# OAC, not the deprecated OAI, per current AWS guidance.
resource "aws_cloudfront_origin_access_control" "video" {
  name                              = "${var.project}-video-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Grants CloudFront read access to HLS output only (not raw/, which never
# needs to be served publicly). Scoped to this specific distribution's ARN
# via the source-arn condition, so no other distribution in the account
# could read this bucket even if one existed.
resource "aws_s3_bucket_policy" "video_cloudfront_read" {
  bucket = aws_s3_bucket.video.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.video.arn}/hls/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.app.arn }
      }
    }]
  })
}

# Referenced by name (not hardcoded IDs) -- these are AWS-managed policies,
# safer to resolve by their documented names than to copy UUIDs from memory.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# The ALB is provisioned dynamically by the aws-load-balancer-controller
# from gitops/app/ingress.yaml (via the IngressGroup shared with
# gitops/plataforma/argocd/ingress.yaml), not by Terraform -- so its DNS
# name can't be known until the controller has actually reconciled the
# Ingress. `alb.ingress.kubernetes.io/load-balancer-name: minitube-app` on
# that Ingress pins a predictable name, making this lookup by name instead
# of guessing the controller's auto-generated tag values.
#
# Known chicken-and-egg consequence: on a brand-new environment, the very
# first `terraform apply` creates helm_release.argocd_apps (which starts the
# add-ons + Ingress reconciling) in the SAME run this data source is read in,
# so the ALB may not exist yet. If this data source errors ("no matching
# load balancer found"), wait ~1-2 min for the controller to finish
# provisioning it (`aws elbv2 describe-load-balancers --names minitube-app`),
# then re-run `terraform apply` -- same two-phase-apply pattern already used
# for the initial ArgoCD bootstrap, see ADR 007 decision 8.
data "aws_lb" "app_shared" {
  name = "minitube-app"

  depends_on = [helm_release.argocd_apps]
}

resource "aws_cloudfront_distribution" "app" {
  enabled     = true
  price_class = "PriceClass_100" # US/Europe only -- a lab doesn't need global edge coverage
  aliases     = ["app.${var.domain_name}"]

  origin {
    origin_id                = "s3-video"
    domain_name              = aws_s3_bucket.video.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.video.id
  }

  origin {
    origin_id   = "alb-api"
    domain_name = data.aws_lb.app_shared.dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-video"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "alb-api"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.wildcard.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name = "${var.project}-app"
  }
}

# Created via Terraform, not external-dns: the CloudFront distribution is
# itself a Terraform-managed resource, so its DNS record can be too. Only
# argocd.<domain_name>, pointing at the dynamically-provisioned ALB, needs
# external-dns.
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.minitube.zone_id
  name    = "app.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}

# Static showcase page for the project's architecture (interactive version
# of docs/architecture.md, aimed at LinkedIn/portfolio visitors). Lives here,
# not envs/lab, on purpose: the whole point is staying reachable even with
# envs/lab destroyed (the project's normal resting state between sessions).
# Same S3+OAC+CloudFront shape already validated in envs/lab/cloudfront.tf's
# "s3-video" origin, reusing this state's own hosted zone/ACM cert directly
# instead of a cross-module data source. See docs/adr/017-persistent-architecture-showcase-site.md.

resource "aws_s3_bucket" "architecture_site" {
  bucket = "${var.project}-architecture-site-${data.aws_caller_identity.current.account_id}"

  tags = {
    purpose = "architecture-showcase-site"
  }
}

resource "aws_s3_bucket_public_access_block" "architecture_site" {
  bucket = aws_s3_bucket.architecture_site.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "architecture_site" {
  bucket = aws_s3_bucket.architecture_site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_cloudfront_origin_access_control" "architecture_site" {
  name                              = "${var.project}-architecture-site-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Scoped to this specific distribution's ARN via the source-arn condition,
# same pattern as envs/lab's video bucket policy -- no other distribution in
# the account could read this bucket even if one existed.
resource "aws_s3_bucket_policy" "architecture_site_cloudfront_read" {
  bucket = aws_s3_bucket.architecture_site.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.architecture_site.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.architecture_site.arn }
      }
    }]
  })
}

data "aws_cloudfront_cache_policy" "architecture_site_caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "architecture_site" {
  enabled             = true
  price_class         = "PriceClass_100" # US/Europe only -- a portfolio page doesn't need global edge coverage
  aliases             = ["system-design.${var.domain_name}"]
  default_root_object = "index.html"

  origin {
    origin_id                = "s3-architecture-site"
    domain_name              = aws_s3_bucket.architecture_site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.architecture_site.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-architecture-site"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.architecture_site_caching_optimized.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Same state as the certificate itself -- referenced directly, no
  # cross-module data source needed (unlike envs/lab/cloudfront.tf).
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.wildcard.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name = "${var.project}-architecture-site"
  }
}

resource "aws_route53_record" "architecture_site" {
  zone_id = aws_route53_zone.minitube.zone_id
  name    = "system-design.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.architecture_site.domain_name
    zone_id                = aws_cloudfront_distribution.architecture_site.hosted_zone_id
    evaluate_target_health = false
  }
}

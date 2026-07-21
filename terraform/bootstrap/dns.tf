# Hosted zone and TLS certificate for the project's delegated subdomain.
# Persistent by design, like the state bucket and ECR: Route 53 zones and
# ACM certificates aren't restricted by the operator's PowerUserAccess
# policy, and re-issuing them every session would mean re-delegating NS
# records at the domain registrar (a manual, non-instant step) on every
# apply. See docs/adr/008-cloudfront-dns-tls.md.
resource "aws_route53_zone" "minitube" {
  name = var.domain_name

  tags = {
    purpose = "minitube-lab-subdomain"
  }
}

# CloudFront requires the certificate to be in us-east-1 regardless of where
# the distribution's origins live. This module's aws_region already defaults
# to us-east-1 (same as terraform/envs/lab) — if that ever changes, this
# certificate would need its own provider alias pinned to us-east-1.
resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.${var.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "wildcard_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = aws_route53_zone.minitube.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

# Blocks this apply until ACM actually issues the certificate (DNS
# propagation + Let's Encrypt-style validation, typically a few minutes).
# A cost paid once here, not on every envs/lab session, since this module
# isn't part of the ephemeral apply/destroy cycle.
resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for record in aws_route53_record.wildcard_validation : record.fqdn]
}

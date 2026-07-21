# Looks up the hosted zone and wildcard certificate created in
# terraform/bootstrap/ (persistent, outside this module's ephemeral
# apply/destroy cycle). Deliberately a `data` source, not
# `terraform_remote_state`: envs/lab is destroyed every session while
# bootstrap/ isn't, and ADR 006 already rejected coupling modules with
# different lifecycles via remote state for the same reason. See
# docs/adr/008-cloudfront-dns-tls.md.
data "aws_route53_zone" "minitube" {
  name = var.domain_name
}

data "aws_acm_certificate" "wildcard" {
  domain      = "*.${var.domain_name}"
  statuses    = ["ISSUED"]
  most_recent = true
}

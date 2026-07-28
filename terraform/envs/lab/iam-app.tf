# IRSA role for the app workloads (API + transcoder). Lives here, not in
# bootstrap-iam, because its trust policy is bound to this cluster's OIDC
# provider, recreated every session (see "ManageAppIrsaRoles" in
# terraform/bootstrap-iam/main.tf and docs/adr/006-app-irsa-and-job-orchestration.md).
# One shared role for both: same bucket, same policy shape, no real
# isolation gained from splitting them. Names must match
# gitops/app/serviceaccount-{api,transcoder}.yaml.
locals {
  oidc_provider_url         = module.eks.oidc_provider_url
  app_namespace             = "minitube-app"
  app_service_account_names = ["api", "transcoder"]
}

# Must start with "${var.project}-app-" to fall inside the prefix the
# operator was granted (ManageAppIrsaRoles statement).
module "app_irsa" {
  source = "../../modules/irsa-role"

  role_name             = "${var.project}-app-irsa-role"
  oidc_provider_arn     = module.eks.oidc_provider_arn
  oidc_provider_url     = local.oidc_provider_url
  namespace             = local.app_namespace
  service_account_names = local.app_service_account_names
}

resource "aws_iam_role_policy" "app_video_bucket" {
  name = "${var.project}-app-video-bucket-access"
  role = module.app_irsa.role_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.video.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = aws_s3_bucket.video.arn
      },
    ]
  })
}

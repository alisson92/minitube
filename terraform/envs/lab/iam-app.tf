# IRSA role for the app workloads (API + transcoder). Lives here, not in
# bootstrap-iam, because its trust policy is bound to this cluster's OIDC
# provider (aws_iam_openid_connect_provider.lab, in eks.tf) — a resource
# that's recreated every session along with the rest of envs/lab. Creating it
# here keeps the whole app stack on one apply/destroy cycle, at the cost of a
# one-time, narrowly-scoped IAM grant to the daily operator (see the
# "ManageAppIrsaRoles" statement in terraform/bootstrap-iam/main.tf and
# docs/adr/006-app-irsa-and-job-orchestration.md).
#
# One shared role for both workloads: the API only writes to raw/, the
# transcoder reads raw/ and writes hls/ — same bucket, same policy shape, so
# two near-identical roles wouldn't buy any real isolation at this stage.
# Trust policy accepts both service accounts; names must match
# gitops/app/serviceaccount-api.yaml and gitops/app/serviceaccount-transcoder.yaml.
locals {
  oidc_provider_url         = replace(aws_iam_openid_connect_provider.lab.url, "https://", "")
  app_namespace             = "minitube-app"
  app_service_account_names = ["api", "transcoder"]
}

resource "aws_iam_role" "app" {
  # Must start with "${var.project}-app-" to fall inside the prefix the
  # operator was granted (ManageAppIrsaRoles statement).
  name = "${var.project}-app-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.lab.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "${local.oidc_provider_url}:sub" = [
            for sa in local.app_service_account_names :
            "system:serviceaccount:${local.app_namespace}:${sa}"
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "app_video_bucket" {
  name = "${var.project}-app-video-bucket-access"
  role = aws_iam_role.app.id

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

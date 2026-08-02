provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project        = var.project
      managed-by     = "terraform"
      terraform-path = "terraform/bootstrap"
    }
  }
}

# Used to build a globally unique bucket name without hardcoding the account ID.
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "terraform_state" {
  bucket = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"

  tags = {
    purpose = "terraform-state"
  }

  # No longer a persistence exception: prevent_destroy was removed to allow
  # a full teardown of terraform/bootstrap/ after a budget overrun.
  # force_destroy so `terraform destroy` doesn't fail on remaining state
  # object versions (versioning is enabled below).
  # See docs/adr/001-terraform-state-backend.md#update.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  policy = data.aws_iam_policy_document.terraform_state.json
}

data "aws_iam_policy_document" "terraform_state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.terraform_state.arn,
      "${aws_s3_bucket.terraform_state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    # Avoids unbounded storage cost growth from the state version history.
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

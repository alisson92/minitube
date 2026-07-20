# Used to build a globally unique bucket name without hardcoding the account ID.
data "aws_caller_identity" "current" {}

# Video storage: raw uploads (short-lived) and HLS output (segments + playlists).
# Ephemeral by design, unlike the Terraform state bucket — force_destroy lets
# `terraform destroy` remove it even with test objects still inside.
resource "aws_s3_bucket" "video" {
  bucket        = "${var.project}-video-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "${var.project}-video"
  }
}

resource "aws_s3_bucket_public_access_block" "video" {
  bucket = aws_s3_bucket.video.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "video" {
  bucket = aws_s3_bucket.video.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "video" {
  bucket = aws_s3_bucket.video.id

  rule {
    id     = "expire-raw-uploads"
    status = "Enabled"

    filter {
      prefix = "raw/"
    }

    # Raw uploads are only needed until the transcoder job reads them.
    expiration {
      days = 1
    }
  }
}

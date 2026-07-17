terraform {
  required_version = "~> 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Admin-only module: apply exclusively via AWS CloudShell / root session.
  # cloudlab-operator's PowerUserAccess intentionally excludes IAM.
  # See docs/adr/002-aws-account-and-iam-bootstrap.md.
  backend "s3" {
    bucket       = "minitube-tfstate-479213212405"
    key          = "bootstrap-iam/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

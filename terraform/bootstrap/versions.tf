terraform {
  required_version = "~> 1.14"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Local backend on purpose: creates the bucket the remote backend needs.
  # Migration steps: docs/runbooks/bootstrap-remote-backend.md.
}

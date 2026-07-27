terraform {
  # Deliberately more lenient than the root module's constraint (envs/lab
  # pins `~> 1.14`) -- a reusable module should only assert the floor it
  # actually needs, not duplicate the caller's exact pin.
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

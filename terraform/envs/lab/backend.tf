terraform {
  backend "s3" {
    bucket       = "minitube-tfstate-479213212405"
    key          = "envs/lab/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

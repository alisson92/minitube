# Runbook — Terraform remote backend

> See the decision in [`docs/adr/001-terraform-state-backend.md`](../../adr/001-terraform-state-backend.md).

## Bucket creation

The state bucket is created together with the account/IAM bootstrap — see [`docs/runbooks/bootstrap/aws-account-bootstrap.md`](aws-account-bootstrap.md) (steps 4-7). This runbook covers only the **use** of the already-created backend.

## Using the backend in a new environment

In each new environment (e.g. `terraform/envs/lab/backend.tf`):

```hcl
terraform {
  backend "s3" {
    bucket       = "minitube-tfstate-<account-id>"
    key          = "envs/lab/terraform.tfstate"   # unique key per environment
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
```

Each environment uses its own `key` within the same bucket — there's no need for one bucket per environment.

## Verification

```bash
aws s3api get-bucket-versioning --profile cloudlab --bucket minitube-tfstate-<account-id>
aws s3api get-bucket-encryption --profile cloudlab --bucket minitube-tfstate-<account-id>
aws s3api get-public-access-block --profile cloudlab --bucket minitube-tfstate-<account-id>
```

Confirm: versioning `Enabled`, encryption `AES256`, all 4 public-access-block flags `true`.

## Rollback

This bucket has `prevent_destroy = true` on purpose (see ADR 001). To actually destroy it (e.g. when shutting down the project entirely), you need to remove that guard in the code, commit the change, and only then run `terraform destroy` — never via the console.

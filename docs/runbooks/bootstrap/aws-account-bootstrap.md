# Runbook — Bootstrapping a new AWS account

> One-time procedure per AWS account. See the decision in [`docs/adr/002-aws-account-and-iam-bootstrap.md`](../../adr/002-aws-account-and-iam-bootstrap.md) and [`docs/adr/003-cloudlab-operator-sso-migration.md`](../../adr/003-cloudlab-operator-sso-migration.md).

## Step 1 — Account and root (manual, outside any automation)

1. Create a dedicated email address (e.g. `alisson.cloudlab@gmail.com`).
2. Create the AWS account at https://aws.amazon.com/pt/ with that email.
3. Log in as root → set a strong password → save it in a password manager.
4. Enable MFA on root (console → Security credentials → Assign MFA device).

## Step 2 — Open CloudShell

In the AWS console, click the CloudShell icon (top of the page). The session inherits the temporary credentials from the root login — no root access key is created.

⚠️ **Configure a shared provider cache before any `terraform init`.** CloudShell has only 1 GB of persistent storage in `$HOME` (an AWS limit, not a project one). Steps 6 and 7 run `terraform init` in two different directories (`bootstrap-iam/` and `bootstrap/`) in the same session — without a shared cache, each one downloads its own copy of the `hashicorp/aws` provider (~500 MB) and the disk fills up, causing `Error: Failed to install provider ... no space left on device`. Avoid this by setting:

```bash
mkdir -p ~/.terraform.d/plugin-cache
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
```

before the first `terraform init` of the session. This way the provider is downloaded only once and reused by every module.

## Step 3 — Clone the repository

```bash
gh auth login   # required if the repository is private (device flow, no SSH key)
gh repo clone alisson92/minitube
cd minitube
git checkout feat/terraform-bootstrap   # or main, if already merged
```

## Step 4 — Enable IAM Identity Center (manual, console)

Account-level service activation — AWS doesn't expose this via Terraform:

1. AWS Console → IAM Identity Center → "Enable".
2. Confirm the identity source stays as "Identity Center directory" (internal identity store, no external AD/IdP).
3. Under "Settings", note the **AWS access portal URL** (`https://<subdomain>.awsapps.com/start`) — it will be used in step 8.

## Step 5 — Create the operator user in Identity Center (manual, console)

1. Console → IAM Identity Center → Users → Add user.
2. Username/email: `alisson.cloudlab@gmail.com`.
3. Accept the invitation email and set a password + MFA.

Creating the user via Terraform (`aws_identitystore_user`) doesn't trigger this invitation/activation flow — that's why this step is manual, once per account.

## Step 6 — Apply `bootstrap-iam` (everything that requires admin permissions)

Needs to run with the root/CloudShell session — not just the permission set itself, but **every administrative resource accumulated throughout the project** that the daily operator's `PowerUserAccess` can't reach (`aws_ssoadmin_*`/`aws_identitystore_*` because they're IAM Identity Center resources; everything else because `PowerUserAccess` deliberately excludes IAM, including reads). Today that includes:

- The `cloudlab-operator` permission set + `PowerUserAccess` policy + account assignment (the only item that existed in Phase 1, ADR 002/003).
- The EKS roles (`minitube-eks-cluster-role`, `minitube-eks-node-role`) + the EKS service-linked roles (ADR 004).
- The smoke-test role (`minitube-network-smoke-test`) used by the functional validation scripts.
- The account budget alert (ADR 005).
- The permission set's single inline policy (`operator_pass_roles`) — seven `Statement`s accumulated phase by phase, granting the daily operator exactly what's needed to pass/manage these roles and the IRSA roles it creates itself in `envs/lab` (app, platform, OIDC provider, EBS CSI).

This isn't a one-off step just for this phase — it's reapplied (the same `terraform apply`) whenever a future session needs a new permission here; none of it requires steps 4-5 again (Identity Center/user), only this one:

```bash
cd terraform/bootstrap-iam
terraform init
terraform plan       # review: all the resources above, on a fresh account
terraform apply       # confirm manually (yes)
```

No sensitive value is generated in this step — no access key to copy.

## Step 7 — Apply `bootstrap` (state bucket)

Still in CloudShell, with the same root session (`cloudlab-operator` doesn't yet have the bucket to use for itself afterward):

```bash
cd ../bootstrap
terraform init
terraform plan       # review: versioned/encrypted S3 bucket with no public access
terraform apply       # confirm manually (yes)
```

## Step 8 — Configure the local profile via SSO

On your local machine (not CloudShell), create an `sso-session` dedicated to the `cloudlab` account in `~/.aws/config`:

```ini
[profile cloudlab]
sso_session = cloudlab
sso_account_id = <cloudlab account id>
sso_role_name  = cloudlab-operator
region = us-east-1
output = json

[sso-session cloudlab]
sso_start_url = https://<subdomain-from-step-4>.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

⚠️ **Before testing, remove any old static access key from `~/.aws/credentials` for the `cloudlab` profile** (from the `aws configure` used before this migration). The AWS CLI/SDK prioritizes `aws_access_key_id`/`aws_secret_access_key` from `~/.aws/credentials` over the `sso_session` in `~/.aws/config` when both exist for the same profile — if the old key (already destroyed in step 6) is left behind, the result is `InvalidClientTokenId: The security token included in the request is invalid`, even with SSO configured correctly.

Then:

```bash
aws sso login --profile cloudlab
aws sts get-caller-identity --profile cloudlab   # should return the permission set's assumed-role
```

Use `AWS_PROFILE=cloudlab` (or `--profile cloudlab`) on every Terraform/AWS CLI command in the project from here on. The session expires on its own — repeat `aws sso login --profile cloudlab` when it does.

## Step 9 — Connect the local Terraform to the remote backend

In local `terraform/bootstrap/` (`backend.tf` already points to the bucket created in step 7):

```bash
AWS_PROFILE=cloudlab terraform init
AWS_PROFILE=cloudlab terraform plan   # should show "No changes"
```

`terraform/bootstrap-iam/` **cannot** run locally with `cloudlab-operator` — see the permanent rule below.

## Permanent rule

`terraform/bootstrap-iam/` can only be planned/applied with a root/CloudShell session — `cloudlab-operator`'s `PowerUserAccess` deliberately excludes IAM, and the IAM Identity Center resources require permissions that also aren't in that policy. Any future change there (new permission set, new user) repeats steps 4-6. Everything else in the project — state bucket, VPC, EKS, CloudFront, DNS — runs with `cloudlab-operator` via SSO, locally, without the console.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project        = var.project
      managed-by     = "terraform"
      terraform-path = "terraform/bootstrap-iam"
    }
  }
}

data "aws_caller_identity" "current" {}

# Requires IAM Identity Center already enabled and the operator user already
# created via the console (one-time manual steps — see
# docs/runbooks/aws-account-bootstrap.md). Terraform only wires the
# permission set and the account assignment on top of that.
data "aws_ssoadmin_instances" "this" {}

data "aws_identitystore_user" "operator" {
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = var.operator_sso_username
    }
  }
}

# PowerUserAccess: broad service access, excludes IAM/Organizations management.
# See docs/adr/002-aws-account-and-iam-bootstrap.md and
# docs/adr/003-cloudlab-operator-sso-migration.md.
resource "aws_ssoadmin_permission_set" "operator" {
  name             = var.operator_username
  description      = "Daily operator access for MiniTube Terraform work (PowerUserAccess-equivalent)"
  instance_arn     = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  session_duration = "PT4H"
}

resource "aws_ssoadmin_managed_policy_attachment" "operator_power_user" {
  instance_arn       = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  managed_policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
  permission_set_arn = aws_ssoadmin_permission_set.operator.arn
}

resource "aws_ssoadmin_account_assignment" "operator" {
  # Managed policy attachment destruction re-provisions the permission set;
  # keep this explicit so destroy order is safe on teardown.
  depends_on = [aws_ssoadmin_managed_policy_attachment.operator_power_user]

  instance_arn       = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  permission_set_arn = aws_ssoadmin_permission_set.operator.arn

  principal_id   = data.aws_identitystore_user.operator.user_id
  principal_type = "USER"

  target_id   = data.aws_caller_identity.current.account_id
  target_type = "AWS_ACCOUNT"
}

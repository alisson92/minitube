variable "operator_username" {
  description = "IAM username for the daily-use Terraform operator across all personal lab projects in this account"
  type        = string
  default     = "cloudlab-operator"
}

resource "aws_iam_user" "operator" {
  name = var.operator_username

  tags = {
    purpose = "terraform-operator"
  }
}

# PowerUserAccess: broad service access, excludes IAM/Organizations management.
# See docs/adr/002-aws-account-and-iam-bootstrap.md.
resource "aws_iam_user_policy_attachment" "operator_power_user" {
  user       = aws_iam_user.operator.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_access_key" "operator" {
  user = aws_iam_user.operator.name
}

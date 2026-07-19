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

# Instance role for ephemeral EC2 smoke-test instances (SSM Session Manager
# access, no SSH/bastion). Lives here, not in envs/lab, because PowerUserAccess
# denies ALL IAM actions to the daily operator, including reads (verified:
# iam:GetRole/GetInstanceProfile/PassRole all return AccessDenied). The inline
# policy below grants back just enough to use this one role. Reusable across
# future validation scripts (EKS, etc.), not just the VPC network test.
resource "aws_iam_role" "network_smoke_test" {
  name = "${var.project}-network-smoke-test"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "network_smoke_test_ssm" {
  role       = aws_iam_role.network_smoke_test.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "network_smoke_test" {
  name = aws_iam_role.network_smoke_test.name
  role = aws_iam_role.network_smoke_test.name
}

# AWS creates these automatically the first time a resource of the given type
# is provisioned in the account. Toggle to false once confirmed present (see
# docs/runbooks/validate-eks-cluster.md) — re-running with true after that
# point fails with "has been taken in this account".
resource "aws_iam_service_linked_role" "eks_cluster" {
  count            = var.create_eks_service_linked_roles ? 1 : 0
  aws_service_name = "eks.amazonaws.com"
}

resource "aws_iam_service_linked_role" "eks_nodegroup" {
  count            = var.create_eks_service_linked_roles ? 1 : 0
  aws_service_name = "eks-nodegroup.amazonaws.com"
}

# Control plane role: EKS assumes this to manage cluster-owned AWS resources
# (ENIs, security groups) on the operator's behalf.
resource "aws_iam_role" "eks_cluster" {
  name = "${var.project}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Worker node role: assumed by each EC2 instance in the managed node group.
resource "aws_iam_role" "eks_node" {
  name = "${var.project}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_node_worker" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_cni" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

# PowerUserAccess has no IAM allowlist at all (unlike the AWS-documented
# behavior of some other policies) — grant back only what's needed for each
# resource the operator must pass a role for, nothing else in IAM.
#
# IAM Identity Center allows exactly one inline policy per permission set, so
# every statement the operator needs lives here as a single resource — this
# is edited (Sid added), never duplicated, as new roles are introduced.
resource "aws_ssoadmin_permission_set_inline_policy" "operator_pass_roles" {
  instance_arn       = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  permission_set_arn = aws_ssoadmin_permission_set.operator.arn

  inline_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PassSmokeTestRole"
        Effect = "Allow"
        Action = [
          "iam:GetInstanceProfile",
          "iam:PassRole",
        ]
        Resource = [
          aws_iam_role.network_smoke_test.arn,
          aws_iam_instance_profile.network_smoke_test.arn,
        ]
      },
      {
        Sid    = "PassEksRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:PassRole",
        ]
        Resource = [
          aws_iam_role.eks_cluster.arn,
          aws_iam_role.eks_node.arn,
        ]
      },
    ]
  })
}

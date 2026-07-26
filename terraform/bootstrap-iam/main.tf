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
# docs/runbooks/bootstrap/aws-account-bootstrap.md). Terraform only wires the
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

# Instance role for ephemeral EC2 smoke-test instances (SSM only, no
# SSH/bastion). Lives here, not envs/lab: PowerUserAccess denies ALL IAM
# actions to the daily operator, including reads -- the inline policy below
# grants back just enough to use this one role. Reusable across future
# validation scripts, not just the VPC network test.
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
# docs/runbooks/validate/validate-eks-cluster.md) — re-running with true after that
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

# PowerUserAccess grants no IAM access at all -- grant back only what's
# needed per resource. IAM Identity Center allows exactly one inline policy
# per permission set, so every statement lives here; new grants add a Sid,
# never a duplicate resource.
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
          # CreateNodegroup checks the node role's attached managed policies
          # before creating the ASG -- only surfaced once the daily operator
          # (not CloudShell/root) called CreateNodegroup directly.
          "iam:ListAttachedRolePolicies",
        ]
        Resource = [
          aws_iam_role.eks_cluster.arn,
          aws_iam_role.eks_node.arn,
        ]
      },
      {
        # CreateNodegroup also validates the eks-nodegroup service-linked
        # role exists via iam:GetRole -- a separate check from PassEksRoles
        # above, which only covers the cluster/node roles themselves.
        Sid    = "ReadEksServiceLinkedRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/eks-nodegroup.amazonaws.com/AWSServiceRoleForAmazonEKSNodegroup",
        ]
      },
      {
        # Lets the operator manage the app's IRSA role in envs/lab, where it
        # must live (trust policy bound to the per-session OIDC provider).
        # Scoped by name prefix since the role is ephemeral. See
        # docs/adr/006-app-irsa-and-job-orchestration.md.
        Sid    = "ManageAppIrsaRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          # Refreshing an aws_iam_role checks managed-policy attachments even
          # when none exist -- 403 on the operator's first plan without it.
          "iam:ListAttachedRolePolicies",
          "iam:TagRole",
          "iam:UntagRole",
          # Same class of gap as ListAttachedRolePolicies, surfaced on
          # `destroy` instead of `plan`: deletion checks instance profiles too.
          "iam:ListInstanceProfilesForRole",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-app-*"
      },
      {
        # Any `terraform plan` refreshes resources already in state, which
        # for an IAM resource needs an explicit read grant, not just
        # create/destroy -- only exposed once the daily operator (not
        # CloudShell/root) planned against an existing provider. Its ARN
        # embeds a per-cluster ID, so scoped by account/region/service
        # instead of an exact ARN.
        Sid    = "ManageEksOidcProvider"
        Effect = "Allow"
        Action = [
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:TagOpenIDConnectProvider",
          "iam:UntagOpenIDConnectProvider",
          "iam:ListOpenIDConnectProviderTags",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/oidc.eks.${var.aws_region}.amazonaws.com/id/*"
      },
      {
        # Same rationale as ManageAppIrsaRoles, for the platform add-ons'
        # IRSA roles. Separate name prefix keeps the two grants
        # independently auditable. See docs/adr/008-cloudfront-dns-tls.md.
        Sid    = "ManagePlatformIrsaRoles"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListInstanceProfilesForRole",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-platform-*"
      },
      {
        # EBS CSI driver's IRSA role attaches the AWS-managed
        # AmazonEBSCSIDriverPolicy instead of an inline policy, unlike the
        # other add-ons -- ManagePlatformIrsaRoles doesn't cover managed-
        # policy attach/detach. iam:PolicyARN pins this to exactly that
        # policy, so it can't attach anything broader to a platform-* role.
        Sid    = "AttachEbsCsiManagedPolicy"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
        ]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-platform-*"
        Condition = {
          StringEquals = {
            "iam:PolicyARN" = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
          }
        }
      },
    ]
  })
}

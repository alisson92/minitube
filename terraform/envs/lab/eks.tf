# EKS Cluster
#
# authentication_mode = "API" uses IAM access entries instead of the legacy
# aws-auth ConfigMap — the current AWS-recommended mode for new clusters.
# bootstrap_cluster_creator_admin_permissions grants cluster-admin to
# whichever identity actually calls CreateCluster — which, in practice, has
# sometimes been a CloudShell/root session rather than cloudlab-operator (the
# daily operator identity envs/lab is meant to be fully usable from). The
# explicit access entry below grants cluster-admin to whoever *applies this
# Terraform module* regardless of who originally created the cluster, so
# kubectl works for the daily operator even on a session that didn't create
# the cluster itself.
resource "aws_eks_cluster" "lab" {
  name     = local.cluster_name
  role_arn = data.aws_iam_role.eks_cluster.arn
  version  = var.eks_cluster_version

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    # Public endpoint kept enabled for lab simplicity (kubectl from the
    # operator's laptop without a bastion). Revisit via ADR if this needs
    # restricting to specific CIDRs once the cluster carries real traffic.
    endpoint_public_access = true
  }

  tags = {
    Name = local.cluster_name
  }

  # No depends_on on the role's policy attachments here: those live in the
  # separate terraform/bootstrap-iam/ state and must already be applied
  # before this module runs (see docs/runbooks/validate-eks-cluster.md).
}

# Managed spot node group. AWS handles the underlying Auto Scaling Group,
# AMI selection and node draining — chosen over a self-managed ASG so there's
# less undifferentiated infrastructure to maintain for a learning project.
resource "aws_eks_node_group" "lab_spot" {
  cluster_name    = aws_eks_cluster.lab.name
  node_group_name = "${var.project}-spot"
  node_role_arn   = data.aws_iam_role.eks_node.arn
  subnet_ids      = aws_subnet.private[*].id

  capacity_type  = "SPOT"
  instance_types = var.eks_node_instance_types

  scaling_config {
    desired_size = var.eks_node_desired_size
    max_size     = var.eks_node_max_size
    min_size     = var.eks_node_min_size
  }

  update_config {
    max_unavailable = 1
  }

  # No depends_on on the role's policy attachments here: those live in the
  # separate terraform/bootstrap-iam/ state and must already be applied
  # before this module runs (see docs/runbooks/validate-eks-cluster.md).
}

# IAM OIDC provider for IRSA (IAM Roles for Service Accounts). Created now,
# ahead of any add-on that needs it, because the provider itself is a single
# cheap/idempotent resource — the alternative is retrofitting it later,
# coupled to whichever add-on (aws-load-balancer-controller, phase 4;
# cluster-autoscaler, phase 6) needs IRSA first. No IRSA role is created yet:
# each add-on creates its own role when it's actually implemented.
resource "aws_iam_openid_connect_provider" "lab" {
  url            = aws_eks_cluster.lab.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
  # thumbprint_list intentionally omitted: for AWS-hosted OIDC issuers the
  # provider resolves this automatically against AWS's own trusted CAs.

  tags = {
    Name = local.cluster_name
  }
}

# Resolves the underlying IAM role ARN of the identity running `terraform
# apply` (data.aws_caller_identity.current.arn is an assumed-role session ARN
# with a session-name suffix that access entries won't match).
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

# Explicit access entry: cluster-admin for whoever applies this module, not
# just whoever happened to create the cluster (see comment on the cluster
# resource above). eks:CreateAccessEntry/AssociateAccessPolicy aren't IAM
# actions, so PowerUserAccess already allows this for the daily operator —
# no CloudShell needed.
resource "aws_eks_access_entry" "operator" {
  cluster_name  = aws_eks_cluster.lab.name
  principal_arn = data.aws_iam_session_context.current.issuer_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "operator_admin" {
  cluster_name  = aws_eks_cluster.lab.name
  principal_arn = data.aws_iam_session_context.current.issuer_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

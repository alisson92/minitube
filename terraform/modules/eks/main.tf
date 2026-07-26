# authentication_mode = "API" uses IAM access entries, not the legacy
# aws-auth ConfigMap. bootstrap_cluster_creator_admin_permissions is
# explicitly false: when true, EKS auto-creates a hidden access entry for
# whoever calls CreateCluster, colliding (409 ResourceInUseException) with
# the explicit aws_eks_access_entry.operator below whenever that's the same
# identity as var.operator_role_arn. Keeping it false makes access 100%
# declared by Terraform, regardless of who runs apply.
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = var.cluster_role_arn
  version  = var.cluster_version

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_private_access = true
    # Public endpoint kept enabled for lab simplicity (kubectl from the
    # operator's laptop without a bastion). Revisit via ADR if this needs
    # restricting to specific CIDRs once the cluster carries real traffic.
    endpoint_public_access = true
  }

  tags = {
    Name = var.cluster_name
  }

  # No depends_on on the role's policy attachments here: those live in the
  # separate terraform/bootstrap-iam/ state and must already be applied
  # before this module runs (see docs/runbooks/validate/validate-eks-cluster.md).
}

# Managed spot node group. AWS handles the underlying Auto Scaling Group,
# AMI selection and node draining — chosen over a self-managed ASG so there's
# less undifferentiated infrastructure to maintain for a learning project.
resource "aws_eks_node_group" "spot" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project}-spot"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids

  capacity_type  = "SPOT"
  instance_types = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
    min_size     = var.node_min_size
  }

  update_config {
    max_unavailable = 1
  }

  # No depends_on on the role's policy attachments here: those live in the
  # separate terraform/bootstrap-iam/ state and must already be applied
  # before this module runs (see docs/runbooks/validate/validate-eks-cluster.md).
}

# IAM OIDC provider for IRSA (IAM Roles for Service Accounts). Created now,
# ahead of any add-on that needs it, because the provider itself is a single
# cheap/idempotent resource — the alternative is retrofitting it later,
# coupled to whichever add-on (aws-load-balancer-controller, phase 4;
# cluster-autoscaler, phase 6) needs IRSA first. No IRSA role is created
# here: each add-on's own role, elsewhere in envs/lab, references this
# provider's outputs instead.
resource "aws_iam_openid_connect_provider" "this" {
  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
  # thumbprint_list intentionally omitted: for AWS-hosted OIDC issuers the
  # provider resolves this automatically against AWS's own trusted CAs.

  tags = {
    Name = var.cluster_name
  }
}

# Explicit access entry: cluster-admin for the daily operator, regardless of
# who created the cluster. var.operator_role_arn is a fixed ARN rather than
# resolved dynamically via `data "aws_iam_session_context"` on purpose: that
# data source itself calls iam:GetRole, an IAM read PowerUserAccess denies.
resource "aws_eks_access_entry" "operator" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.operator_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "operator_admin" {
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.operator_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# EKS access entries return success in ~1s, but the control plane's
# authorizer takes a few extra seconds to actually accept the new principal
# -- no describe/wait call exists to confirm propagation. Callers creating
# Kubernetes/Helm resources as the operator depend_on this whole module to
# inherit this wait. See docs/adr/013-terraform-vpc-eks-modules.md.
resource "time_sleep" "operator_access_propagation" {
  depends_on      = [aws_eks_access_entry.operator, aws_eks_access_policy_association.operator_admin]
  create_duration = "30s"
}

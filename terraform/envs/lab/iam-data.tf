# Created in terraform/bootstrap-iam/ (admin-only) because PowerUserAccess
# denies IAM write actions to the daily operator — only reading it here.
data "aws_iam_instance_profile" "network_smoke_test" {
  name = "${var.project}-network-smoke-test"
}

data "aws_iam_role" "eks_cluster" {
  name = "${var.project}-eks-cluster-role"
}

data "aws_iam_role" "eks_node" {
  name = "${var.project}-eks-node-role"
}

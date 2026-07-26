module "eks" {
  source = "../../modules/eks"

  project          = var.project
  cluster_name     = local.cluster_name
  cluster_version  = var.eks_cluster_version
  cluster_role_arn = data.aws_iam_role.eks_cluster.arn
  node_role_arn    = data.aws_iam_role.eks_node.arn
  subnet_ids       = module.vpc.private_subnet_ids

  node_instance_types = var.eks_node_instance_types
  node_desired_size   = var.eks_node_desired_size
  node_min_size       = var.eks_node_min_size
  node_max_size       = var.eks_node_max_size

  operator_role_arn = var.operator_role_arn
}

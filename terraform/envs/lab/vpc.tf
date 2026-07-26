# Shared by module.vpc (subnet auto-discovery tags,
# kubernetes.io/cluster/<name> = shared) and module.eks (the cluster's own
# name) below -- kept at this level since naming the cluster isn't either
# module's own concern.
locals {
  cluster_name = "${var.project}-lab"
}

module "vpc" {
  source = "../../modules/vpc"

  project              = var.project
  cluster_name         = local.cluster_name
  vpc_cidr             = var.vpc_cidr
  az_count             = var.az_count
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project        = var.project
      managed-by     = "terraform"
      terraform-path = "terraform/envs/lab"
      environment    = "lab"
    }
  }
}

# aws_eks_cluster_auth builds a pre-signed STS URL locally (no EKS API
# call), so it doesn't block on cluster readiness -- ordering against
# module.eks comes from referencing its outputs below, not a hardcoded value.
data "aws_eks_cluster_auth" "lab" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.lab.token
}

# helm provider v3.x: `kubernetes` is a single object attribute here, not a
# nested block like the old SDKv2 helm provider -- a block fails validate.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.lab.token
  }
}

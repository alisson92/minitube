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

# aws_eks_cluster_auth builds a pre-signed STS URL locally to obtain a
# short-lived cluster token — it makes no call to the EKS API itself, so it
# doesn't block on cluster readiness. What actually orders this correctly
# against module.eks is referencing the module's own outputs below
# (endpoint/certificate_authority_data), not a hardcoded value: Terraform
# infers the dependency from that reference.
data "aws_eks_cluster_auth" "lab" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.lab.token
}

# helm provider v3.x moved to the Plugin Framework: `kubernetes` is a single
# object attribute here, not a nested block like in an aws-auth ConfigMap
# provider generation or the old SDKv2 helm provider — using a block instead
# fails terraform validate.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.lab.token
  }
}

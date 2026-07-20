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
# against aws_eks_cluster.lab is referencing the cluster resource's own
# attributes below (endpoint/certificate_authority), not a hardcoded value:
# Terraform infers the dependency from that reference.
data "aws_eks_cluster_auth" "lab" {
  name = aws_eks_cluster.lab.name
}

provider "kubernetes" {
  host                   = aws_eks_cluster.lab.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.lab.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.lab.token
}

# helm provider v3.x moved to the Plugin Framework: `kubernetes` is a single
# object attribute here, not a nested block like in an aws-auth ConfigMap
# provider generation or the old SDKv2 helm provider — using a block instead
# fails terraform validate.
provider "helm" {
  kubernetes = {
    host                   = aws_eks_cluster.lab.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.lab.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.lab.token
  }
}

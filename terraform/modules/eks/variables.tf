variable "project" {
  description = "Project name, used as a prefix for the node group's name"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster. Check currently supported versions (aws eks describe-cluster-versions) before each apply -- EKS drops standard support for old versions over time."
  type        = string
}

variable "cluster_role_arn" {
  description = "ARN of the IAM role EKS assumes to manage the cluster's control plane (created out-of-band in terraform/bootstrap-iam/, since PowerUserAccess denies IAM writes to the daily operator)"
  type        = string
}

variable "node_role_arn" {
  description = "ARN of the IAM role EC2 assumes for worker nodes in the spot node group (created out-of-band in terraform/bootstrap-iam/, same reason as cluster_role_arn)"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs the cluster's control plane ENIs and worker nodes are placed in"
  type        = list(string)
}

variable "node_instance_types" {
  description = "EC2 instance types for the spot node group, in order of preference"
  type        = list(string)
}

variable "node_desired_size" {
  description = "Desired number of worker nodes in the spot node group"
  type        = number
}

variable "node_min_size" {
  description = "Minimum number of worker nodes in the spot node group"
  type        = number
}

variable "node_max_size" {
  description = "Maximum number of worker nodes in the spot node group"
  type        = number
}

variable "operator_role_arn" {
  description = "IAM role ARN granted cluster-admin via an explicit EKS access entry, regardless of who calls CreateCluster (see the access_config comment on the cluster resource in main.tf)"
  type        = string
}

variable "aws_region" {
  description = "AWS region the cluster lives in, needed by null_resource.wait_for_operator_access's local-exec (aws eks update-kubeconfig requires an explicit --region, unlike the aws/kubernetes/helm providers which already carry it)"
  type        = string
}

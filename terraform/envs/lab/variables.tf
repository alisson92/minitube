variable "project" {
  description = "Project name, used as a prefix for resource names and tags"
  type        = string
  default     = "minitube"
}

variable "aws_region" {
  description = "AWS region where the lab environment is deployed"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across. EKS requires at least 2."
  type        = number
  default     = 2
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets, one per AZ (hosts the NAT Gateway and, later, the ALB)"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == var.az_count
    error_message = "public_subnet_cidrs must have exactly az_count entries."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets, one per AZ (hosts EKS nodes and pods, sized larger for VPC CNI pod IPs)"
  type        = list(string)
  default     = ["10.0.16.0/20", "10.0.32.0/20"]

  validation {
    condition     = length(var.private_subnet_cidrs) == var.az_count
    error_message = "private_subnet_cidrs must have exactly az_count entries."
  }
}

variable "eks_cluster_version" {
  description = "Kubernetes version for the EKS cluster. Check currently supported versions (aws eks describe-cluster-versions) before each apply — EKS drops standard support for old versions over time."
  type        = string
  default     = "1.31"
}

variable "eks_node_instance_types" {
  description = "EC2 instance types for the spot node group, in order of preference"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_node_desired_size" {
  description = "Desired number of worker nodes in the spot node group. Fixed equal to min/max (no Cluster Autoscaler/Karpenter yet, so a wider range has no effect) -- sized for 17 pods/node (t3.medium's VPC CNI ENI-IP limit, the real bottleneck here, not CPU/memory) to cover Phase 5's steady-state pod count with headroom. Revisit once a cluster autoscaler exists (Phase 6), driven by real k6 load data."
  type        = number
  default     = 3
}

variable "eks_node_min_size" {
  description = "Minimum number of worker nodes in the spot node group. Equal to desired_size -- see its description."
  type        = number
  default     = 3
}

variable "eks_node_max_size" {
  description = "Maximum number of worker nodes in the spot node group. Equal to desired_size -- see its description."
  type        = number
  default     = 3
}

variable "operator_role_arn" {
  description = "IAM role ARN backing the daily operator's IAM Identity Center permission set, granted cluster-admin via an EKS access entry (aws_eks_access_entry.operator). Only changes if the cloudlab-operator permission set is recreated — find it via `aws iam get-role --role-name AWSReservedSSO_cloudlab-operator_<hash> --query Role.Arn --output text` (CloudShell/root, read-only)."
  type        = string
  default     = "arn:aws:iam::479213212405:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_cloudlab-operator_05e61e8d7c72bcd9"
}

variable "argocd_chart_version" {
  description = "Pinned version of the argo-cd Helm chart (https://artifacthub.io/packages/helm/argo/argo-cd). Check for a newer stable release before bumping."
  type        = string
  default     = "10.1.4"
}

variable "argocd_gitops_revision" {
  description = "Git branch/tag the root Applications track in gitops/app and gitops/plataforma. Defaults to main; override with -var only to validate a feature branch before it's merged (e.g. gitops/plataforma/ doesn't exist on main until this branch merges)."
  type        = string
  default     = "main"
}

variable "argocd_apps_chart_version" {
  description = "Pinned version of the argocd-apps Helm chart (https://artifacthub.io/packages/helm/argo/argocd-apps), used to declare the root Applications/AppProject via Terraform values instead of a manually-applied Application manifest."
  type        = string
  default     = "2.0.5"
}

variable "domain_name" {
  description = "Must match terraform/bootstrap's domain_name (the source of truth for the hosted zone/certificate) -- duplicated here rather than read via terraform_remote_state, see dns-data.tf."
  type        = string
  default     = "minitube.projetodevops.com.br"
}

variable "aws_load_balancer_controller_chart_version" {
  description = "Pinned version of the aws-load-balancer-controller Helm chart (https://artifacthub.io/packages/helm/aws/aws-load-balancer-controller, repo https://aws.github.io/eks-charts). Check for a newer stable release, and re-download terraform/envs/lab/policies/aws-load-balancer-controller-iam-policy.json, before bumping."
  type        = string
  default     = "3.4.2"
}

variable "external_dns_chart_version" {
  description = "Pinned version of the external-dns Helm chart (https://artifacthub.io/packages/helm/external-dns/external-dns, repo https://kubernetes-sigs.github.io/external-dns/)."
  type        = string
  default     = "1.21.1"
}

variable "cert_manager_chart_version" {
  description = "Pinned version of the cert-manager Helm chart (https://artifacthub.io/packages/helm/cert-manager/cert-manager, repo https://charts.jetstack.io). Keep the leading 'v' -- the chart's own version tags use it."
  type        = string
  default     = "v1.21.0"
}

variable "ebs_csi_driver_chart_version" {
  description = "Pinned version of the aws-ebs-csi-driver Helm chart (https://artifacthub.io/packages/helm/aws-ebs-csi-driver/aws-ebs-csi-driver, repo https://kubernetes-sigs.github.io/aws-ebs-csi-driver). Check for a newer stable release before bumping."
  type        = string
  default     = "2.63.0"
}

variable "kube_prometheus_stack_chart_version" {
  description = "Pinned version of the kube-prometheus-stack Helm chart (https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack, repo https://prometheus-community.github.io/helm-charts). Check for a newer stable release before bumping."
  type        = string
  default     = "87.19.0"
}

variable "loki_chart_version" {
  description = "Pinned version of the loki Helm chart (https://artifacthub.io/packages/helm/grafana/loki, repo https://grafana.github.io/helm-charts), deployed in SingleBinary mode with filesystem storage. Check for a newer stable release before bumping."
  type        = string
  default     = "7.1.0"
}

variable "promtail_chart_version" {
  description = "Pinned version of the promtail Helm chart (https://artifacthub.io/packages/helm/grafana/promtail, repo https://grafana.github.io/helm-charts). Promtail is upstream maintenance-mode (superseded by Grafana Alloy) but remains the simplest, best-documented log agent for a single-binary Loki -- fine for a lab, revisit if Alloy's docs mature."
  type        = string
  default     = "6.17.1"
}

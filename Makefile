.ONESHELL:
SHELL := /bin/bash
.DEFAULT_GOAL := help

# Same convention every script in this repo already uses -- override with
# `make validate-all AWS_PROFILE=other` or an exported AWS_PROFILE.
AWS_PROFILE ?= cloudlab
export AWS_PROFILE

LAB := terraform/envs/lab/scripts
IAM := terraform/bootstrap-iam/scripts

.PHONY: help validate-all \
	validate-network validate-eks validate-transcoding validate-argocd \
	validate-cloudfront-dns-tls validate-observability validate-budget

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN {FS = ":.*## "}; {printf "  %-30s %s\n", $$1, $$2}'

## Individual checks -- see docs/runbooks/validate/ for what each one proves
## and how to read its output. Every script assumes `terraform apply` already
## ran in the directory it validates.

validate-network: ## VPC/NAT egress from a private subnet (terraform/envs/lab)
	$(LAB)/validate-network.sh

validate-eks: ## EKS control plane, spot nodes, a real pod running (terraform/envs/lab)
	$(LAB)/validate-eks.sh

validate-transcoding: ## Upload -> Job -> FFmpeg -> S3 pipeline (terraform/envs/lab)
	$(LAB)/validate-transcoding.sh

validate-argocd: ## ArgoCD selfHeal reverts manual drift, no kubectl apply (terraform/envs/lab)
	$(LAB)/validate-argocd.sh

validate-cloudfront-dns-tls: ## Real HLS via CloudFront over valid HTTPS (terraform/envs/lab)
	$(LAB)/validate-cloudfront-dns-tls.sh

validate-observability: ## PVCs, Prometheus targets, Grafana, real Loki logs (terraform/envs/lab)
	$(LAB)/validate-observability.sh

validate-budget: ## Persistent account budget alert (terraform/bootstrap-iam, not envs/lab)
	$(IAM)/validate-budget.sh

validate-all: ## Run every envs/lab check in dependency order; keeps going on failure, prints a summary
	@names=(network eks transcoding argocd cloudfront-dns-tls observability)
	scripts=(
	  "$(LAB)/validate-network.sh"
	  "$(LAB)/validate-eks.sh"
	  "$(LAB)/validate-transcoding.sh"
	  "$(LAB)/validate-argocd.sh"
	  "$(LAB)/validate-cloudfront-dns-tls.sh"
	  "$(LAB)/validate-observability.sh"
	)
	results=()
	overall=0
	for i in "$${!names[@]}"; do
	  echo ""
	  echo "--- validate-all: $${names[$$i]} ($${scripts[$$i]}) ---"
	  if "$${scripts[$$i]}"; then
	    results[$$i]="PASS"
	  else
	    results[$$i]="FAIL"
	    overall=1
	  fi
	done
	echo ""
	echo "--- validate-all summary ---"
	for i in "$${!names[@]}"; do
	  printf "  %-20s %s\n" "$${names[$$i]}" "$${results[$$i]}"
	done
	exit $$overall

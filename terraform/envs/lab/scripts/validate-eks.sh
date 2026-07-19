#!/usr/bin/env bash
# Functional smoke test for the lab EKS cluster: proves the control plane is
# reachable, spot nodes are Ready, and a real pod actually runs and produces
# output on one of them -- not just that `aws eks describe-cluster` reports
# ACTIVE. Uses a throwaway kubeconfig and namespace, both always cleaned up.
#
# Usage: AWS_PROFILE=cloudlab ./scripts/validate-eks.sh
# Run from terraform/envs/lab/ (the script also cds there automatically).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

AWS_REGION="${AWS_REGION:-us-east-1}"
NODE_READY_TIMEOUT_SECONDS=180
POD_READY_TIMEOUT_SECONDS=120
NAMESPACE="minitube-eks-smoke-test"

for bin in aws jq terraform kubectl; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

kubeconfig=""

cleanup() {
  if [[ -n "$kubeconfig" && -f "$kubeconfig" ]]; then
    echo "Cleaning up: deleting namespace $NAMESPACE"
    kubectl --kubeconfig "$kubeconfig" delete namespace "$NAMESPACE" \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
    rm -f "$kubeconfig"
  fi
}
trap cleanup EXIT

echo "Reading Terraform outputs..."
cluster_name=$(terraform output -raw eks_cluster_name)

echo "Generating an ephemeral kubeconfig for $cluster_name..."
kubeconfig=$(mktemp)
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name "$cluster_name" \
  --kubeconfig "$kubeconfig" >/dev/null

# Runs a check function, echoes PASS/FAIL, and returns non-zero on failure
# instead of exiting the script, so all checks run even if one fails.
run_check() {
  local description="$1"
  shift
  echo "--- Check: $description ---"
  if "$@"; then
    echo "PASS: $description"
    return 0
  else
    echo "FAIL: $description" >&2
    return 1
  fi
}

check_nodes_ready() {
  local ready_spot_nodes
  ready_spot_nodes=$(kubectl --kubeconfig "$kubeconfig" get nodes \
    -l eks.amazonaws.com/capacityType=SPOT \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    2>/dev/null | grep -c True || true)
  [[ "$ready_spot_nodes" -ge 1 ]]
}

echo "Waiting for at least one spot node to be Ready (up to ${NODE_READY_TIMEOUT_SECONDS}s)..."
elapsed=0
until check_nodes_ready; do
  if (( elapsed >= NODE_READY_TIMEOUT_SECONDS )); then
    echo "FAIL: no spot node reached Ready within ${NODE_READY_TIMEOUT_SECONDS}s" >&2
    exit 1
  fi
  sleep 10
  elapsed=$((elapsed + 10))
done

overall=0
run_check "control plane reachable and reports Ready spot node(s)" true || overall=1
kubectl --kubeconfig "$kubeconfig" get nodes -L eks.amazonaws.com/capacityType

echo "Creating ephemeral namespace $NAMESPACE..."
kubectl --kubeconfig "$kubeconfig" create namespace "$NAMESPACE" >/dev/null

echo "Scheduling a smoke-test pod..."
kubectl --kubeconfig "$kubeconfig" run minitube-eks-smoke \
  --namespace "$NAMESPACE" \
  --image=public.ecr.aws/docker/library/busybox:stable \
  --restart=Never \
  --command -- sh -c 'echo hello from $(hostname); sleep 30' >/dev/null

if kubectl --kubeconfig "$kubeconfig" wait pod/minitube-eks-smoke \
    --namespace "$NAMESPACE" --for=condition=Ready --timeout="${POD_READY_TIMEOUT_SECONDS}s" >/dev/null 2>&1; then
  echo "PASS: smoke-test pod reached Ready"
else
  echo "FAIL: smoke-test pod never reached Ready within ${POD_READY_TIMEOUT_SECONDS}s" >&2
  kubectl --kubeconfig "$kubeconfig" describe pod/minitube-eks-smoke --namespace "$NAMESPACE" >&2 || true
  overall=1
fi

if (( overall == 0 )); then
  node_name=$(kubectl --kubeconfig "$kubeconfig" get pod/minitube-eks-smoke \
    --namespace "$NAMESPACE" -o jsonpath='{.spec.nodeName}')
  capacity_type=$(kubectl --kubeconfig "$kubeconfig" get node "$node_name" \
    -o jsonpath='{.metadata.labels.eks\.amazonaws\.com/capacityType}')
  if [[ "$capacity_type" == "SPOT" ]]; then
    echo "PASS: pod scheduled on spot node $node_name"
  else
    echo "FAIL: pod scheduled on $node_name, which is not a spot node (capacityType=$capacity_type)" >&2
    overall=1
  fi

  echo "--- Pod logs (proves the container actually executed, not just Running) ---"
  if kubectl --kubeconfig "$kubeconfig" logs pod/minitube-eks-smoke --namespace "$NAMESPACE" | grep -q "hello from"; then
    echo "PASS: pod produced expected log output"
  else
    echo "FAIL: pod did not produce expected log output" >&2
    overall=1
  fi
fi

if (( overall == 0 )); then
  echo "=== All checks passed: EKS cluster is reachable and schedules real workloads on spot nodes. ==="
else
  echo "=== One or more checks FAILED -- see output above. ===" >&2
fi

exit $overall

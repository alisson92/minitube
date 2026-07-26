#!/usr/bin/env bash
# Chaos experiment: simulates a spot node interruption via cordon+drain
# (not a real EC2 termination -- that would fight the ASG's desired_size,
# fixed at 3/3/3 since Phase 5, and risks drifting Terraform state) and
# confirms workloads reschedule onto the remaining nodes within a bounded
# timeout. Deliberately skips nodes hosting PVC-backed pods (Prometheus,
# Loki, Grafana) by default -- an EBS volume is AZ-bound, so draining that
# node would make its pod Pending for a *storage* reason, not the node-loss
# behavior this experiment is meant to exercise.
#
# Always uncordons the target node on exit, even on failure -- that's the
# whole point of the trap here, a node must never come out of this script
# still marked unschedulable.
#
# Usage: AWS_PROFILE=cloudlab ./chaos/drain-spot-node.sh
# See docs/runbooks/chaos-drain-spot-node.md for what to expect and how to
# read the result.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TF_DIR="terraform/envs/lab"
AWS_REGION="${AWS_REGION:-us-east-1}"
NODEGROUP_LABEL="eks.amazonaws.com/nodegroup=minitube-spot"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-120}"
RESCHEDULE_TIMEOUT_SECONDS="${RESCHEDULE_TIMEOUT_SECONDS:-120}"

for bin in aws terraform kubectl; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

kubeconfig=""
target_node=""
cordoned=0

cleanup() {
  if [[ -n "$target_node" && "$cordoned" -eq 1 ]]; then
    echo "Cleaning up: uncordoning $target_node"
    kubectl --kubeconfig "$kubeconfig" uncordon "$target_node" 2>/dev/null || \
      echo "WARN: uncordon of $target_node failed -- check manually: kubectl uncordon $target_node" >&2
  fi
  if [[ -n "$kubeconfig" && -f "$kubeconfig" ]]; then
    rm -f "$kubeconfig"
  fi
}
trap cleanup EXIT

echo "Reading Terraform outputs from ${TF_DIR}..."
cluster_name=$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name)

echo "Generating an ephemeral kubeconfig for $cluster_name..."
kubeconfig=$(mktemp)
aws eks update-kubeconfig --region "$AWS_REGION" --name "$cluster_name" --kubeconfig "$kubeconfig" >/dev/null

echo "Listing nodes in nodegroup ($NODEGROUP_LABEL)..."
mapfile -t all_nodes < <(kubectl --kubeconfig "$kubeconfig" get nodes -l "$NODEGROUP_LABEL" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
if (( ${#all_nodes[@]} < 2 )); then
  echo "FAIL: only ${#all_nodes[@]} node(s) in the nodegroup -- need at least 2 so draining one leaves somewhere for pods to reschedule to." >&2
  exit 1
fi
echo "Nodes: ${all_nodes[*]}"

echo "Finding nodes that host PVC-backed pods (minitube-platform), to avoid by default..."
mapfile -t pvc_nodes < <(kubectl --kubeconfig "$kubeconfig" -n minitube-platform get pods \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{range .spec.volumes[*]}{.persistentVolumeClaim.claimName}{" "}{end}{"\n"}{end}' \
  | awk 'NF>1 {print $1}' | sort -u)
echo "Nodes with PVC-backed pods (avoided): ${pvc_nodes[*]:-none}"

target_node=""
for node in "${all_nodes[@]}"; do
  skip=0
  for pvc_node in "${pvc_nodes[@]:-}"; do
    [[ "$node" == "$pvc_node" ]] && skip=1 && break
  done
  if [[ "$skip" -eq 0 ]]; then
    target_node="$node"
    break
  fi
done

if [[ -z "$target_node" ]]; then
  echo "FAIL: every node in the nodegroup hosts a PVC-backed pod -- nothing safe to drain by default. Re-run with a specific node via 'kubectl drain <node>' manually if you want to test the storage-bound case too." >&2
  exit 1
fi
echo "Target node: $target_node"

echo "Pods on $target_node before drain:"
kubectl --kubeconfig "$kubeconfig" get pods -A --field-selector "spec.nodeName=${target_node}" -o wide

echo "Cordoning $target_node..."
kubectl --kubeconfig "$kubeconfig" cordon "$target_node"
cordoned=1

echo "Draining $target_node (timeout ${DRAIN_TIMEOUT_SECONDS}s)..."
kubectl --kubeconfig "$kubeconfig" drain "$target_node" \
  --ignore-daemonsets --delete-emptydir-data --force \
  --timeout="${DRAIN_TIMEOUT_SECONDS}s"

echo "Waiting up to ${RESCHEDULE_TIMEOUT_SECONDS}s for the api Deployment to be fully Ready again on the remaining nodes..."
if kubectl --kubeconfig "$kubeconfig" -n minitube-app rollout status deployment/api --timeout="${RESCHEDULE_TIMEOUT_SECONDS}s"; then
  echo "PASS: api Deployment is Ready -- rescheduled off $target_node onto the remaining nodes within ${RESCHEDULE_TIMEOUT_SECONDS}s."
  result=0
else
  echo "FAIL: api Deployment did not reach Ready within ${RESCHEDULE_TIMEOUT_SECONDS}s -- see docs/runbooks/chaos-drain-spot-node.md for what to check next." >&2
  result=1
fi

echo ""
echo "--- Pod distribution after drain ---"
kubectl --kubeconfig "$kubeconfig" -n minitube-app get pods -o wide

exit $result

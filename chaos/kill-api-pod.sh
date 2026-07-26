#!/usr/bin/env bash
# Chaos experiment: kills one running replica of the "api" Deployment while
# generating light traffic, measuring the real client-facing error rate.
# Proves minReplicas:2 + the PodDisruptionBudget actually absorb a pod loss,
# not just that the objects exist (docs/engineering-standards.md §11).
# Nothing needs reverting -- the ReplicaSet recreating the pod *is* the
# behavior under test. Cleanup only covers the local traffic loop/kubeconfig.
#
# Usage: AWS_PROFILE=cloudlab ./chaos/kill-api-pod.sh
# See docs/runbooks/chaos/chaos-kill-api-pod.md for what to expect and how to read
# the result.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TF_DIR="terraform/envs/lab"
AWS_REGION="${AWS_REGION:-us-east-1}"
APP_NAMESPACE="minitube-app"
LOCAL_PORT=8000
TRAFFIC_WINDOW_SECONDS="${TRAFFIC_WINDOW_SECONDS:-90}"
KILL_AFTER_SECONDS="${KILL_AFTER_SECONDS:-15}"
REQUEST_INTERVAL_SECONDS=0.5
MAX_ERROR_RATE_PERCENT="${MAX_ERROR_RATE_PERCENT:-1}"

for bin in aws terraform kubectl curl bc; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

kubeconfig=""
port_forward_pid=""
traffic_pid=""
results_file=""

cleanup() {
  if [[ -n "$traffic_pid" ]]; then
    kill "$traffic_pid" 2>/dev/null || true
    wait "$traffic_pid" 2>/dev/null || true
  fi
  if [[ -n "$port_forward_pid" ]]; then
    echo "Cleaning up: stopping port-forward (pid $port_forward_pid)"
    kill "$port_forward_pid" 2>/dev/null || true
  fi
  if [[ -n "$results_file" && -f "$results_file" ]]; then
    rm -f "$results_file"
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

echo "Confirming the api Deployment currently has more than one Ready replica..."
ready_replicas=$(kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" get deployment api \
  -o jsonpath='{.status.readyReplicas}')
if [[ -z "$ready_replicas" || "$ready_replicas" -lt 2 ]]; then
  echo "FAIL: api Deployment has ${ready_replicas:-0} ready replicas -- need at least 2 for this experiment to be meaningful (minReplicas:2 in gitops/app/hpa.yaml). Wait for the HPA to settle or check rollout status." >&2
  exit 1
fi
echo "PASS: $ready_replicas ready replicas -- safe to proceed."

echo "Starting port-forward to the api Service on localhost:${LOCAL_PORT}..."
kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" port-forward svc/api "${LOCAL_PORT}:80" >/dev/null 2>&1 &
port_forward_pid=$!
sleep 3

results_file=$(mktemp)
echo "Starting traffic generator against /api/healthz (${TRAFFIC_WINDOW_SECONDS}s window, one request every ${REQUEST_INTERVAL_SECONDS}s)..."
(
  end=$((SECONDS + TRAFFIC_WINDOW_SECONDS))
  while (( SECONDS < end )); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:${LOCAL_PORT}/api/healthz" || echo "000")
    echo "$code" >> "$results_file"
    sleep "$REQUEST_INTERVAL_SECONDS"
  done
) &
traffic_pid=$!

echo "Letting traffic settle for ${KILL_AFTER_SECONDS}s before killing a pod..."
sleep "$KILL_AFTER_SECONDS"

victim_pod=$(kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" get pods \
  -l app.kubernetes.io/name=api -o jsonpath='{.items[0].metadata.name}')
echo "Killing pod $victim_pod..."
kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" delete pod "$victim_pod" --wait=false

remaining=$((TRAFFIC_WINDOW_SECONDS - KILL_AFTER_SECONDS))
echo "Pod deleted. Letting the traffic generator keep running for the remaining ${remaining}s to capture the recovery..."
wait "$traffic_pid"
traffic_pid=""

echo ""
echo "--- Recovery state (kubectl get, right after the traffic window) ---"
kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" get pods -l app.kubernetes.io/name=api
kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" get hpa api

total=$(wc -l < "$results_file")
errors=$(grep -cv '^200$' "$results_file" || true)
error_rate=$(echo "scale=2; 100 * $errors / $total" | bc)

echo ""
echo "--- Result ---"
echo "Total requests: $total"
echo "Non-200 responses: $errors"
echo "Error rate: ${error_rate}%"

if (( $(echo "$error_rate <= $MAX_ERROR_RATE_PERCENT" | bc -l) )); then
  echo "PASS: error rate ${error_rate}% is at or below the ${MAX_ERROR_RATE_PERCENT}% threshold -- minReplicas + PDB absorbed the pod loss without visible client impact."
  exit 0
else
  echo "FAIL: error rate ${error_rate}% exceeded the ${MAX_ERROR_RATE_PERCENT}% threshold -- see docs/runbooks/chaos/chaos-kill-api-pod.md for what to check next." >&2
  exit 1
fi

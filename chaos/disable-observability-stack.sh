#!/usr/bin/env bash
# Chaos experiment: takes down Prometheus, Alertmanager, Grafana and Loki
# (the "kube-prometheus-stack" and "loki" ArgoCD Applications, both in
# minitube-platform) while generating real traffic against the API and the
# HLS playlist, to confirm the app's blast radius is actually contained --
# it keeps serving video with zero observability, it doesn't go down with
# it. Deliberately scoped to just these two Applications: the shared ALB
# (aws-load-balancer-controller), DNS (external-dns), certs (cert-manager)
# and the EBS CSI driver all live in the same namespace but are NOT part of
# this experiment and are never touched.
#
# ArgoCD's selfHeal would otherwise revert `kubectl scale --replicas=0`
# within seconds, treating it as drift -- same technique already used (and
# recorded in CLAUDE.md) during manual destroy troubleshooting, formalized
# here as a versioned, self-cleaning script: pause each Application's
# syncPolicy, scale to zero, observe, then always restore both the original
# replica counts and the original syncPolicy on exit, in reverse order.
#
# Usage: AWS_PROFILE=cloudlab ./chaos/disable-observability-stack.sh
# See docs/runbooks/chaos-disable-observability-stack.md for what to expect
# and how to read the result.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
source load/lib/find-or-create-video.sh

TF_DIR="terraform/envs/lab"
AWS_REGION="${AWS_REGION:-us-east-1}"
ARGOCD_NAMESPACE="argocd"
PLATFORM_NAMESPACE="minitube-platform"
APP_NAMESPACE="minitube-app"
LOCAL_PORT=8000
TRAFFIC_WINDOW_SECONDS="${TRAFFIC_WINDOW_SECONDS:-60}"
REQUEST_INTERVAL_SECONDS=1
MAX_ERROR_RATE_PERCENT="${MAX_ERROR_RATE_PERCENT:-0}"
APPLICATIONS=(kube-prometheus-stack loki)

for bin in aws terraform kubectl curl bc jq ffmpeg; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

kubeconfig=""
port_forward_pid=""
tmpdir=""
results_file=""
# Populated before any mutation -- cleanup restores exactly these, in
# reverse order, regardless of how far the script got before failing.
declare -A original_sync_policy=()
declare -A original_replicas=()
scaled_workloads=()
paused_applications=()

cleanup() {
  if [[ -n "$port_forward_pid" ]]; then
    kill "$port_forward_pid" 2>/dev/null || true
  fi

  # Restore replicas first (while selfHeal is still paused, so ArgoCD
  # doesn't race a sync against this scale-up), then restore syncPolicy.
  for workload in "${scaled_workloads[@]:-}"; do
    [[ -z "$workload" ]] && continue
    count="${original_replicas[$workload]:-}"
    if [[ -n "$count" ]]; then
      echo "Restoring $workload to $count replica(s)..."
      kubectl --kubeconfig "$kubeconfig" -n "$PLATFORM_NAMESPACE" scale "$workload" --replicas="$count" 2>/dev/null || \
        echo "WARN: failed to restore $workload to $count replicas -- check manually" >&2
    fi
  done

  for app in "${paused_applications[@]:-}"; do
    [[ -z "$app" ]] && continue
    policy="${original_sync_policy[$app]:-}"
    if [[ -n "$policy" && "$policy" != "null" ]]; then
      echo "Restoring syncPolicy on Application/$app..."
      kubectl --kubeconfig "$kubeconfig" -n "$ARGOCD_NAMESPACE" patch application "$app" \
        --type merge -p "{\"spec\":{\"syncPolicy\":${policy}}}" 2>/dev/null || \
        echo "WARN: failed to restore syncPolicy on Application/$app -- check manually: kubectl -n $ARGOCD_NAMESPACE get application $app -o yaml" >&2
    fi
  done

  if [[ -n "$results_file" && -f "$results_file" ]]; then
    rm -f "$results_file"
  fi
  if [[ -n "$tmpdir" && -d "$tmpdir" ]]; then
    rm -rf "$tmpdir"
  fi
  if [[ -n "$kubeconfig" && -f "$kubeconfig" ]]; then
    rm -f "$kubeconfig"
  fi
}
trap cleanup EXIT

echo "Reading Terraform outputs from ${TF_DIR}..."
cluster_name=$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name)
base_url=$(terraform -chdir="$TF_DIR" output -raw app_url)
bucket=$(terraform -chdir="$TF_DIR" output -raw s3_video_bucket_name)

# Sets video_id -- and, only if it had to upload a fresh one, also
# kubeconfig/port_forward_pid/tmpdir (see load/lib/find-or-create-video.sh).
# The common case (an HLS output already exists in S3) touches none of
# those, so the kubeconfig generated right after is still needed then.
find_or_create_test_video "$bucket" "$cluster_name" "$APP_NAMESPACE" "$LOCAL_PORT"

if [[ -z "$kubeconfig" ]]; then
  echo "Generating an ephemeral kubeconfig for $cluster_name..."
  kubeconfig=$(mktemp)
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$cluster_name" --kubeconfig "$kubeconfig" >/dev/null
fi

echo "Pausing selfHeal on: ${APPLICATIONS[*]}..."
for app in "${APPLICATIONS[@]}"; do
  policy=$(kubectl --kubeconfig "$kubeconfig" -n "$ARGOCD_NAMESPACE" get application "$app" -o jsonpath='{.spec.syncPolicy}')
  original_sync_policy["$app"]="${policy:-null}"
  kubectl --kubeconfig "$kubeconfig" -n "$ARGOCD_NAMESPACE" patch application "$app" --type merge -p '{"spec":{"syncPolicy":null}}'
  paused_applications+=("$app")
done
echo "PASS: selfHeal paused."

echo "Discovering Deployments/StatefulSets owned by these Applications (via app.kubernetes.io/instance)..."
mapfile -t scaled_workloads < <(kubectl --kubeconfig "$kubeconfig" -n "$PLATFORM_NAMESPACE" get deploy,statefulset \
  -l "app.kubernetes.io/instance in (${APPLICATIONS[0]},${APPLICATIONS[1]})" \
  -o jsonpath='{range .items[*]}{.kind}{"/"}{.metadata.name}{"\n"}{end}' | sed 's/^Deployment/deployment/; s/^StatefulSet/statefulset/')
if (( ${#scaled_workloads[@]} == 0 )); then
  echo "FAIL: no Deployments/StatefulSets found with label app.kubernetes.io/instance in (${APPLICATIONS[*]}) in $PLATFORM_NAMESPACE -- check the label actually matches this chart's release (kubectl -n $PLATFORM_NAMESPACE get deploy,statefulset --show-labels)." >&2
  exit 1
fi
echo "Workloads to scale to zero:"
printf '  %s\n' "${scaled_workloads[@]}"

for workload in "${scaled_workloads[@]}"; do
  count=$(kubectl --kubeconfig "$kubeconfig" -n "$PLATFORM_NAMESPACE" get "$workload" -o jsonpath='{.spec.replicas}')
  original_replicas["$workload"]="$count"
done

echo "Scaling observability stack to zero..."
for workload in "${scaled_workloads[@]}"; do
  kubectl --kubeconfig "$kubeconfig" -n "$PLATFORM_NAMESPACE" scale "$workload" --replicas=0
done

echo "Waiting for pods to actually terminate..."
kubectl --kubeconfig "$kubeconfig" -n "$PLATFORM_NAMESPACE" wait pod \
  -l "app.kubernetes.io/instance in (${APPLICATIONS[0]},${APPLICATIONS[1]})" \
  --for=delete --timeout=90s 2>/dev/null || true

echo ""
echo "--- Observability stack state (should be empty or Terminating) ---"
kubectl --kubeconfig "$kubeconfig" -n "$PLATFORM_NAMESPACE" get pods \
  -l "app.kubernetes.io/instance in (${APPLICATIONS[0]},${APPLICATIONS[1]})"

echo "Starting port-forward to the api Service on localhost:${LOCAL_PORT}..."
kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" port-forward svc/api "${LOCAL_PORT}:80" >/dev/null 2>&1 &
port_forward_pid=$!
sleep 3

results_file=$(mktemp)
echo "Generating traffic for ${TRAFFIC_WINDOW_SECONDS}s against /api/healthz and the HLS playlist (via CloudFront, ${base_url})..."
end=$((SECONDS + TRAFFIC_WINDOW_SECONDS))
while (( SECONDS < end )); do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:${LOCAL_PORT}/api/healthz" || echo "000")
  echo "$code" >> "$results_file"
  if [[ -n "$video_id" ]]; then
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${base_url}/hls/${video_id}/playlist.m3u8" || echo "000")
    echo "$code" >> "$results_file"
  fi
  sleep "$REQUEST_INTERVAL_SECONDS"
done

total=$(wc -l < "$results_file")
errors=$(grep -cv '^200$' "$results_file" || true)
error_rate=$(echo "scale=2; 100 * $errors / $total" | bc)

echo ""
echo "--- Result ---"
echo "Total requests (API + HLS playlist): $total"
echo "Non-200 responses: $errors"
echo "Error rate: ${error_rate}%"

if (( $(echo "$error_rate <= $MAX_ERROR_RATE_PERCENT" | bc -l) )); then
  echo "PASS: error rate ${error_rate}% -- the app kept serving traffic with zero observability stack up. Blast radius contained."
  result=0
else
  echo "FAIL: error rate ${error_rate}% exceeded ${MAX_ERROR_RATE_PERCENT}% -- the app's availability depends on the observability stack, which shouldn't be true. See docs/runbooks/chaos-disable-observability-stack.md." >&2
  result=1
fi

echo ""
echo "Restoring the observability stack now (see cleanup log below)..."
exit $result

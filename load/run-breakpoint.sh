#!/usr/bin/env bash
# Finds (or creates) a real, already-transcoded test video, then runs
# load/k6/breakpoint.js against it, escalating load until it actually
# breaks (or completes cleanly, meaning PEAK_RATE wasn't enough to find the
# ceiling). See docs/runbooks/load/run-k6-breakpoint.md.
#
# Usage: AWS_PROFILE=cloudlab ./load/run-breakpoint.sh
# Escalate across runs: PEAK_RATE=800 AWS_PROFILE=cloudlab ./load/run-breakpoint.sh
# Requires: k6, aws, jq, terraform, kubectl, curl, ffmpeg in PATH; terraform
# apply already ran and ArgoCD has synced gitops/app/.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=load/lib/find-or-create-video.sh
source ./lib/find-or-create-video.sh

TF_DIR="../terraform/envs/lab"
APP_NAMESPACE="minitube-app"
LOCAL_PORT=8000
PEAK_RATE="${PEAK_RATE:-400}"

for bin in k6 aws jq terraform kubectl curl ffmpeg; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

kubeconfig=""
port_forward_pid=""
tmpdir=""
video_id=""

cleanup() {
  if [[ -n "$port_forward_pid" ]]; then
    echo "Cleaning up: stopping port-forward (pid $port_forward_pid)"
    kill "$port_forward_pid" 2>/dev/null || true
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
bucket=$(terraform -chdir="$TF_DIR" output -raw s3_video_bucket_name)
cluster_name=$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name)
base_url=$(terraform -chdir="$TF_DIR" output -raw app_url)

find_or_create_test_video "$bucket" "$cluster_name" "$APP_NAMESPACE" "$LOCAL_PORT"

echo "Running k6 breakpoint scenario against ${base_url} (video_id=${video_id}, PEAK_RATE=${PEAK_RATE} req/s)..."
k6 run --env BASE_URL="$base_url" --env VIDEO_ID="$video_id" --env PEAK_RATE="$PEAK_RATE" ./k6/breakpoint.js

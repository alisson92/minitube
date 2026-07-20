#!/usr/bin/env bash
# Functional smoke test for the app: generates a synthetic test video with
# FFmpeg (no binary committed to the repo), uploads it through the real
# API (POST /videos), waits for the Job it creates to finish, and confirms
# real HLS output (playlist + at least one segment) landed in S3 -- proves
# the whole pipeline (API -> S3 raw -> Job -> FFmpeg -> S3 hls), not just
# that `kubectl apply` and `terraform apply` exited 0.
#
# Usage: AWS_PROFILE=cloudlab ./scripts/validate-transcoding.sh
# Run from terraform/envs/lab/ (the script also cds there automatically).
# Requires: gitops/app/ already applied (kubectl apply -k gitops/app/) and
# both images already pushed to ECR -- see docs/runbooks/validate-transcoding.md.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

AWS_REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="minitube-app"
LOCAL_PORT=8000
JOB_TIMEOUT_SECONDS=300

for bin in aws jq terraform kubectl curl ffmpeg; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

tmpdir=""
port_forward_pid=""

cleanup() {
  if [[ -n "$port_forward_pid" ]]; then
    echo "Cleaning up: stopping port-forward (pid $port_forward_pid)"
    kill "$port_forward_pid" 2>/dev/null || true
  fi
  if [[ -n "$tmpdir" && -d "$tmpdir" ]]; then
    rm -rf "$tmpdir"
  fi
}
trap cleanup EXIT

echo "Reading Terraform outputs..."
bucket=$(terraform output -raw s3_video_bucket_name)
cluster_name=$(terraform output -raw eks_cluster_name)

echo "Generating an ephemeral kubeconfig for $cluster_name..."
kubeconfig=$(mktemp)
aws eks update-kubeconfig --region "$AWS_REGION" --name "$cluster_name" --kubeconfig "$kubeconfig" >/dev/null

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

echo "Waiting for the api Deployment to be Available (up to 120s)..."
kubectl --kubeconfig "$kubeconfig" -n "$NAMESPACE" wait deployment/api --for=condition=Available --timeout=120s

echo "Starting port-forward to the api Service on localhost:${LOCAL_PORT}..."
kubectl --kubeconfig "$kubeconfig" -n "$NAMESPACE" port-forward svc/api "${LOCAL_PORT}:80" >/dev/null 2>&1 &
port_forward_pid=$!
sleep 3

overall=0
run_check "API is reachable and healthy" curl -sf "http://127.0.0.1:${LOCAL_PORT}/healthz" || { overall=1; exit 1; }

tmpdir=$(mktemp -d)
sample="$tmpdir/sample.mp4"
echo "Generating a synthetic 3s test video..."
ffmpeg -f lavfi -i testsrc=duration=3:size=640x360:rate=30 \
  -f lavfi -i sine=frequency=1000:duration=3 \
  -c:v libx264 -c:a aac -shortest -y -loglevel error "$sample"

echo "Uploading test video via POST /videos..."
response=$(curl -sf -X POST "http://127.0.0.1:${LOCAL_PORT}/videos" -F "file=@${sample}")
video_id=$(jq -r '.video_id' <<< "$response")
echo "video_id=$video_id"

echo "Waiting for the transcode Job to finish (up to ${JOB_TIMEOUT_SECONDS}s)..."
elapsed=0
status="running"
while [[ "$status" != "succeeded" && "$status" != "failed" ]]; do
  if (( elapsed >= JOB_TIMEOUT_SECONDS )); then
    echo "FAIL: transcode job did not finish within ${JOB_TIMEOUT_SECONDS}s" >&2
    overall=1
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
  # A transient curl/port-forward hiccup shouldn't kill the whole script (set
  # -e + pipefail would otherwise abort silently mid-loop) -- treat it as
  # "still running" and let the next iteration retry.
  polled_status=$(curl -s "http://127.0.0.1:${LOCAL_PORT}/videos/${video_id}" 2>/dev/null | jq -r '.status // empty' 2>/dev/null) || true
  status="${polled_status:-running}"
  echo "  [$(printf '%3d' "$elapsed")s] status=$status"
done

run_check "transcode job succeeded (status=$status)" [ "$status" = "succeeded" ] || {
  overall=1
  echo "--- Job pod logs (for debugging) ---"
  kubectl --kubeconfig "$kubeconfig" -n "$NAMESPACE" logs "job/transcode-${video_id}" || true
}

if [[ "$status" == "succeeded" ]]; then
  playlist_exists() {
    aws s3api head-object --bucket "$bucket" --key "hls/${video_id}/playlist.m3u8" >/dev/null 2>&1
  }
  run_check "HLS playlist exists in S3 (hls/${video_id}/playlist.m3u8)" playlist_exists || overall=1

  segment_count=$(aws s3 ls "s3://${bucket}/hls/${video_id}/" | grep -c '\.ts$' || true)
  run_check "at least one HLS segment exists in S3 (found: ${segment_count})" [ "$segment_count" -ge 1 ] || overall=1
fi

if (( overall == 0 )); then
  echo "=== All checks passed: a real video was uploaded, transcoded, and its HLS segments are readable in S3. ==="
else
  echo "=== One or more checks FAILED -- see output above. ===" >&2
fi

exit $overall

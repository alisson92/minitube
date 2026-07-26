# Shared by all four load/run-*.sh scripts (see load/README.md for what
# each one covers): finds an
# existing transcoded video in S3, or uploads a synthetic one via the real
# API and waits for the transcode Job to finish -- same pattern already used
# in terraform/envs/lab/scripts/validate-transcoding.sh and
# validate-cloudfront-dns-tls.sh.
#
# Meant to be `source`d, not executed directly. Sets `video_id` in the
# caller's shell, and -- only when it had to create a video --
# `kubeconfig`/`port_forward_pid`/`tmpdir` too, so the caller's own
# `trap cleanup EXIT` (already holding those variable names) tears them down.

find_or_create_test_video() {
  local bucket="$1" cluster_name="$2" namespace="$3" local_port="$4"
  local job_timeout_seconds="${5:-300}"

  echo "Looking for existing HLS output in s3://${bucket}/hls/..." >&2
  local existing_playlist
  existing_playlist=$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "hls/" \
    --query "Contents[?ends_with(Key, 'playlist.m3u8')].Key | [0]" --output text 2>/dev/null || echo "None")

  if [[ "$existing_playlist" != "None" && -n "$existing_playlist" ]]; then
    video_id=$(echo "$existing_playlist" | awk -F'/' '{print $2}')
    echo "Found existing HLS output: video_id=${video_id}" >&2
    return 0
  fi

  echo "No existing HLS output found -- uploading a synthetic test video via the API..." >&2
  kubeconfig=$(mktemp)
  aws eks update-kubeconfig --region "${AWS_REGION:-us-east-1}" --name "$cluster_name" --kubeconfig "$kubeconfig" >/dev/null

  kubectl --kubeconfig "$kubeconfig" -n "$namespace" wait deployment/api --for=condition=Available --timeout=120s
  kubectl --kubeconfig "$kubeconfig" -n "$namespace" port-forward svc/api "${local_port}:80" >/dev/null 2>&1 &
  port_forward_pid=$!
  sleep 3

  tmpdir=$(mktemp -d)
  local sample="$tmpdir/sample.mp4"
  ffmpeg -f lavfi -i testsrc=duration=3:size=640x360:rate=30 \
    -f lavfi -i sine=frequency=1000:duration=3 \
    -c:v libx264 -c:a aac -shortest -y -loglevel error "$sample"

  local response
  response=$(curl -sf -X POST "http://127.0.0.1:${local_port}/api/videos" -F "file=@${sample}")
  video_id=$(jq -r '.video_id' <<< "$response")
  echo "video_id=${video_id}" >&2

  local elapsed=0 status="running"
  while [[ "$status" != "succeeded" && "$status" != "failed" ]]; do
    if (( elapsed >= job_timeout_seconds )); then
      echo "FAIL: transcode job did not finish within ${job_timeout_seconds}s" >&2
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    status=$(curl -sf "http://127.0.0.1:${local_port}/api/videos/${video_id}" 2>/dev/null | jq -r '.status // "running"' 2>/dev/null || echo "running")
    echo "  [$(printf '%3d' "$elapsed")s] status=${status}" >&2
  done

  if [[ "$status" != "succeeded" ]]; then
    echo "FAIL: transcode job did not succeed (status=${status})" >&2
    return 1
  fi

  kill "$port_forward_pid" 2>/dev/null || true
  port_forward_pid=""
  return 0
}

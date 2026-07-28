#!/usr/bin/env bash
# Uploads a real video file via the public API and prints the watch page URL
# (site/player/, ADR 019) once transcoding succeeds. Companion to
# load/lib/find-or-create-video.sh (which only needs *some* video, synthetic
# or not, for a load test) -- this one is for a human who wants a specific
# real video and its shareable https://app.<domain>/?v=<video_id> URL.
#
# Usage: ./scripts/upload-video.sh /path/to/video.mp4
# Requires terraform apply already ran in this directory.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

VIDEO_FILE="${1:?Usage: $0 <path-to-video-file>}"
JOB_TIMEOUT_SECONDS="${JOB_TIMEOUT_SECONDS:-300}"
MAX_CONSECUTIVE_ERRORS=3

[[ -f "$VIDEO_FILE" ]] || { echo "FAIL: file not found: $VIDEO_FILE" >&2; exit 1; }

for bin in terraform curl jq; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

echo "Reading Terraform outputs..."
app_url=$(terraform output -raw app_url)

echo "Uploading ${VIDEO_FILE} to ${app_url}/api/videos..."
response=$(curl -sf -X POST "${app_url}/api/videos" -F "file=@${VIDEO_FILE}")
video_id=$(jq -r '.video_id' <<< "$response")
echo "video_id=${video_id}"

echo "Waiting for the transcode Job to finish (up to ${JOB_TIMEOUT_SECONDS}s)..."
elapsed=0
status="queued"
consecutive_errors=0
while [[ "$status" != "succeeded" && "$status" != "failed" ]]; do
  if (( elapsed >= JOB_TIMEOUT_SECONDS )); then
    echo "FAIL: transcode job did not finish within ${JOB_TIMEOUT_SECONDS}s" >&2
    exit 1
  fi
  sleep 5
  elapsed=$((elapsed + 5))
  # Same "don't let a transient curl/API hiccup masquerade as still-running"
  # guard as validate-transcoding.sh -- an unparseable response fails the jq
  # lookup instead of silently matching the while condition.
  raw_response=$(curl -s "${app_url}/api/videos/${video_id}" 2>/dev/null) || raw_response=""
  polled_status=$(jq -r '.status // empty' <<< "$raw_response" 2>/dev/null) || polled_status=""
  if [[ -z "$polled_status" ]]; then
    consecutive_errors=$((consecutive_errors + 1))
    echo "  [$(printf '%3d' "$elapsed")s] no valid status in response (attempt ${consecutive_errors}/${MAX_CONSECUTIVE_ERRORS}): ${raw_response:-<empty>}"
    if (( consecutive_errors >= MAX_CONSECUTIVE_ERRORS )); then
      echo "FAIL: API returned an unparseable/error response ${MAX_CONSECUTIVE_ERRORS} times in a row" >&2
      exit 1
    fi
    continue
  fi
  consecutive_errors=0
  status="$polled_status"
  echo "  [$(printf '%3d' "$elapsed")s] status=${status}"
done

if [[ "$status" != "succeeded" ]]; then
  echo "FAIL: transcode job did not succeed (status=${status})" >&2
  exit 1
fi

echo ""
echo "Ready: ${app_url}/?v=${video_id}"

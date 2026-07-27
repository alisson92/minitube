#!/usr/bin/env bash
# Same test as load/k6/waves.js, but k6 runs from an ephemeral EC2 instance
# in the lab VPC -- same reasoning as run-breakpoint-from-ec2.sh (client
# network noise would make the "recovery" stage impossible to read
# correctly). Reuses the same ephemeral-EC2-via-SSM pattern and IAM
# instance profile -- no new Terraform resources needed.
#
# Usage: AWS_PROFILE=cloudlab ./load/run-waves-from-ec2.sh
# Escalate the deliberate peak: WAVE_PEAK_RATE=1000 AWS_PROFILE=cloudlab ./load/run-waves-from-ec2.sh
# Requires locally: aws, jq, terraform, kubectl, curl, ffmpeg (same as
# run-breakpoint-from-ec2.sh, for the find-or-create-video step). k6 itself
# is installed on the remote instance, not required locally.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=load/lib/find-or-create-video.sh
source ./lib/find-or-create-video.sh

TF_DIR="../terraform/envs/lab"
APP_NAMESPACE="minitube-app"
LOCAL_PORT=8000
WAVE_PEAK_RATE="${WAVE_PEAK_RATE:-700}"
AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
K6_VERSION="2.0.0"
SSM_REGISTER_TIMEOUT_SECONDS=180
INSTALL_TIMEOUT_SECONDS=120
# waves.js's stages total 23m (3+4+2+3+3+2+2+2+2), regardless of
# WAVE_PEAK_RATE -- only the target rate at each stage scales, not the
# schedule. Padded well past that for install/setup overhead (same ~480s
# margin already validated in run-breakpoint-from-ec2.sh's 1500s for a 17m
# test).
RUN_TIMEOUT_SECONDS=1900

for bin in aws jq terraform kubectl curl ffmpeg; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

kubeconfig=""
port_forward_pid=""
tmpdir=""
video_id=""
instance_id=""

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
  if [[ -n "$instance_id" ]]; then
    echo "Cleaning up: terminating $instance_id"
    aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$instance_id" >/dev/null || true
  fi
}
trap cleanup EXIT

echo "Reading Terraform outputs from ${TF_DIR}..."
bucket=$(terraform -chdir="$TF_DIR" output -raw s3_video_bucket_name)
cluster_name=$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name)
base_url=$(terraform -chdir="$TF_DIR" output -raw app_url)
private_subnet_id=$(terraform -chdir="$TF_DIR" output -json private_subnet_ids | jq -r '.[0]')
instance_profile_name=$(terraform -chdir="$TF_DIR" output -raw smoke_test_instance_profile_name)

find_or_create_test_video "$bucket" "$cluster_name" "$APP_NAMESPACE" "$LOCAL_PORT"

echo "Resolving latest Amazon Linux 2023 AMI..."
ami_id=$(aws ssm get-parameters \
  --region "$AWS_REGION" \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)

echo "Launching load-generator instance ($INSTANCE_TYPE) in $private_subnet_id (no public IP, SSM-only access)..."
instance_id=$(aws ec2 run-instances \
  --region "$AWS_REGION" \
  --image-id "$ami_id" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$private_subnet_id" \
  --iam-instance-profile "Name=$instance_profile_name" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=minitube-k6-load-generator}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "Instance: $instance_id"

aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$instance_id"

echo "Waiting for the SSM agent to register (up to ${SSM_REGISTER_TIMEOUT_SECONDS}s)..."
elapsed=0
until [[ "$(aws ssm describe-instance-information --region "$AWS_REGION" \
    --filters "Key=InstanceIds,Values=$instance_id" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" == "Online" ]]; do
  if (( elapsed >= SSM_REGISTER_TIMEOUT_SECONDS )); then
    echo "FAIL: instance never registered with SSM within ${SSM_REGISTER_TIMEOUT_SECONDS}s" >&2
    exit 1
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
echo "SSM agent online."

# Runs a remote command via SSM and waits for it to reach a terminal status
# (SSM only exposes stdout/stderr once the command finishes, no streaming).
# Prints stdout, and on failure also stderr, then returns non-zero.
run_remote() {
  local description="$1" remote_command="$2" timeout_seconds="$3"
  echo "--- $description (timeout ${timeout_seconds}s) ---"

  local parameters_json
  parameters_json=$(jq -n --arg cmd "$remote_command" '{commands: [$cmd]}')

  local command_id
  command_id=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --timeout-seconds "$timeout_seconds" \
    --parameters "$parameters_json" \
    --query 'Command.CommandId' --output text)

  local status="Pending" elapsed=0 wait_ceiling=$((timeout_seconds + 60))
  while [[ "$status" == "Pending" || "$status" == "InProgress" ]]; do
    if (( elapsed >= wait_ceiling )); then
      echo "FAIL: $description (local wait exceeded ${wait_ceiling}s)" >&2
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    status=$(aws ssm get-command-invocation --region "$AWS_REGION" \
      --command-id "$command_id" --instance-id "$instance_id" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")
  done

  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$command_id" --instance-id "$instance_id" \
    --query 'StandardOutputContent' --output text

  if [[ "$status" != "Success" ]]; then
    echo "FAIL: $description (status=$status)" >&2
    aws ssm get-command-invocation --region "$AWS_REGION" \
      --command-id "$command_id" --instance-id "$instance_id" \
      --query 'StandardErrorContent' --output text >&2
    return 1
  fi
  return 0
}

run_remote "installing k6 v${K6_VERSION}" \
  "curl -sL https://github.com/grafana/k6/releases/download/v${K6_VERSION}/k6-v${K6_VERSION}-linux-amd64.tar.gz | tar -xz -C /tmp && sudo mv /tmp/k6-v${K6_VERSION}-linux-amd64/k6 /usr/local/bin/k6 && k6 version" \
  "$INSTALL_TIMEOUT_SECONDS"

echo "Uploading waves.js to the instance..."
script_b64=$(base64 -w0 ./k6/waves.js)
run_remote "writing waves.js" \
  "echo ${script_b64} | base64 -d | sudo tee /tmp/waves.js >/dev/null" \
  60

echo "Running k6 waves scenario from EC2 against ${base_url} (video_id=${video_id}, WAVE_PEAK_RATE=${WAVE_PEAK_RATE} req/s)..."
run_remote "k6 run" \
  "BASE_URL='${base_url}' VIDEO_ID='${video_id}' WAVE_PEAK_RATE='${WAVE_PEAK_RATE}' /usr/local/bin/k6 run --quiet /tmp/waves.js" \
  "$RUN_TIMEOUT_SECONDS"

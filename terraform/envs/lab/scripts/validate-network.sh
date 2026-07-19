#!/usr/bin/env bash
# Functional smoke test for the lab VPC: proves the NAT Gateway actually
# provides internet egress from a private subnet, not just that the route
# table has the right entry. Launches an ephemeral EC2 instance reachable
# only via SSM Session Manager (no SSH/bastion/inbound rules), runs a few
# checks, then always terminates it.
#
# Usage: AWS_PROFILE=cloudlab ./scripts/validate-network.sh
# Run from terraform/envs/lab/ (the script also cds there automatically).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
SSM_REGISTER_TIMEOUT_SECONDS=180
COMMAND_TIMEOUT_SECONDS=60

for bin in aws jq terraform; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

instance_id=""

cleanup() {
  if [[ -n "$instance_id" ]]; then
    echo "Cleaning up: terminating $instance_id"
    aws ec2 terminate-instances --region "$AWS_REGION" --instance-ids "$instance_id" >/dev/null || true
  fi
}
trap cleanup EXIT

echo "Reading Terraform outputs..."
private_subnet_id=$(terraform output -json private_subnet_ids | jq -r '.[0]')
instance_profile_name=$(terraform output -raw smoke_test_instance_profile_name)

echo "Resolving latest Amazon Linux 2023 AMI..."
ami_id=$(aws ssm get-parameters \
  --region "$AWS_REGION" \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)

echo "Launching smoke-test instance in $private_subnet_id (no public IP, SSM-only access)..."
instance_id=$(aws ec2 run-instances \
  --region "$AWS_REGION" \
  --image-id "$ami_id" \
  --instance-type "$INSTANCE_TYPE" \
  --subnet-id "$private_subnet_id" \
  --iam-instance-profile "Name=$instance_profile_name" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=minitube-network-smoke-test}]' \
  --query 'Instances[0].InstanceId' --output text)
echo "Instance: $instance_id"

echo "Waiting for the instance to reach 'running'..."
aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids "$instance_id"

# Config sanity check: confirm the private IP AWS actually assigned falls
# inside the subnet's own CIDR block (EC2 API only, no SSM needed yet).
private_ip=$(aws ec2 describe-instances --region "$AWS_REGION" --instance-ids "$instance_id" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
subnet_cidr=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$private_subnet_id" \
  --query 'Subnets[0].CidrBlock' --output text)
if python3 -c "import ipaddress,sys; sys.exit(0 if ipaddress.ip_address('$private_ip') in ipaddress.ip_network('$subnet_cidr') else 1)"; then
  echo "PASS: private IP $private_ip is within subnet CIDR $subnet_cidr"
else
  echo "FAIL: private IP $private_ip is NOT within subnet CIDR $subnet_cidr" >&2
  exit 1
fi

echo "Waiting for the SSM agent to register (up to ${SSM_REGISTER_TIMEOUT_SECONDS}s)..."
elapsed=0
until [[ "$(aws ssm describe-instance-information --region "$AWS_REGION" \
    --filters "Key=InstanceIds,Values=$instance_id" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" == "Online" ]]; do
  if (( elapsed >= SSM_REGISTER_TIMEOUT_SECONDS )); then
    echo "FAIL: instance never registered with SSM within ${SSM_REGISTER_TIMEOUT_SECONDS}s" >&2
    echo "      (this itself is a signal the NAT path may be broken -- SSM needs internet egress to register)" >&2
    exit 1
  fi
  sleep 5
  elapsed=$((elapsed + 5))
done
echo "PASS: SSM agent online (this alone proves NAT egress: SSM registration requires reaching AWS endpoints over the internet)"

# Runs a remote command via SSM and waits for it to finish. Echoes PASS/FAIL
# and returns a non-zero status on failure instead of exiting the script,
# so all checks run even if one fails.
run_check() {
  local description="$1" remote_command="$2"
  echo "--- Check: $description ---"

  local command_id
  command_id=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "{\"commands\":[\"$remote_command\"]}" \
    --query 'Command.CommandId' --output text)

  local status="Pending" elapsed=0
  while [[ "$status" == "Pending" || "$status" == "InProgress" ]]; do
    if (( elapsed >= COMMAND_TIMEOUT_SECONDS )); then
      echo "FAIL: $description (timed out after ${COMMAND_TIMEOUT_SECONDS}s)" >&2
      return 1
    fi
    sleep 3
    elapsed=$((elapsed + 3))
    status=$(aws ssm get-command-invocation --region "$AWS_REGION" \
      --command-id "$command_id" --instance-id "$instance_id" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")
  done

  if [[ "$status" == "Success" ]]; then
    echo "PASS: $description"
    aws ssm get-command-invocation --region "$AWS_REGION" \
      --command-id "$command_id" --instance-id "$instance_id" \
      --query 'StandardOutputContent' --output text
    return 0
  else
    echo "FAIL: $description (status=$status)" >&2
    aws ssm get-command-invocation --region "$AWS_REGION" \
      --command-id "$command_id" --instance-id "$instance_id" \
      --query 'StandardErrorContent' --output text >&2
    return 1
  fi
}

overall=0
run_check "internet egress via NAT Gateway (curl to checkip.amazonaws.com)" \
  "curl -sf --max-time 5 https://checkip.amazonaws.com" || overall=1
run_check "public DNS resolution" \
  "getent hosts amazon.com" || overall=1

if (( overall == 0 )); then
  echo "=== All checks passed: private subnet has real internet egress via the NAT Gateway. ==="
else
  echo "=== One or more checks FAILED -- see output above. ===" >&2
fi

exit $overall

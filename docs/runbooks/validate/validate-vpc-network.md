# Runbook — VPC network functional validation (lab)

> Establishes the "functional validation post-apply" standard described in [`docs/engineering-standards.md`](../../engineering-standards.md#11-post-apply-functional-validation).

## Why this exists

`terraform apply` without error and `aws ec2 describe-*` showing the right attributes prove that the resources **exist with the expected configuration** — they do not prove that they **work**. For the lab VPC, the question that matters is: can a workload in a private subnet actually reach the internet through the NAT Gateway? Reading the route table doesn't answer that; only exercising the network path does.

This runbook documents the `terraform/envs/lab/scripts/validate-network.sh` script, which spins up an ephemeral EC2 instance in the private subnet, tests the network path from inside it, and always terminates it at the end — it never remains as permanent infrastructure.

## How it works

- **Access via SSM Session Manager**, not SSH: the instance has no public IP, no key, and no inbound Security Group. The SSM agent connects from the inside out, so **the instance's own registration with SSM is already a first egress test** — if the NAT doesn't work, the instance never shows up as `Online`.
- **AMI resolved dynamically** via a public SSM parameter (`/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`), without hardcoding an AMI ID that expires.
- **Checks performed:**
  1. The assigned private IP falls within the subnet's CIDR (sanity check via the EC2 API, doesn't need SSM).
  2. The instance registers in SSM as `Online` (indirect proof of egress).
  3. `curl` to `https://checkip.amazonaws.com` from inside the instance (direct proof: the NAT translates and routes outbound traffic).
  4. Public DNS resolution (`getent hosts amazon.com`).
- **Guaranteed cleanup:** `trap cleanup EXIT` calls `aws ec2 terminate-instances` even if the script fails or is interrupted (`Ctrl+C`).

## Prerequisite: smoke test role

The script needs an instance profile (`minitube-network-smoke-test`) for the EC2 instance to assume the SSM role. The `cloudlab-operator` (`PowerUserAccess`) **cannot create IAM resources** — only read them and `PassRole`. Because of this, that role lives in `terraform/bootstrap-iam/` (admin-only module) and needs to be applied once via CloudShell/root, following the same flow as [`docs/runbooks/bootstrap/aws-account-bootstrap.md`](../bootstrap/aws-account-bootstrap.md).

```bash
# Root/CloudShell session, one time only (the role persists between sessions, at no cost)
cd terraform/bootstrap-iam
terraform init
terraform plan
terraform apply
```

Verify the role exists before running the script:

```bash
aws iam get-instance-profile --instance-profile-name minitube-network-smoke-test --profile cloudlab
```

⚠️ Without this role applied, `terraform plan`/`apply` in `terraform/envs/lab/` fails while resolving the `data "aws_iam_instance_profile"` in `ssm.tf`.

## Run the test

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab ./scripts/validate-network.sh
```

Dependencies in your environment: `aws` CLI, `jq`, `terraform`, `python3` (used only for the IP-within-CIDR check).

## Expected output

```
PASS: private IP 10.0.16.x is within subnet CIDR 10.0.16.0/20
PASS: SSM agent online (this alone proves NAT egress: ...)
PASS: internet egress via NAT Gateway (curl to checkip.amazonaws.com)
PASS: public DNS resolution
=== All checks passed: private subnet has real internet egress via the NAT Gateway. ===
```

Exit code `0` when everything passes, `1` if any check fails (the specific error message appears before the final line).

## Security / rollback

The script always terminates the test instance via `trap`, even on error. If the script is terminated abnormally (e.g. `kill -9`, a frozen panel) and the instance is left behind:

```bash
aws ec2 describe-instances --profile cloudlab \
  --filters "Name=tag:Name,Values=minitube-network-smoke-test" "Name=instance-state-name,Values=running,pending" \
  --query 'Reservations[].Instances[].InstanceId' --output text

aws ec2 terminate-instances --profile cloudlab --instance-ids <instance-id>
```

The role/instance profile itself has no cost and does not need to be destroyed between sessions — it's reusable by future validation scripts (EKS, etc.).

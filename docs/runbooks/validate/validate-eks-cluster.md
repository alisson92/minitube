# Runbook — EKS cluster functional validation (lab)

> Establishes the "functional validation post-apply" standard described in [`docs/engineering-standards.md`](../../engineering-standards.md#11-post-apply-functional-validation).

## Why this exists

`terraform apply` without error and `aws eks describe-cluster` showing `status: ACTIVE` prove that the cluster **exists with the expected configuration** — they do not prove that it **works**. The question that matters: does the control plane respond, do the spot nodes reach `Ready`, and can a real pod actually be scheduled and run on them? This can only be answered by truly exercising the cluster.

This runbook documents the `terraform/envs/lab/scripts/validate-eks.sh` script, which generates an ephemeral kubeconfig, runs a test pod in a disposable namespace, and always cleans up at the end — it never remains as permanent state in the cluster.

## How it works

- **Ephemeral kubeconfig**: generated in a temporary file (`mktemp`) via `aws eks update-kubeconfig`, using the operator's own SSO credentials (`AWS_PROFILE=cloudlab`) — without spinning up any extra EC2 instance just for the test.
- **Checks performed:**
  1. At least one node with the label `eks.amazonaws.com/capacityType=SPOT` reports condition `Ready` (with retry of up to 180s, since the node group may take a few minutes to scale up after the `apply`).
  2. A test namespace (`minitube-eks-smoke-test`) is created and a pod (`busybox`) is scheduled in it.
  3. The pod reaches `Ready` within 120s.
  4. The node where the pod ran (`spec.nodeName`) actually has the `capacityType=SPOT` label — confirming the workload landed on the spot node group, not on some node outside it.
  5. The pod logs contain the expected output (`hello from ...`) — proof that the container **actually ran**, not just that it stayed `Running`.
- **Guaranteed cleanup:** `trap cleanup EXIT` deletes the test namespace and removes the temporary kubeconfig, even if the script fails or is interrupted (`Ctrl+C`).

## Prerequisite: cluster and node IAM roles

The script assumes the cluster and node group have already been successfully applied in `terraform/envs/lab/`, which in turn requires the IAM roles (`minitube-eks-cluster-role`, `minitube-eks-node-role`) to already exist. They live in `terraform/bootstrap-iam/` (admin-only module), for the same reason already documented for the network smoke test role — `PowerUserAccess` doesn't allow the operator to create or read IAM resources without the explicit inline policy.

```bash
# Root/CloudShell session, one time only (the roles persist between sessions, at no cost)
cd terraform/bootstrap-iam

# Before the first apply: confirm whether the EKS service-linked roles
# already exist in the account. If they do, set create_eks_service_linked_roles = false
# in variables.tf before applying (the resource fails if it tries to recreate them).
aws iam get-role --role-name AWSServiceRoleForAmazonEKS || true
aws iam get-role --role-name AWSServiceRoleForAmazonEKSNodegroup || true

terraform init
terraform plan
terraform apply
```

Verify the roles exist before applying `envs/lab`:

```bash
aws iam get-role --role-name minitube-eks-cluster-role --profile cloudlab
aws iam get-role --role-name minitube-eks-node-role --profile cloudlab
```

⚠️ Without these roles applied, `terraform plan`/`apply` in `terraform/envs/lab/` fails while resolving the `data "aws_iam_role"` in `iam-data.tf`.

## Apply the cluster and run the test

> ⚠️ **Everything in `terraform/envs/lab/` is ephemeral by design.** If the previous session's VPC has already been destroyed (the normal flow — see `docs/runbooks/validate/validate-vpc-network.md`), this `apply` recreates the VPC **from scratch**, along with the EKS cluster, the node group, and the OIDC provider — it is not incremental on top of anything that already exists. At the end of the test, **all of this is destroyed again** (see the following section). EKS charges for the control plane hourly, even when idle, so don't leave the cluster up beyond the test duration.

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan     # review: VPC (if recreating) + cluster + node group + OIDC provider + subnet tags
AWS_PROFILE=cloudlab terraform apply

AWS_PROFILE=cloudlab ./scripts/validate-eks.sh
```

Dependencies in your environment: `aws` CLI, `jq`, `terraform`, `kubectl`.

## Destroy everything at the end of the test

```bash
cd terraform/envs/lab
AWS_PROFILE=cloudlab terraform plan -destroy   # review: should remove cluster, node group, OIDC provider, VPC — everything
AWS_PROFILE=cloudlab terraform destroy
```

`terraform/bootstrap-iam/` is **not** destroyed — the EKS roles, the network smoke-test role, and the operator permission set remain up between sessions because they incur no cost. Confirm nothing billable is left in the account:

```bash
aws eks list-clusters --profile cloudlab --region us-east-1
aws ec2 describe-vpcs --profile cloudlab --region us-east-1 --filters "Name=tag:Name,Values=minitube-lab"
aws ec2 describe-nat-gateways --profile cloudlab --region us-east-1 --filter "Name=state,Values=available"
```

All three commands should return empty before ending the session.

## Expected output

```
PASS: control plane reachable and reports Ready spot node(s)
NAME                          STATUS   ROLES    AGE   VERSION   CAPACITYTYPE
ip-10-0-16-x.ec2.internal     Ready    <none>   5m    v1.31.x   SPOT
ip-10-0-32-x.ec2.internal     Ready    <none>   5m    v1.31.x   SPOT
PASS: smoke-test pod reached Ready
PASS: pod scheduled on spot node ip-10-0-16-x.ec2.internal
PASS: pod produced expected log output
=== All checks passed: EKS cluster is reachable and schedules real workloads on spot nodes. ===
```

Exit code `0` when everything passes, `1` if any check fails (the specific error message appears before the final line).

## Security / rollback

The script always deletes the test namespace and the temporary kubeconfig via `trap`, even on error. If the script is terminated abnormally (e.g. `kill -9`) and the namespace is left behind:

```bash
aws eks update-kubeconfig --region us-east-1 --name minitube-lab --profile cloudlab --kubeconfig /tmp/minitube-kubeconfig
kubectl --kubeconfig /tmp/minitube-kubeconfig delete namespace minitube-eks-smoke-test
rm -f /tmp/minitube-kubeconfig
```

The cluster/node IAM roles and the EKS service-linked role have no cost and don't need to be destroyed between sessions — they persist in `terraform/bootstrap-iam/` outside the ephemeral cycle of `envs/lab`, consistent with Phase 1's completion criterion ("full destroy followed by a clean apply, with no manual steps").

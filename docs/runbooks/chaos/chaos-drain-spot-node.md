# Chaos: simulate a spot node interruption

## What

`chaos/drain-spot-node.sh` picks a node from the `minitube-spot` node group, runs `kubectl cordon` + `kubectl drain --ignore-daemonsets --delete-emptydir-data`, and confirms the `api` Deployment goes back to `Ready` on the remaining nodes within a timeout. It doesn't actually terminate the EC2 instance — that would conflict with the ASG's fixed `desired_size` (`3/3/3`, see ADR 011) and risk Terraform state drift; cordon+drain simulates the relevant effect (loss of one node's capacity) without that risk.

By default, it avoids nodes hosting pods with a PVC (`minitube-platform` — Prometheus, Loki, Grafana): an EBS volume is bound to its AZ, so draining that node would make the pod go `Pending` for a storage reason, not because of the node loss itself, which is what this experiment is meant to exercise.

## Why

The node group is spot — real interruptions happen. The goal is to confirm the cluster reschedules the workload without manual intervention before this happens for real in production.

## How

```bash
AWS_PROFILE=cloudlab ./chaos/drain-spot-node.sh
```

Optional environment variables:
- `DRAIN_TIMEOUT_SECONDS` (default 120)
- `RESCHEDULE_TIMEOUT_SECONDS` (default 120)

The chosen node is always uncordoned at the end (`trap cleanup EXIT`), even on failure — no node should ever be left marked `SchedulingDisabled` after running this script.

## How to read the result

- **PASS:** `kubectl rollout status deployment/api` reported `Ready` within the timeout — the API pods rescheduled onto the remaining nodes without intervention.
- **FAIL:**
  - Check `kubectl -n minitube-app get pods -o wide` — did the pods go `Pending`? Likely a lack of capacity on the remaining nodes (2 nodes × 17 pods/node via VPC CNI, see ADR 011 decision 1) — in that case the HPA's `maxReplicas: 6` may be trying to scale beyond what 2 nodes can hold.
  - If the script failed because **all** nodes host pods with a PVC, that's a sign the cluster is running with fewer nodes than expected (`3/3/3`) — check `kubectl get nodes`.

## Run result (2026-07-26) — PASS

Target node chosen automatically (`ip-10-0-24-125...`, no PVC — the other two hosted Prometheus/Loki/Grafana and were avoided). Besides the `api` pod, the node also hosted several platform singletons with no explicit affinity to that particular node: `argocd-application-controller-0`, `ebs-csi-controller`, `cert-manager-webhook`, `external-dns`, `alertmanager`, `kube-prometheus-stack-operator` and `coredns` — all drained and rescheduled along with it, with no error (`argocd-application-controller` has no PVC in this configuration — `terraform/envs/lab/values/argocd.yaml` doesn't define persistence — so it didn't need to be in the avoided-nodes list; only the StatefulSets with a real PVC for Prometheus/Loki/Grafana need that).

`kubectl rollout status deployment/api` completed within the timeout: the two remaining `api` pods reappeared `Running` on the other two nodes (`api-...-dcw29`, `api-...-m6zlg`). Node uncordoned at the end (`trap cleanup EXIT`), confirmed in the log itself (`node/... uncordoned`).

`PASS`: automatic rescheduling confirmed, with no manual intervention.

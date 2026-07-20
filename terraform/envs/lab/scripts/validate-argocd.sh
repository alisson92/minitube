#!/usr/bin/env bash
# Functional smoke test for ArgoCD: proves it's not just "helm_release exited
# 0 and pods are Running", but that it's actually reconciling gitops/ from
# Git -- pull-based, continuously. The central check (d) introduces a manual
# drift (kubectl scale) and confirms ArgoCD's selfHeal reverts it on its own,
# with no `kubectl apply` run anywhere in this script -- the real proof of
# the OpenGitOps "applied by pull" + "continuously reconciled" principles.
#
# Usage: AWS_PROFILE=cloudlab ./scripts/validate-argocd.sh
# Run from terraform/envs/lab/ (the script also cds there automatically).
# Requires: terraform apply already ran (ArgoCD + the two root Applications
# come up from terraform/envs/lab/argocd.tf) -- see
# docs/runbooks/validate-argocd-gitops.md.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

AWS_REGION="${AWS_REGION:-us-east-1}"
ARGOCD_NAMESPACE="argocd"
APP_NAMESPACE="minitube-app"
LOCAL_PORT=8000
APP_SYNC_TIMEOUT_SECONDS=180
DRIFT_TIMEOUT_SECONDS=120

for bin in aws jq terraform kubectl curl; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

kubeconfig=""
api_pf_pid=""
drift_reverted=1

cleanup() {
  if [[ -n "$api_pf_pid" ]]; then
    kill "$api_pf_pid" 2>/dev/null || true
  fi
  # Safety net: if the drift check below failed partway through, never leave
  # the Deployment diverged from what Git declares.
  if [[ -n "$kubeconfig" && -f "$kubeconfig" && "$drift_reverted" -eq 0 ]]; then
    echo "Cleaning up: reverting manual drift on deployment/api"
    kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" scale deployment/api --replicas=1 >/dev/null 2>&1 || true
  fi
  if [[ -n "$kubeconfig" && -f "$kubeconfig" ]]; then
    rm -f "$kubeconfig"
  fi
}
trap cleanup EXIT

echo "Reading Terraform outputs..."
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

overall=0

# (a) Core ArgoCD components Ready
echo "Waiting for argocd-server and argocd-repo-server to be Available (up to 180s)..."
kubectl --kubeconfig "$kubeconfig" -n "$ARGOCD_NAMESPACE" wait deploy/argocd-server deploy/argocd-repo-server \
  --for=condition=Available --timeout=180s || overall=1

controller_ready() {
  local ready
  ready=$(kubectl --kubeconfig "$kubeconfig" -n "$ARGOCD_NAMESPACE" get statefulset argocd-application-controller \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  [[ -n "$ready" && "$ready" -ge 1 ]]
}
run_check "argocd-application-controller has at least 1 ready replica" controller_ready || overall=1

# (b) Both root Applications reach Synced (health check relaxed for
# "platform", which syncs 0 resources in this phase -- see gitops/plataforma/README.md)
app_synced_healthy() {
  local app="$1" require_healthy="$2" sync health
  sync=$(kubectl --kubeconfig "$kubeconfig" -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$app" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
  health=$(kubectl --kubeconfig "$kubeconfig" -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$app" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
  [[ "$sync" == "Synced" ]] || return 1
  if [[ "$require_healthy" == "true" ]]; then
    [[ "$health" == "Healthy" ]]
  else
    [[ "$health" == "Healthy" || -z "$health" ]]
  fi
}

wait_for_app() {
  local app="$1" require_healthy="$2" elapsed=0
  until app_synced_healthy "$app" "$require_healthy"; do
    if (( elapsed >= APP_SYNC_TIMEOUT_SECONDS )); then
      return 1
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  return 0
}

run_check "Application 'app' reaches Synced+Healthy (up to ${APP_SYNC_TIMEOUT_SECONDS}s)" \
  wait_for_app app true || overall=1
run_check "Application 'platform' reaches Synced (up to ${APP_SYNC_TIMEOUT_SECONDS}s; empty health accepted, 0 resources)" \
  wait_for_app platform false || overall=1

# (c) gitops/app/ resources exist, tracked by ArgoCD (not a manual apply), API responds
echo "Waiting for the api Deployment to be Available (up to 120s)..."
kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" wait deployment/api --for=condition=Available --timeout=120s

tracking_id_present() {
  local tracking_id
  tracking_id=$(kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" get deployment/api \
    -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/tracking-id}' 2>/dev/null || echo "")
  [[ -n "$tracking_id" ]]
}
run_check "deployment/api carries an ArgoCD tracking-id annotation (proves ArgoCD created it, not a manual kubectl apply)" \
  tracking_id_present || overall=1

echo "Starting port-forward to the api Service on localhost:${LOCAL_PORT}..."
kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" port-forward svc/api "${LOCAL_PORT}:80" >/dev/null 2>&1 &
api_pf_pid=$!
sleep 3
run_check "API is reachable and healthy via port-forward" curl -sf "http://127.0.0.1:${LOCAL_PORT}/healthz" || overall=1

# (d) Central proof: manual drift must self-heal without any intervention
baseline=$(kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" get deployment/api -o jsonpath='{.spec.replicas}')
echo "Baseline: deployment/api replicas=$baseline (gitops/app/deployment.yaml declares replicas: 1)"
echo "Introducing manual drift: scaling deployment/api to 2 replicas (never via GitOps)..."
kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" scale deployment/api --replicas=2 >/dev/null
drift_reverted=0

elapsed=0
reverted=false
until $reverted; do
  if (( elapsed >= DRIFT_TIMEOUT_SECONDS )); then
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
  spec_replicas=$(kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" get deployment/api -o jsonpath='{.spec.replicas}')
  ready_replicas=$(kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" get deployment/api -o jsonpath='{.status.readyReplicas}')
  echo "  [$(printf '%3d' "$elapsed")s] spec.replicas=$spec_replicas status.readyReplicas=$ready_replicas"
  if [[ "$spec_replicas" == "1" && "$ready_replicas" == "1" ]]; then
    reverted=true
  fi
done

if $reverted; then
  echo "PASS: ArgoCD selfHeal reverted the drift back to 1 replica in ~${elapsed}s, with no manual intervention"
  drift_reverted=1
else
  echo "FAIL: manual drift was NOT reverted within ${DRIFT_TIMEOUT_SECONDS}s" >&2
  overall=1
fi

if (( overall == 0 )); then
  echo "=== All checks passed: ArgoCD is installed, both root Applications are synced from Git, and selfHeal reconciles drift without any kubectl apply. ==="
else
  echo "=== One or more checks FAILED -- see output above. ===" >&2
fi

exit $overall

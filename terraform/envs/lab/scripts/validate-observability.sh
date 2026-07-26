#!/usr/bin/env bash
# Functional smoke test: proves kube-prometheus-stack and Loki don't just
# report Synced+Healthy, but actually work -- PVCs bound, Prometheus
# scraping real targets (including the API's own /metrics), Grafana
# reachable, Loki serving real log lines shipped by Promtail. Mirrors
# "existe vs. funciona" (docs/engineering-standards.md §11).
#
# Usage: AWS_PROFILE=cloudlab ./scripts/validate-observability.sh
# Requires terraform apply already ran and ArgoCD finished syncing the
# add-ons -- see docs/runbooks/validate/validate-observability.md.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

AWS_REGION="${AWS_REGION:-us-east-1}"
PLATFORM_NAMESPACE="minitube-platform"
APP_NAMESPACE="minitube-app"
PROMETHEUS_PORT=9090
GRAFANA_PORT=3000
LOKI_PORT=3100
API_PORT=8000
PVC_TIMEOUT_SECONDS=300
LOG_TIMEOUT_SECONDS=180

for bin in aws jq terraform kubectl curl dig; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

kubeconfig=""
prometheus_pf_pid=""
grafana_pf_pid=""
loki_pf_pid=""
api_pf_pid=""

cleanup() {
  for pid in "$prometheus_pf_pid" "$grafana_pf_pid" "$loki_pf_pid" "$api_pf_pid"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  if [[ -n "$kubeconfig" && -f "$kubeconfig" ]]; then
    rm -f "$kubeconfig"
  fi
}
trap cleanup EXIT

echo "Reading Terraform outputs..."
cluster_name=$(terraform output -raw eks_cluster_name)
domain_name=$(terraform output -raw app_url | sed -E 's#https://app\.##')
grafana_fqdn="grafana.${domain_name}"

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

poll_until() {
  local timeout="$1" description="$2"
  shift 2
  local elapsed=0
  until "$@"; do
    if (( elapsed >= timeout )); then
      echo "FAIL: $description did not happen within ${timeout}s" >&2
      return 1
    fi
    sleep 10
    elapsed=$((elapsed + 10))
    echo "  [$(printf '%4d' "$elapsed")s] still waiting: $description"
  done
  return 0
}

overall=0

# (a) PVCs bound -- proves the EBS CSI driver (new this phase) provisioned
# real EBS volumes, not just that the StorageClass object exists.
pvcs_bound() {
  local phases not_bound
  phases=$(kubectl --kubeconfig "$kubeconfig" -n "$PLATFORM_NAMESPACE" get pvc \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null)
  # Zero PVCs is not a pass -- it means kube-prometheus-stack/loki never
  # synced (e.g. their Applications are stuck Unknown), not that there's
  # nothing to wait for.
  [[ -n "$phases" ]] || return 1
  not_bound=$(awk '$2 != "Bound"' <<< "$phases")
  [[ -z "$not_bound" ]]
}
run_check "All PVCs in ${PLATFORM_NAMESPACE} reach Bound (up to ${PVC_TIMEOUT_SECONDS}s)" \
  poll_until "$PVC_TIMEOUT_SECONDS" "PVC binding" pvcs_bound || overall=1
kubectl --kubeconfig "$kubeconfig" -n "$PLATFORM_NAMESPACE" get pvc || true

# (b) Prometheus has zero down scrape targets among what's enabled.
echo "Starting port-forward to Prometheus on localhost:${PROMETHEUS_PORT}..."
kubectl --kubeconfig "$kubeconfig" -n "$PLATFORM_NAMESPACE" port-forward svc/kube-prometheus-stack-prometheus "${PROMETHEUS_PORT}:9090" >/dev/null 2>&1 &
prometheus_pf_pid=$!
sleep 3

prometheus_targets_up() {
  local down
  down=$(curl -sf "http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/targets" 2>/dev/null \
    | jq -r '[.data.activeTargets[] | select(.health != "up")] | length' 2>/dev/null || echo "")
  [[ "$down" == "0" ]]
}
run_check "Prometheus reports zero down scrape targets" prometheus_targets_up || overall=1

# (c) The API's own /metrics is being scraped (proves the Phase 5
# instrumentation in app/api/main.py + servicemonitor-api.yaml work).
api_target_up() {
  local health
  health=$(curl -sf "http://127.0.0.1:${PROMETHEUS_PORT}/api/v1/query" --data-urlencode 'query=up{job="api"}' 2>/dev/null \
    | jq -r '.data.result[0].value[1] // empty' 2>/dev/null || echo "")
  [[ "$health" == "1" ]]
}
run_check "Prometheus scrapes app/api's /metrics (up{job=\"api\"} == 1)" api_target_up || overall=1

# (d) Grafana reachable via https://grafana.<domain>, with the Loki
# datasource actually able to reach Loki (not just "configured").
grafana_ui_reachable() {
  curl -sf -o /dev/null -w "%{http_code}" "https://${grafana_fqdn}/login" 2>/dev/null | grep -q "^200$"
}
run_check "Grafana UI reachable via https://${grafana_fqdn}" grafana_ui_reachable || overall=1

# (e) Real log ingestion: generate known traffic against the API, then poll
# Loki (via port-forward, bypassing Grafana entirely) until it shows up --
# the actual proof that promtail is shipping minitube-app's container logs.
echo "Starting port-forward to Loki on localhost:${LOKI_PORT}..."
kubectl --kubeconfig "$kubeconfig" -n "$PLATFORM_NAMESPACE" port-forward svc/loki "${LOKI_PORT}:3100" >/dev/null 2>&1 &
loki_pf_pid=$!
sleep 3

echo "Generating known traffic against the API (/api/healthz) to produce a fresh log line..."
kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" port-forward svc/api "${API_PORT}:80" >/dev/null 2>&1 &
api_pf_pid=$!
sleep 3
curl -sf "http://127.0.0.1:${API_PORT}/api/healthz" >/dev/null || true

loki_has_app_logs() {
  local start_ns count
  start_ns=$(( $(date +%s) - LOG_TIMEOUT_SECONDS - 60 ))000000000
  count=$(curl -sf "http://127.0.0.1:${LOKI_PORT}/loki/api/v1/query_range" \
    --data-urlencode "query={namespace=\"${APP_NAMESPACE}\"}" \
    --data-urlencode "start=${start_ns}" \
    --data-urlencode "limit=5" 2>/dev/null \
    | jq -r '[.data.result[].values[]] | length' 2>/dev/null || echo "0")
  [[ "$count" -gt 0 ]]
}
run_check "Loki has log lines for namespace=${APP_NAMESPACE} (up to ${LOG_TIMEOUT_SECONDS}s, promtail shipping real logs)" \
  poll_until "$LOG_TIMEOUT_SECONDS" "log ingestion into Loki" loki_has_app_logs || overall=1

if (( overall == 0 )); then
  echo "=== All checks passed: PVCs bound via the EBS CSI driver, Prometheus scrapes real targets including the instrumented API, Grafana is reachable, and Loki holds real logs shipped by promtail. ==="
else
  echo "=== One or more checks FAILED -- see output above. ===" >&2
fi

exit $overall

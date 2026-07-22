#!/usr/bin/env bash
# Functional smoke test for Phase 4: proves app.<domain> actually serves real
# HLS content through CloudFront over valid HTTPS (not just "distribution
# status is Deployed"), and that argocd.<domain> resolves and serves the
# ArgoCD UI straight through the ALB. Mirrors the "existe vs. funciona"
# principle from docs/engineering-standards.md §11.
#
# Usage: AWS_PROFILE=cloudlab ./scripts/validate-cloudfront-dns-tls.sh
# Run from terraform/envs/lab/ (the script also cds there automatically).
# Requires: terraform apply already ran (CloudFront, the 3 platform IRSA
# roles, and the add-on Applications come from terraform/envs/lab/argocd.tf
# and cloudfront.tf) and ArgoCD has finished syncing the add-ons -- see
# docs/runbooks/validate-cloudfront-dns-tls.md. DNS propagation for a
# freshly-created record can lag behind Route53 itself by a few minutes on
# some resolvers -- the polling below accounts for that, it isn't a bug if
# the early checks take a while.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

AWS_REGION="${AWS_REGION:-us-east-1}"
APP_NAMESPACE="minitube-app"
LOCAL_PORT=8000
DNS_TIMEOUT_SECONDS=300
DISTRIBUTION_TIMEOUT_SECONDS=600
JOB_TIMEOUT_SECONDS=300
CLUSTER_ISSUER_TIMEOUT_SECONDS=180
ALB_INGRESS_TIMEOUT_SECONDS=180

for bin in aws jq terraform kubectl curl dig openssl ffmpeg; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

kubeconfig=""
port_forward_pid=""
tmpdir=""

cleanup() {
  if [[ -n "$port_forward_pid" ]]; then
    kill "$port_forward_pid" 2>/dev/null || true
  fi
  if [[ -n "$tmpdir" && -d "$tmpdir" ]]; then
    rm -rf "$tmpdir"
  fi
  if [[ -n "$kubeconfig" && -f "$kubeconfig" ]]; then
    rm -f "$kubeconfig"
  fi
}
trap cleanup EXIT

echo "Reading Terraform outputs..."
bucket=$(terraform output -raw s3_video_bucket_name)
cluster_name=$(terraform output -raw eks_cluster_name)
domain_name=$(terraform output -raw app_url | sed -E 's#https://app\.##')
app_fqdn="app.${domain_name}"
argocd_fqdn="argocd.${domain_name}"
distribution_id=$(terraform output -raw cloudfront_distribution_id)

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

# (a) app.<domain> DNS record resolves (Terraform-managed alias)
app_dns_resolves() { [[ -n "$(dig +short "$app_fqdn" @8.8.8.8)" ]]; }
run_check "app.${domain_name} resolves via a public resolver (up to ${DNS_TIMEOUT_SECONDS}s)" \
  poll_until "$DNS_TIMEOUT_SECONDS" "app DNS record propagation" app_dns_resolves || overall=1

# (b) CloudFront distribution reaches Deployed
distribution_deployed() {
  local status
  status=$(aws cloudfront get-distribution --id "$distribution_id" --query "Distribution.Status" --output text 2>/dev/null || echo "")
  [[ "$status" == "Deployed" ]]
}
run_check "CloudFront distribution reaches Deployed (up to ${DISTRIBUTION_TIMEOUT_SECONDS}s)" \
  poll_until "$DISTRIBUTION_TIMEOUT_SECONDS" "CloudFront distribution deployment" distribution_deployed || overall=1

# (c) ClusterIssuer Ready -- proves cert-manager's IRSA role and RBAC work,
# even with no Certificate consumer yet (see docs/adr/008-cloudfront-dns-tls.md)
cluster_issuer_ready() {
  local ready
  ready=$(kubectl --kubeconfig "$kubeconfig" get clusterissuer letsencrypt-route53 \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [[ "$ready" == "True" ]]
}
run_check "ClusterIssuer letsencrypt-route53 reaches Ready (up to ${CLUSTER_ISSUER_TIMEOUT_SECONDS}s)" \
  poll_until "$CLUSTER_ISSUER_TIMEOUT_SECONDS" "ClusterIssuer readiness" cluster_issuer_ready || overall=1

# (d) aws-load-balancer-controller provisioned the shared ALB from the app Ingress
alb_provisioned() {
  local hostname
  hostname=$(kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" get ingress api \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  [[ -n "$hostname" ]]
}
run_check "aws-load-balancer-controller provisioned the shared ALB (up to ${ALB_INGRESS_TIMEOUT_SECONDS}s)" \
  poll_until "$ALB_INGRESS_TIMEOUT_SECONDS" "ALB provisioning" alb_provisioned || overall=1

# (e) argocd.<domain> DNS record resolves -- proves external-dns is working
argocd_dns_resolves() { [[ -n "$(dig +short "$argocd_fqdn" @8.8.8.8)" ]]; }
run_check "argocd.${domain_name} resolves via a public resolver (up to ${DNS_TIMEOUT_SECONDS}s)" \
  poll_until "$DNS_TIMEOUT_SECONDS" "argocd DNS record propagation (external-dns)" argocd_dns_resolves || overall=1

# (f) argocd.<domain> serves the UI, TLS valid, straight off the ALB (no CloudFront)
argocd_ui_reachable() {
  curl -sf -o /dev/null -w "%{http_code}" "https://${argocd_fqdn}/" 2>/dev/null | grep -qE "^(200|307)$"
}
run_check "ArgoCD UI reachable via https://${argocd_fqdn} with valid TLS" argocd_ui_reachable || overall=1

# (g) Central proof: a real HLS playlist, served by CloudFront over HTTPS,
# with a valid certificate chain and a CloudFront cache status header.
# Ensures real content exists in S3 first (reuses validate-transcoding.sh's
# synthetic-video flow) instead of depending on a previous script run.
echo "Looking for existing HLS output in s3://${bucket}/hls/..."
video_id=$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "hls/" --query "Contents[?ends_with(Key, 'playlist.m3u8')].Key | [0]" --output text 2>/dev/null || echo "None")
if [[ "$video_id" == "None" || -z "$video_id" ]]; then
  echo "No existing HLS output found -- uploading a synthetic test video via the API..."
  kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" wait deployment/api --for=condition=Available --timeout=120s
  kubectl --kubeconfig "$kubeconfig" -n "$APP_NAMESPACE" port-forward svc/api "${LOCAL_PORT}:80" >/dev/null 2>&1 &
  port_forward_pid=$!
  sleep 3

  tmpdir=$(mktemp -d)
  sample="$tmpdir/sample.mp4"
  ffmpeg -f lavfi -i testsrc=duration=3:size=640x360:rate=30 \
    -f lavfi -i sine=frequency=1000:duration=3 \
    -c:v libx264 -c:a aac -shortest -y -loglevel error "$sample"

  response=$(curl -sf -X POST "http://127.0.0.1:${LOCAL_PORT}/api/videos" -F "file=@${sample}")
  video_id=$(jq -r '.video_id' <<< "$response")
  echo "video_id=$video_id"

  job_ready() {
    local status
    status=$(curl -sf "http://127.0.0.1:${LOCAL_PORT}/api/videos/${video_id}" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || echo "")
    [[ "$status" == "succeeded" ]]
  }
  poll_until "$JOB_TIMEOUT_SECONDS" "transcode job completion" job_ready
  video_id="hls/${video_id}/playlist.m3u8"
else
  echo "Found existing HLS output: ${video_id}"
fi

playlist_url="https://${app_fqdn}/${video_id}"

cloudfront_serves_playlist() {
  local http_code
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" "$playlist_url" 2>/dev/null || echo "")
  [[ "$http_code" == "200" ]]
}
run_check "CloudFront serves the HLS playlist at ${playlist_url}" cloudfront_serves_playlist || overall=1

cache_header_present() {
  curl -sI "$playlist_url" 2>/dev/null | grep -qi "^x-cache:.*cloudfront"
}
run_check "response carries an X-Cache header from CloudFront (Hit or Miss)" cache_header_present || overall=1

tls_chain_valid() {
  local issuer
  issuer=$(echo | openssl s_client -connect "${app_fqdn}:443" -servername "${app_fqdn}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)
  [[ "$issuer" == *"Amazon"* ]]
}
run_check "TLS certificate chain for ${app_fqdn} is issued by Amazon (ACM)" tls_chain_valid || overall=1

if (( overall == 0 )); then
  echo "=== All checks passed: app.${domain_name} serves real HLS content via CloudFront over valid HTTPS, and argocd.${domain_name} is reachable straight off the shared ALB. ==="
else
  echo "=== One or more checks FAILED -- see output above. ===" >&2
fi

exit $overall

#!/usr/bin/env bash
# Syncs site/architecture/ to the persistent showcase bucket and invalidates
# the CloudFront cache so the change is visible immediately, instead of
# waiting out the cache TTL. Content-only deploy -- terraform/bootstrap/
# only owns the infrastructure (bucket, distribution), never the page's
# HTML/CSS/JS, so this is the only way updated content actually goes live.
#
# Usage: AWS_PROFILE=cloudlab ./scripts/deploy-architecture-site.sh
# Run from terraform/bootstrap/ (the script also cds there automatically).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

for bin in aws terraform; do
  command -v "$bin" >/dev/null || { echo "FAIL: '$bin' is required but not found in PATH" >&2; exit 1; }
done

echo "Reading Terraform outputs..."
bucket_name=$(terraform output -raw architecture_site_bucket_name)
distribution_id=$(terraform output -raw architecture_site_cloudfront_distribution_id)
site_url=$(terraform output -raw architecture_site_url)

echo "Syncing site/architecture/ to s3://$bucket_name ..."
aws s3 sync ../../site/architecture/ "s3://$bucket_name/" --delete

echo "Invalidating CloudFront cache ($distribution_id)..."
aws cloudfront create-invalidation --distribution-id "$distribution_id" --paths "/*" >/dev/null

echo "Deployed: $site_url"

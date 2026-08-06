#!/usr/bin/env bash
# remediate-billing-leak.sh
#
# Deletes MiniTube orphaned resources found billing after the supposed
# 2026-08-02 full teardown (S3 bucket, CloudFront distribution, Route53
# hosted zone, ECR repo, orphaned EBS volume, KMS customer-managed key).
# Run in AWS CloudShell (inherits console session credentials - admin/root,
# not the destroyed `cloudlab-operator` SSO role).
#
# After this runs clean, reconcile Terraform state in bootstrap-iam/,
# bootstrap/, and envs/lab/ (they should already show these as gone) and
# record an ADR on why the 2026-08-02 teardown didn't fully take.
set -euo pipefail

tmpfile="$(mktemp)"
trap 'rm -f "$tmpfile"' EXIT

echo "=== 0. Confirms identity ==="
aws sts get-caller-identity

echo
echo "=== PHASE 1: DISCOVERY (read-only) ==="

echo "--- S3 buckets ---"
buckets=$(aws s3api list-buckets --query "Buckets[].Name" --output text)
echo "$buckets"

echo "--- CloudFront distributions ---"
dist_ids=$(aws cloudfront list-distributions --query "DistributionList.Items[].Id" --output text 2>/dev/null || true)
aws cloudfront list-distributions \
  --query "DistributionList.Items[].{Id:Id,Domain:DomainName,Comment:Comment,Enabled:Enabled,Status:Status}" \
  --output table 2>/dev/null || echo "(none)"

echo "--- Route53 hosted zones ---"
zone_ids=$(aws route53 list-hosted-zones --query "HostedZones[].Id" --output text)
aws route53 list-hosted-zones --query "HostedZones[].{Id:Id,Name:Name}" --output table

echo "--- ECR repositories ---"
repos=$(aws ecr describe-repositories --query "repositories[].repositoryName" --output text 2>/dev/null || true)
echo "$repos"

echo "--- EBS volumes available (unattached) ---"
volume_ids=$(aws ec2 describe-volumes --filters Name=status,Values=available --query "Volumes[].VolumeId" --output text)
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query "Volumes[].{Id:VolumeId,SizeGB:Size,Type:VolumeType}" --output table

echo "--- KMS customer-managed keys (enabled, not AWS-managed) ---"
kms_key_ids=""
for kid in $(aws kms list-keys --query "Keys[].KeyId" --output text); do
  meta=$(aws kms describe-key --key-id "$kid" --query "KeyMetadata.[KeyManager,KeyState]" --output text)
  manager=$(echo "$meta" | awk '{print $1}')
  state=$(echo "$meta" | awk '{print $2}')
  if [[ "$manager" == "CUSTOMER" && "$state" == "Enabled" ]]; then
    echo "$kid -> $manager / $state"
    kms_key_ids="$kms_key_ids $kid"
  fi
done

echo
echo ">>> Review the list above. Press ENTER to proceed with deletion, or Ctrl+C to abort."
read -r

echo
echo "=== PHASE 2: DELETION ==="

# --- CloudFront: must disable and wait for propagation before delete ---
for id in $dist_ids; do
  [[ -z "$id" ]] && continue
  echo "--- CloudFront $id: disabling ---"
  aws cloudfront get-distribution-config --id "$id" > "$tmpfile"
  etag=$(jq -r .ETag "$tmpfile")
  jq '.DistributionConfig | .Enabled = false' "$tmpfile" > "${tmpfile}.cfg"
  aws cloudfront update-distribution --id "$id" --distribution-config "file://${tmpfile}.cfg" --if-match "$etag" >/dev/null
  echo "--- CloudFront $id: waiting for deployment (~15-20min, this blocks) ---"
  aws cloudfront wait distribution-deployed --id "$id"
  etag2=$(aws cloudfront get-distribution --id "$id" --query ETag --output text)
  echo "--- CloudFront $id: deleting ---"
  aws cloudfront delete-distribution --id "$id" --if-match "$etag2"
  rm -f "${tmpfile}.cfg"
done

# --- Route53: strip non-default records, then delete the zone ---
for zid_raw in $zone_ids; do
  [[ -z "$zid_raw" ]] && continue
  zid="${zid_raw#/hostedzone/}"
  echo "--- Route53 zone $zid: removing non-NS/SOA records ---"
  aws route53 list-resource-record-sets --hosted-zone-id "$zid" --output json \
    | jq -c '.ResourceRecordSets[] | select(.Type != "NS" and .Type != "SOA")' \
    | while read -r rec; do
        jq -n --argjson r "$rec" '{Changes:[{Action:"DELETE",ResourceRecordSet:$r}]}' > "$tmpfile"
        aws route53 change-resource-record-sets --hosted-zone-id "$zid" --change-batch "file://$tmpfile"
      done
  echo "--- Route53 zone $zid: deleting ---"
  aws route53 delete-hosted-zone --id "$zid"
done

# --- S3: empty (including versions/delete markers) then delete bucket ---
for bucket in $buckets; do
  [[ -z "$bucket" ]] && continue
  echo "--- S3 bucket $bucket: emptying current objects ---"
  aws s3 rm "s3://$bucket" --recursive || true
  echo "--- S3 bucket $bucket: purging versions/delete markers (if versioned) ---"
  aws s3api list-object-versions --bucket "$bucket" --output json \
    | jq -c '(.Versions // []) + (.DeleteMarkers // []) | .[] | {Key:.Key, VersionId:.VersionId}' \
    | while read -r obj; do
        key=$(echo "$obj" | jq -r .Key)
        vid=$(echo "$obj" | jq -r .VersionId)
        aws s3api delete-object --bucket "$bucket" --key "$key" --version-id "$vid" >/dev/null
      done
  echo "--- S3 bucket $bucket: deleting ---"
  aws s3api delete-bucket --bucket "$bucket"
done

# --- ECR: force-delete repos (removes stored images too) ---
for repo in $repos; do
  [[ -z "$repo" ]] && continue
  echo "--- ECR repo $repo: force-deleting ---"
  aws ecr delete-repository --repository-name "$repo" --force
done

# --- EBS: delete unattached volumes ---
for vid in $volume_ids; do
  [[ -z "$vid" ]] && continue
  echo "--- EBS volume $vid: deleting ---"
  aws ec2 delete-volume --volume-id "$vid"
done

# --- KMS: schedule deletion (7-day minimum window, AWS-enforced, can't be instant) ---
for kid in $kms_key_ids; do
  echo "--- KMS key $kid: scheduling deletion (7-day min window) ---"
  aws kms schedule-key-deletion --key-id "$kid" --pending-window-in-days 7
done

echo
echo "=== DONE. Re-run the Cost Explorer / Bills screen in a few hours to confirm charges stopped. ==="
echo "=== KMS key(s) will still show ~1 dollar/month prorated until day 7 - that is an AWS-enforced minimum, not a leftover bug. ==="

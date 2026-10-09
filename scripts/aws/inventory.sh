#!/usr/bin/env bash
# Phase 14 - list every resource tagged Project=ems (plus the fixed-name ones), or prove that none is left.
#   scripts/aws/inventory.sh                 list what exists
#   scripts/aws/inventory.sh --expect-empty  exit 1 if anything still exists (after a teardown)
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
EXPECT_EMPTY=false
DRY_RUN=false

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--region REGION] [--expect-empty] [--dry-run] [--help]
Lists AWS resources of the EMS platform (tag Project=ems, ECR ems-app, IAM ems-*, state bucket and lock table).
  --expect-empty  fail when any resource is still there (use after terraform destroy)
  --dry-run       print the AWS CLI calls instead of running them
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --region) REGION="${2:?--region needs a value}"; shift 2 ;;
    --expect-empty) EXPECT_EMPTY=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

found=0
check() {           # check LABEL -- aws args...   (the command prints one line per resource)
  local label="$1"; shift 2
  if $DRY_RUN; then echo "aws $*"; return; fi
  local out
  out="$(aws "$@" 2>/dev/null | sed '/^None$/d;/^$/d' || true)"
  if [ -n "$out" ]; then
    found=$((found + $(printf '%s\n' "$out" | wc -w)))
    printf '%-22s %s\n' "$label" "$(printf '%s' "$out" | tr '\n' ' ')"
  else
    printf '%-22s -\n' "$label"
  fi
}

check "tagged resources" -- resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters Key=Project,Values=ems --query 'ResourceTagMappingList[].ResourceARN' --output text
check "ec2 instances" -- ec2 describe-instances --region "$REGION" \
  --filters Name=tag:Project,Values=ems Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId' --output text
check "load balancers" -- elbv2 describe-load-balancers --region "$REGION" \
  --query "LoadBalancers[?starts_with(LoadBalancerName, 'ems-')].LoadBalancerName" --output text
check "ecr repositories" -- ecr describe-repositories --region "$REGION" \
  --query "repositories[?repositoryName=='ems-app'].repositoryName" --output text
check "iam roles" -- iam list-roles --query "Roles[?starts_with(RoleName, 'ems-')].RoleName" --output text
check "iam policies" -- iam list-policies --scope Local --query "Policies[?starts_with(PolicyName, 'ems-')].PolicyName" --output text
check "s3 buckets" -- s3api list-buckets --query "Buckets[?starts_with(Name, 'ems-')].Name" --output text
check "dynamodb lock table" -- dynamodb list-tables --region "$REGION" --query "TableNames[?@=='ems-tf-locks']" --output text

$DRY_RUN && exit 0
echo "total: $found"
if $EXPECT_EMPTY && [ "$found" -gt 0 ]; then
  echo "FAIL: $found EMS resources still exist" >&2
  exit 1
fi

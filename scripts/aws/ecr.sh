#!/usr/bin/env bash
# Phase 17 - push a locally built image to ECR by hand (CD does this automatically from ghcr.io)
#   scripts/aws/ecr.sh push v1.0.0      build ems-app:v1.0.0 and push it
#   scripts/aws/ecr.sh scan v1.0.0      show the scan-on-push findings
#   scripts/aws/ecr.sh list             list the tags in the repository
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
REPO="ems-app"
DRY_RUN=false

usage() {
  echo "Usage: $(basename "$0") push TAG | scan TAG | list | login  [--region R] [--dry-run] [--help]"
}

run() { if $DRY_RUN; then echo "+ $*"; else "$@"; fi; }

args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --region) REGION="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ "${#args[@]}" -ge 1 ] || { usage >&2; exit 2; }

if $DRY_RUN; then
  ACCOUNT="123456789012"
else
  ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
fi
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

login() {
  if $DRY_RUN; then echo "+ aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY"; return; fi
  aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
}

case "${args[0]}" in
  login) login ;;
  push)
    tag="${args[1]:?push needs a TAG}"
    login
    run docker build --build-arg "APP_VERSION=$tag" --build-arg "VCS_REF=$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
      -t "$REGISTRY/$REPO:$tag" .
    run docker push "$REGISTRY/$REPO:$tag"
    ;;
  scan)
    tag="${args[1]:?scan needs a TAG}"
    run aws ecr wait image-scan-complete --region "$REGION" --repository-name "$REPO" --image-id "imageTag=$tag"
    run aws ecr describe-image-scan-findings --region "$REGION" --repository-name "$REPO" --image-id "imageTag=$tag" \
      --query 'imageScanFindings.findingSeverityCounts'
    ;;
  list)
    run aws ecr describe-images --region "$REGION" --repository-name "$REPO" \
      --query 'sort_by(imageDetails,&imagePushedAt)[].[imageTags[0],imagePushedAt,imageSizeInBytes]' --output table
    ;;
  *) usage >&2; exit 2 ;;
esac

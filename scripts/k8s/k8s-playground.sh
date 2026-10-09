#!/usr/bin/env bash
# Phase 23 - deploy k8s/overlays/playground to EKS with the ECR image ACCOUNT.dkr.ecr.REGION.amazonaws.com/ems-app:TAG.
# The overlay keeps the placeholders ACCOUNT_ID / IMAGE_TAG; this script substitutes them in the rendered
# output, so nothing account-specific is written to git.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACCOUNT=""
REGION="us-east-1"
TAG=""
TIMEOUT="300s"
DRY_RUN=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") --tag TAG [--account 123456789012] [--region us-east-1] [--timeout 300s] [--dry-run] [--help]

Renders k8s/overlays/playground with the ECR image, applies it to the current kubectl context
(aws eks update-kubeconfig ... first) and waits for the rollout.
--account defaults to the account of the current AWS credentials (aws sts get-caller-identity).

  --dry-run     print the commands instead of running them (does not call AWS)
  --help        show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --account) ACCOUNT="${2:?--account needs a value}"; shift ;;
        --region) REGION="${2:?--region needs a value}"; shift ;;
        --tag) TAG="${2:?--tag needs a value}"; shift ;;
        --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ -z "$TAG" ]]; then
    echo "--tag is required" >&2
    exit 2
fi

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '+'; printf ' %q' "$@"; printf '\n'
    else
        "$@"
    fi
}

if [[ -z "$ACCOUNT" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        ACCOUNT="ACCOUNT_ID"
    else
        ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
    fi
fi
if [[ ! -f "$ROOT/k8s/base/secret.env" ]]; then
    echo "k8s/base/secret.env is missing: copy k8s/base/secret.env.example and set strong values" >&2
    [[ "$DRY_RUN" -eq 1 ]] || exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ kubectl kustomize $ROOT/k8s/overlays/playground | sed s/ACCOUNT_ID/$ACCOUNT/ s/IMAGE_TAG/$TAG/ s/us-east-1/$REGION/ | kubectl apply -f -"
else
    kubectl kustomize "$ROOT/k8s/overlays/playground" \
        | sed -e "s/ACCOUNT_ID\.dkr\.ecr\.us-east-1/$ACCOUNT.dkr.ecr.$REGION/" -e "s/:IMAGE_TAG\$/:$TAG/" \
        | kubectl apply -f -
fi
run kubectl -n ems rollout status statefulset/postgres --timeout "$TIMEOUT"
run kubectl -n ems rollout status deployment/ems-app --timeout "$TIMEOUT"
run kubectl -n ems get pods,svc,ingress,hpa

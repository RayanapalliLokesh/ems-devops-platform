#!/usr/bin/env bash
# Phase 19 - connect the GitHub repository to the current playground session (and disconnect it again).
#   enable   secrets EMS_HOST + EMS_SSH_KEY, variables for the role, ECR, SG, bucket and URL, environment "playground"
#            with the repository owner as required reviewer
#   disable  remove them (the playground account is gone at the end of the session anyway)
#   status   show what is set
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${GITHUB_REPOSITORY:-RayanapalliLokesh/ems-devops-platform}"
KEY="${EMS_DEPLOY_KEY:-$ROOT/.secrets/ems-deploy}"
DRY_RUN=false

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
  echo "Usage: $(basename "$0") enable|disable|status [--repo OWNER/NAME] [--dry-run] [--help]"
}

run() { if $DRY_RUN; then echo "+ $*"; else "$@"; fi; }

cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    enable|disable|status) cmd="$1"; shift ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[ -n "$cmd" ] || { usage >&2; exit 2; }

VARS=(AWS_DEPLOY_ROLE_ARN AWS_REGION EMS_ECR_REPOSITORY EMS_HOST_SG_ID EMS_BACKUP_BUCKET EMS_APP_URL)

tf_out() {   # tf_out DIR NAME
  if $DRY_RUN; then echo "<$2>"; else terraform -chdir="$ROOT/terraform/$1" output -raw "$2"; fi
}

case "$cmd" in
  enable)
    host="$(tf_out envs/dev host_public_ip)"
    run gh secret set EMS_HOST --repo "$REPO" --body "$host"
    if $DRY_RUN; then echo "+ gh secret set EMS_SSH_KEY --repo $REPO < $KEY"
    else gh secret set EMS_SSH_KEY --repo "$REPO" < "$KEY"; fi
    run gh variable set AWS_DEPLOY_ROLE_ARN --repo "$REPO" --body "$(tf_out registry github_deploy_role_arn)"
    run gh variable set AWS_REGION --repo "$REPO" --body "${AWS_REGION:-us-east-1}"
    run gh variable set EMS_ECR_REPOSITORY --repo "$REPO" --body "$(tf_out envs/dev ecr_repository_url)"
    run gh variable set EMS_HOST_SG_ID --repo "$REPO" --body "$(tf_out envs/dev host_security_group_id)"
    run gh variable set EMS_BACKUP_BUCKET --repo "$REPO" --body "$(tf_out envs/dev backup_bucket)"
    run gh variable set EMS_APP_URL --repo "$REPO" --body "$(tf_out envs/dev app_url)"
    if $DRY_RUN; then owner_id="<owner id>"; else owner_id="$(gh api "users/${REPO%%/*}" --jq .id)"; fi
    if $DRY_RUN; then
      echo "+ gh api -X PUT repos/$REPO/environments/playground (required reviewer: $owner_id)"
    else
      gh api -X PUT "repos/$REPO/environments/playground" --input - >/dev/null <<JSON
{"reviewers":[{"type":"User","id":$owner_id}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
      gh api -X POST "repos/$REPO/environments/playground/deployment-branch-policies" \
        -f name='v*.*.*' -f type=tag >/dev/null 2>&1 || true
      gh api -X POST "repos/$REPO/environments/playground/deployment-branch-policies" \
        -f name='main' -f type=branch >/dev/null 2>&1 || true
    fi
    echo "CD enabled for $REPO"
    ;;
  disable)
    run gh secret delete EMS_HOST --repo "$REPO" || true
    run gh secret delete EMS_SSH_KEY --repo "$REPO" || true
    for v in "${VARS[@]}"; do run gh variable delete "$v" --repo "$REPO" || true; done
    echo "CD disabled for $REPO (the deploy jobs are skipped until enable runs again)"
    ;;
  status)
    run gh secret list --repo "$REPO"
    run gh variable list --repo "$REPO"
    ;;
esac

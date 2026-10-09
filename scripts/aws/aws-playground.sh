#!/usr/bin/env bash
# Phase 20 - the whole playground lifecycle with Terraform, in order:
#   bootstrap  remote state (S3 + DynamoDB)          registry  ECR + GitHub OIDC deploy role
#   up         dev environment (writes terraform.tfvars with your IP and the deploy key, plans, asks, applies)
#   deploy TAG Ansible site.yml with that image tag  drift     terraform plan -detailed-exitcode (2 = drift)
#   outputs    dev outputs                           down      destroy dev, registry and state (reverse order)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF="$ROOT/terraform"
KEY="${EMS_DEPLOY_KEY:-$ROOT/.secrets/ems-deploy}"
REPO_SLUG="${GITHUB_REPOSITORY:-RayanapalliLokesh/ems-devops-platform}"
DRY_RUN=false

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
  echo "Usage: $(basename "$0") bootstrap|registry|up|deploy TAG|drift|outputs|down [--dry-run] [--help]"
}

run() { if $DRY_RUN; then echo "+ $*"; else "$@"; fi; }

args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) args+=("$1"); shift ;;
  esac
done
[ "${#args[@]}" -ge 1 ] || { usage >&2; exit 2; }

plan_and_apply() {     # plan_and_apply DIR [terraform plan args...]: the plan is shown and saved, then applied
  local dir="$1"; shift
  run terraform -chdir="$dir" plan -input=false -out=tfplan "$@"
  if ! $DRY_RUN; then
    read -r -p "Apply this plan? [y/N] " answer
    [ "$answer" = "y" ] || { echo "not applied"; return 1; }
  fi
  run terraform -chdir="$dir" apply -input=false tfplan
}

case "${args[0]}" in
  bootstrap)
    run terraform -chdir="$TF/bootstrap-state" init -input=false
    plan_and_apply "$TF/bootstrap-state"
    if $DRY_RUN; then echo "+ terraform -chdir=$TF/bootstrap-state output -raw backend_config > $TF/backend.hcl"
    else terraform -chdir="$TF/bootstrap-state" output -raw backend_config > "$TF/backend.hcl"; fi
    ;;
  registry)
    run terraform -chdir="$TF/registry" init -input=false -reconfigure -backend-config=../backend.hcl
    sub_prefix=""
    if ! $DRY_RUN && command -v gh >/dev/null; then   # newer repositories use immutable OIDC subjects (owner@id/name@id)
      sub_prefix="$(gh api "repos/$REPO_SLUG/actions/oidc/customization/sub" --jq '.sub_claim_prefix // empty' 2>/dev/null || true)"
    fi
    plan_and_apply "$TF/registry" -var "github_repository=$REPO_SLUG" -var "github_sub_prefix=$sub_prefix"
    ;;
  up)
    [ -f "$KEY" ] || run ssh-keygen -q -t ed25519 -N '' -C ems-deploy -f "$KEY"
    if ! $DRY_RUN; then
      ip="$(curl -fsS https://checkip.amazonaws.com)"
      printf 'region         = "%s"\ninstance_type  = "t3.medium"\nssh_cidrs      = ["%s/32"]\nssh_public_key = "%s"\n' \
        "${AWS_REGION:-us-east-1}" "$ip" "$(cat "$KEY.pub")" > "$TF/envs/dev/terraform.tfvars"
    fi
    run terraform -chdir="$TF/envs/dev" init -input=false -reconfigure -backend-config=../../backend.hcl
    plan_and_apply "$TF/envs/dev"
    ;;
  deploy)
    tag="${args[1]:?deploy needs an image TAG that exists in ECR}"
    cd "$ROOT/ansible"
    run ansible-playbook -i inventories/aws/hosts.yml playbooks/site.yml --private-key "$KEY" -e "ems_image_tag=$tag"
    ;;
  drift)
    set +e
    run terraform -chdir="$TF/envs/dev" plan -input=false -detailed-exitcode -lock=false
    rc=$?
    set -e
    case "$rc" in
      0) echo "no drift" ;;
      2) echo "DRIFT: the real infrastructure differs from the code (see the plan above)"; exit 2 ;;
      *) echo "plan failed"; exit "$rc" ;;
    esac
    ;;
  outputs) run terraform -chdir="$TF/envs/dev" output ;;
  down)
    for dir in envs/dev registry bootstrap-state; do
      if [ "$dir" = registry ]; then extra=(-var "github_repository=$REPO_SLUG" -var "github_sub_prefix=x"); else extra=(); fi
      run terraform -chdir="$TF/$dir" plan -destroy -input=false -out=tfplan "${extra[@]}"
      if ! $DRY_RUN; then
        read -r -p "Destroy $dir? [y/N] " answer
        [ "$answer" = "y" ] || { echo "stopped"; exit 1; }
      fi
      run terraform -chdir="$TF/$dir" apply -input=false tfplan
    done
    run "$ROOT/scripts/aws/inventory.sh" --expect-empty
    ;;
  *) usage >&2; exit 2 ;;
esac

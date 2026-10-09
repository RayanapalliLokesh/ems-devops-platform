#!/usr/bin/env bash
# Chaos scenario: Terraform drift (Phase 25, docs/sre/game-days.md#terraform-drift)
# Someone "fixes something in the console": a tag is added to the ALB security group with the AWS CLI.
# `terraform plan -detailed-exitcode` in terraform/envs/dev must notice it (exit code 2 = changes pending).
# Revert deletes the tag again (targeted; no apply of the whole environment) and re-plans (exit code 0).
# Never use `terraform apply -refresh-only` to "fix" drift: it writes the console change INTO the state.
set -euo pipefail

ACTION=""
DRY_RUN=false
KEEP=false
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform/envs/dev"
SG_NAME=ems-dev-alb-sg
SG_ID=""
TAG_KEY=ChaosDrift

usage() {
    cat <<EOF
Usage: $(basename "$0") (--inject | --revert | --detect) [options]
       $(basename "$0") --dry-run            print the inject, detect and revert commands, run nothing

Create drift on the ALB security group and prove that Terraform detects it.

  --inject           add the tag, run the drift check, then revert (unless --keep)
  --detect           only run terraform plan -detailed-exitcode (0 = no drift, 2 = drift)
  --revert           delete the tag and re-check
  --keep             with --inject: leave the drift in place for the drill (revert later with --revert)
  --dry-run          only print the commands that would run
  --sg-id ID         security group id (default: looked up by tag Name=<sg-name>)
  --sg-name NAME     name of the ALB security group (default: ems-dev-alb-sg)
  --tf-dir DIR       Terraform root module (default: <repo>/terraform/envs/dev)
  -h, --help         show this help
Uses the AWS credentials and region of the current shell (AWS_PROFILE / AWS_REGION).
EOF
}

run() {
    # print the command (quoted only where needed), then run it unless this is a dry run
    local line="+" arg
    for arg in "$@"; do
        if [[ "$arg" =~ ^[A-Za-z0-9_./:=,@%+-]+$ ]]; then line+=" $arg"; else line+=" ${arg@Q}"; fi
    done
    printf '%s\n' "$line"
    if [[ "$DRY_RUN" == false ]]; then
        "$@"
    fi
}

note() { printf '# %s\n' "$*"; }

require() {
    [[ "$DRY_RUN" == true ]] && return 0
    command -v "$1" >/dev/null || { echo "error: $1 is not installed" >&2; exit 1; }
}

resolve_sg() {
    [[ -n "$SG_ID" ]] && return 0
    local lookup=(aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME"
        --query 'SecurityGroups[0].GroupId' --output text)
    if [[ "$DRY_RUN" == true ]]; then
        run "${lookup[@]}"
        SG_ID="<sg-id>"
    else
        SG_ID="$("${lookup[@]}")"
        [[ "$SG_ID" == sg-* ]] || { echo "error: no security group named $SG_NAME (use --sg-id)" >&2; exit 1; }
        note "security group: $SG_ID"
    fi
}

detect() {
    require terraform
    local rc=0
    run terraform -chdir="$TF_DIR" init -input=false -no-color
    run terraform -chdir="$TF_DIR" plan -detailed-exitcode -input=false -lock=false -no-color || rc=$?
    [[ "$DRY_RUN" == true ]] && { note "exit code 0 = no drift, 2 = drift detected, 1 = error"; return 0; }
    case "$rc" in
        0) note "no drift: the infrastructure matches the code" ;;
        2) note "DRIFT DETECTED: terraform plan wants to change the infrastructure back" ;;
        *) echo "error: terraform plan failed (exit $rc)" >&2; return "$rc" ;;
    esac
}

inject() {
    require aws
    resolve_sg
    run aws ec2 create-tags --resources "$SG_ID" --tags "Key=$TAG_KEY,Value=$(date -u +%Y%m%dT%H%M%SZ)"
    detect
}

revert() {
    require aws
    resolve_sg
    run aws ec2 delete-tags --resources "$SG_ID" --tags "Key=$TAG_KEY"
    detect
}

if [[ $# -eq 0 ]]; then
    usage
    exit 2
fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        --inject) ACTION=inject ;;
        --revert) ACTION=revert ;;
        --detect) ACTION=detect ;;
        --keep) KEEP=true ;;
        --dry-run) DRY_RUN=true ;;
        --sg-id) SG_ID="${2:-}"; shift ;;
        --sg-name) SG_NAME="${2:-}"; shift ;;
        --tf-dir) TF_DIR="${2:-}"; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ -z "$ACTION" ]]; then
    [[ "$DRY_RUN" == true ]] || { usage >&2; exit 2; }
    ACTION=plan
fi

case "$ACTION" in
    inject)
        if [[ "$KEEP" == false ]]; then
            trap revert EXIT
            trap 'exit 130' INT TERM
        fi
        inject
        if [[ "$KEEP" == true ]]; then
            note "drift stays until: $0 --revert"
        fi
        ;;
    detect) detect ;;
    revert) revert ;;
    plan)
        note "dry run: inject + detect"
        inject
        note "revert + detect again"
        revert
        ;;
esac

#!/usr/bin/env bash
# Phase 12 (updated for Phase 17) - back up the EMS PostgreSQL database that runs in the "db" container.
# Phase 12 ran pg_dump against the host PostgreSQL from a systemd timer; since Phase 17 the database lives in
# the Compose stack, so the dump is taken through `docker compose exec`. The user and database name are read
# inside the container ($POSTGRES_USER / $POSTGRES_DB), so no password is needed on the host.
# S3 upload uses the EC2 instance role (ems-host-role): no access keys are stored anywhere.
set -euo pipefail

PROJECT="ems"
BACKUP_DIR="/var/backups/ems"
KEEP=7
S3_BUCKET=""
S3_PREFIX="backups"
RESTORE_FILE=""
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: backup-db.sh [options]
       backup-db.sh --restore FILE [options]

Back up (default) or restore the EMS database of the Compose stack.

Options:
  --project NAME      Compose project name (default: ems)
  --dir DIR           local backup directory (default: /var/backups/ems)
  --keep N            local backups to keep, older ones are deleted (default: 7)
  --s3-bucket NAME    also upload to s3://NAME/backups/ with `aws s3 cp` (uses the instance role, no keys)
  --s3-prefix PREFIX  key prefix in the bucket (default: backups; the IAM policy and lifecycle rule cover backups/ only)
  --restore FILE      restore FILE (.sql.gz) into the database; existing objects are dropped first
  --dry-run           print the commands, run nothing
  --help              show this help

Examples:
  sudo scripts/linux/backup-db.sh --s3-bucket ems-backups-123456789012
  sudo scripts/linux/backup-db.sh --restore /var/backups/ems/ems-20261009T020000Z.sql.gz
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) PROJECT="${2:?--project needs a value}"; shift 2 ;;
        --dir) BACKUP_DIR="${2:?--dir needs a value}"; shift 2 ;;
        --keep) KEEP="${2:?--keep needs a value}"; shift 2 ;;
        --s3-bucket) S3_BUCKET="${2:?--s3-bucket needs a value}"; shift 2 ;;
        --s3-prefix) S3_PREFIX="${2:?--s3-prefix needs a value}"; shift 2 ;;
        --restore) RESTORE_FILE="${2:?--restore needs a file}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || { echo "--keep must be a positive number" >&2; exit 2; }

log() { echo "[backup-db] $*"; }
show() { printf '+ %s\n' "$*"; }

# The shell inside the container expands the variables, so the host needs neither the user nor a password
# shellcheck disable=SC2016  # single quotes on purpose: expanded by sh inside the container
DUMP_CMD='pg_dump --no-owner --clean --if-exists -U "$POSTGRES_USER" "$POSTGRES_DB"'
# shellcheck disable=SC2016
PSQL_CMD='psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" "$POSTGRES_DB"'
COMPOSE=(docker compose -p "$PROJECT")

require_db() {
    if ! "${COMPOSE[@]}" exec -T db pg_isready -q >/dev/null 2>&1; then
        echo "db service of project $PROJECT is not running or not ready (docker compose -p $PROJECT ps)" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------------------------- restore
if [[ -n "$RESTORE_FILE" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        show "gunzip -c '$RESTORE_FILE' | ${COMPOSE[*]} exec -T db sh -c '$PSQL_CMD'"
        show "curl -fsS http://127.0.0.1/health"
        exit 0
    fi
    [[ -r "$RESTORE_FILE" ]] || { echo "cannot read $RESTORE_FILE" >&2; exit 1; }
    gzip -t "$RESTORE_FILE" || { echo "$RESTORE_FILE is not a valid gzip file" >&2; exit 1; }
    require_db
    log "restoring $RESTORE_FILE into project $PROJECT (the dump drops and recreates its objects)"
    gunzip -c "$RESTORE_FILE" | "${COMPOSE[@]}" exec -T db sh -c "$PSQL_CMD" >/dev/null
    log "restore finished; check the app: curl -fsS http://127.0.0.1/health"
    exit 0
fi

# ----------------------------------------------------------------------------------------------- backup
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FILE="$BACKUP_DIR/${PROJECT}-${STAMP}.sql.gz"

if [[ $DRY_RUN -eq 1 ]]; then
    show "install -d -m 0750 '$BACKUP_DIR'"
    show "${COMPOSE[*]} exec -T db sh -c '$DUMP_CMD' | gzip -9 > '$FILE.partial'"
    show "gzip -t '$FILE.partial' && mv '$FILE.partial' '$FILE'"
    show "keep the newest $KEEP of $BACKUP_DIR/${PROJECT}-*.sql.gz, delete the rest"
    if [[ -n "$S3_BUCKET" ]]; then
        show "aws s3 cp '$FILE' 's3://$S3_BUCKET/$S3_PREFIX/$(basename "$FILE")' --only-show-errors"
    fi
    exit 0
fi

require_db
install -d -m 0750 "$BACKUP_DIR"
log "dumping project $PROJECT to $FILE"
# write to .partial first: a failed dump must never look like a good backup or push out an older good one
"${COMPOSE[@]}" exec -T db sh -c "$DUMP_CMD" | gzip -9 > "$FILE.partial"
gzip -t "$FILE.partial"
mv "$FILE.partial" "$FILE"
chmod 0640 "$FILE"
log "done: $(du -h "$FILE" | cut -f1)"

# keep the newest $KEEP backups
mapfile -t old < <(find "$BACKUP_DIR" -maxdepth 1 -name "${PROJECT}-*.sql.gz" -printf '%T@ %p\n' \
    | sort -rn | tail -n +$((KEEP + 1)) | cut -d' ' -f2-)
for f in "${old[@]}"; do
    log "removing old backup $f"
    rm -f -- "$f"
done

if [[ -n "$S3_BUCKET" ]]; then
    command -v aws >/dev/null 2>&1 || { echo "aws CLI not installed; local backup kept at $FILE" >&2; exit 1; }
    log "uploading to s3://$S3_BUCKET/$S3_PREFIX/ (instance role credentials)"
    aws s3 cp "$FILE" "s3://$S3_BUCKET/$S3_PREFIX/$(basename "$FILE")" --only-show-errors
    log "uploaded"
fi

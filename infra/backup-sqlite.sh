#!/usr/bin/env bash
# backup-sqlite.sh — Daily SQLite backup for NineChronicles.EthBridge
#
# Usage:
#   ./backup-sqlite.sh
#
# Environment:
#   S3_BUCKET  — Target S3 bucket name (can also be set in /data/.env)
#
# Cron example (run daily at 02:00 UTC):
#   0 2 * * * /opt/bridge/backup-sqlite.sh >> /var/log/bridge-backup.log 2>&1

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DB_DIR="/data/sqlite"
DB_FILES=("bridge.db" "exchange_histories.db")
ENV_FILE="/data/.env"
LOG_FILE="/var/log/bridge-backup.log"
RETENTION_DAYS=30
TIMESTAMP="$(date -u '+%Y%m%d_%H%M%S')"

# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------
log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG_FILE"
}

# ---------------------------------------------------------------------------
# Load S3_BUCKET from /data/.env if not already set in environment
# ---------------------------------------------------------------------------
if [[ -z "${S3_BUCKET:-}" ]]; then
    if [[ -f "$ENV_FILE" ]]; then
        # Extract only the S3_BUCKET line to avoid polluting the environment
        S3_BUCKET="$(grep -E '^S3_BUCKET=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
    fi
fi

if [[ -z "${S3_BUCKET:-}" ]]; then
    log "ERROR: S3_BUCKET is not set. Set it in the environment or in $ENV_FILE."
    exit 1
fi

# ---------------------------------------------------------------------------
# Validate source directory
# ---------------------------------------------------------------------------
if [[ ! -d "$DB_DIR" ]]; then
    log "ERROR: Database directory $DB_DIR does not exist."
    exit 1
fi

# ---------------------------------------------------------------------------
# Backup each database file
# ---------------------------------------------------------------------------
FAILED=0

for DB_NAME in "${DB_FILES[@]}"; do
    DB_PATH="$DB_DIR/$DB_NAME"

    if [[ ! -f "$DB_PATH" ]]; then
        log "WARNING: $DB_PATH not found — skipping."
        continue
    fi

    BASE_NAME="${DB_NAME%.db}"
    ARCHIVE_NAME="${BASE_NAME}_${TIMESTAMP}.db.gz"
    TMP_ARCHIVE="/tmp/${ARCHIVE_NAME}"
    S3_KEY="backups/${ARCHIVE_NAME}"

    log "Backing up $DB_PATH -> s3://${S3_BUCKET}/${S3_KEY}"

    # Compress with gzip (-k keeps the source file intact)
    if ! gzip -k -c "$DB_PATH" > "$TMP_ARCHIVE"; then
        log "ERROR: Failed to compress $DB_PATH."
        rm -f "$TMP_ARCHIVE"
        FAILED=1
        continue
    fi

    # Upload to S3
    if ! aws s3 cp "$TMP_ARCHIVE" "s3://${S3_BUCKET}/${S3_KEY}" --sse AES256; then
        log "ERROR: Failed to upload $ARCHIVE_NAME to S3."
        rm -f "$TMP_ARCHIVE"
        FAILED=1
        continue
    fi

    rm -f "$TMP_ARCHIVE"
    log "OK: $ARCHIVE_NAME uploaded successfully."
done

# ---------------------------------------------------------------------------
# Delete backups older than RETENTION_DAYS from S3
# ---------------------------------------------------------------------------
log "Pruning backups older than ${RETENTION_DAYS} days from s3://${S3_BUCKET}/backups/"

CUTOFF_DATE="$(date -u -d "-${RETENTION_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v "-${RETENTION_DAYS}d" '+%Y-%m-%dT%H:%M:%SZ')"  # macOS fallback

DELETED=0
while IFS= read -r LINE; do
    # aws s3 ls output: "YYYY-MM-DD HH:MM:SS  <size>  <key>"
    FILE_DATE="$(echo "$LINE" | awk '{print $1"T"$2"Z"}')"
    FILE_KEY="$(echo "$LINE" | awk '{print $4}')"

    if [[ "$FILE_DATE" < "$CUTOFF_DATE" ]]; then
        if aws s3 rm "s3://${S3_BUCKET}/backups/${FILE_KEY}"; then
            log "Deleted old backup: $FILE_KEY"
            DELETED=$((DELETED + 1))
        else
            log "WARNING: Failed to delete $FILE_KEY."
        fi
    fi
done < <(aws s3 ls "s3://${S3_BUCKET}/backups/" 2>/dev/null || true)

log "Pruned $DELETED old backup(s)."

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
if [[ "$FAILED" -ne 0 ]]; then
    log "ERROR: One or more backups failed."
    exit 1
fi

log "Backup completed successfully."
exit 0

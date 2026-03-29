#!/bin/bash
# migrate-sqlite.sh
#
# Safely migrates SQLite state from the OLD EC2 instance to a NEW EC2 instance
# using S3 as the intermediate transfer layer.
#
# WHY NOT binary copy?
#   Copying an SQLite file while the process has it open can yield a corrupt
#   database.  Using `.dump` produces a portable SQL text dump that is safe to
#   run against the running database via sqlite3's built-in backup mechanism.
#
# PREREQUISITES on the operator machine:
#   - AWS CLI configured with sufficient permissions
#   - SSH key that can access OLD_INSTANCE_IP (key agent or -i flag)
#   - AWS SSM Session Manager plugin installed (for NEW instance)
#   - sqlite3 installed on the old instance (usually pre-installed)
#
# Usage:
#   bash migrate-sqlite.sh <OLD_INSTANCE_IP> <S3_BUCKET> <NEW_INSTANCE_ID>
#
# Example:
#   bash migrate-sqlite.sh 13.209.1.2 my-bridge-backups i-0abc123def456789

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <OLD_INSTANCE_IP> <S3_BUCKET> <NEW_INSTANCE_ID>"
  echo ""
  echo "  OLD_INSTANCE_IP  Public or private IP of the old EC2 instance"
  echo "  S3_BUCKET        S3 bucket name (NOT s3:// prefix) for the transfer"
  echo "  NEW_INSTANCE_ID  EC2 instance ID of the new instance (for SSM)"
  exit 1
fi

OLD_INSTANCE_IP="$1"
S3_BUCKET="$2"
NEW_INSTANCE_ID="$3"

# ---------------------------------------------------------------------------
# Configuration — adjust paths to match your deployment
# ---------------------------------------------------------------------------
SSH_USER="ec2-user"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15"

# Directory containing SQLite files on the old instance
OLD_SQLITE_DIR="/data/sqlite"
# SQLite database filename(s) — space-separated if multiple files
SQLITE_FILES="bridge.db"

# Where dumps will land in S3
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
S3_PREFIX="sqlite-migration/${TIMESTAMP}"

# Paths on the new instance (accessed via SSM)
NEW_SQLITE_DIR="/data/sqlite"
NEW_TMP_DIR="/tmp/sqlite-restore-${TIMESTAMP}"

# SSM region (must match the new instance's region)
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

check_prerequisites() {
  log "Checking prerequisites..."
  command -v aws    >/dev/null 2>&1 || die "aws CLI not found"
  command -v ssh    >/dev/null 2>&1 || die "ssh not found"
  command -v gzip   >/dev/null 2>&1 || die "gzip not found"

  # Verify S3 bucket is accessible
  aws s3 ls "s3://${S3_BUCKET}" >/dev/null 2>&1 \
    || die "Cannot access S3 bucket s3://${S3_BUCKET} — check permissions"

  # Verify SSM connectivity to new instance
  log "Verifying SSM connectivity to ${NEW_INSTANCE_ID}..."
  aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${NEW_INSTANCE_ID}" \
    --region "${AWS_REGION}" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text | grep -q "Online" \
    || die "New instance ${NEW_INSTANCE_ID} is not reachable via SSM"

  log "Prerequisites OK."
}

# Run a command on the new instance via SSM and stream output
ssm_run() {
  local command="$1"
  local response
  response="$(aws ssm send-command \
    --instance-ids "${NEW_INSTANCE_ID}" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"${command}\"]" \
    --region "${AWS_REGION}" \
    --query 'Command.CommandId' \
    --output text)"

  local cmd_id="${response}"
  log "  SSM command ID: ${cmd_id}"

  # Wait for the command to complete (poll every 3 s, timeout after 5 min)
  local attempts=0
  while [[ $attempts -lt 100 ]]; do
    local status
    status="$(aws ssm get-command-invocation \
      --command-id "${cmd_id}" \
      --instance-id "${NEW_INSTANCE_ID}" \
      --region "${AWS_REGION}" \
      --query 'Status' \
      --output text 2>/dev/null || echo 'Pending')"

    if [[ "${status}" == "Success" ]]; then
      # Print stdout from the command
      aws ssm get-command-invocation \
        --command-id "${cmd_id}" \
        --instance-id "${NEW_INSTANCE_ID}" \
        --region "${AWS_REGION}" \
        --query 'StandardOutputContent' \
        --output text
      return 0
    elif [[ "${status}" == "Failed" || "${status}" == "TimedOut" || "${status}" == "Cancelled" ]]; then
      aws ssm get-command-invocation \
        --command-id "${cmd_id}" \
        --instance-id "${NEW_INSTANCE_ID}" \
        --region "${AWS_REGION}" \
        --query 'StandardErrorContent' \
        --output text >&2
      die "SSM command failed with status: ${status}"
    fi

    sleep 3
    (( attempts++ )) || true
  done

  die "SSM command timed out after waiting 5 minutes"
}

# ---------------------------------------------------------------------------
# Step 1 — Dump SQLite on the old instance via SSH
# ---------------------------------------------------------------------------
step1_dump_old_instance() {
  log "================================================================"
  log "STEP 1: Dumping SQLite databases on old instance (${OLD_INSTANCE_IP})"
  log "================================================================"

  for db_file in ${SQLITE_FILES}; do
    local src_path="${OLD_SQLITE_DIR}/${db_file}"
    local dump_name="${db_file%.db}.sql"
    local remote_dump="/tmp/${TIMESTAMP}-${dump_name}"
    local s3_key="${S3_PREFIX}/${dump_name}.gz"

    log "  Dumping ${src_path} -> ${remote_dump} ..."

    # Use sqlite3's .dump so we capture a consistent, text-format backup.
    # The WAL checkpoint flushes any pending write-ahead log entries first.
    ssh ${SSH_OPTS} "${SSH_USER}@${OLD_INSTANCE_IP}" bash -s << REMOTE_SCRIPT
set -euo pipefail
if [[ ! -f "${src_path}" ]]; then
  echo "WARNING: ${src_path} not found — skipping"
  exit 0
fi
echo "  WAL checkpoint..."
sqlite3 "${src_path}" "PRAGMA wal_checkpoint(FULL);"
echo "  Dumping SQL..."
sqlite3 "${src_path}" .dump > "${remote_dump}"
echo "  Rows in main table:"
sqlite3 "${src_path}" "SELECT COUNT(*) FROM sqlite_master WHERE type='table';" || true
echo "  Dump size: \$(du -sh ${remote_dump} | cut -f1)"
REMOTE_SCRIPT

    log "  Compressing and uploading ${dump_name} to s3://${S3_BUCKET}/${s3_key} ..."

    # Stream gzip + upload via pipe to avoid storing the dump on the operator machine
    ssh ${SSH_OPTS} "${SSH_USER}@${OLD_INSTANCE_IP}" \
      "gzip -c ${remote_dump}" \
      | aws s3 cp - "s3://${S3_BUCKET}/${s3_key}" \
          --region "${AWS_REGION}" \
          --content-encoding gzip

    # Verify the object was created in S3
    aws s3 ls "s3://${S3_BUCKET}/${s3_key}" >/dev/null 2>&1 \
      || die "S3 upload verification failed for ${s3_key}"

    log "  Uploaded: s3://${S3_BUCKET}/${s3_key}"

    # Clean up the remote dump file
    ssh ${SSH_OPTS} "${SSH_USER}@${OLD_INSTANCE_IP}" "rm -f ${remote_dump}"
  done

  log "STEP 1 complete — all dumps uploaded to s3://${S3_BUCKET}/${S3_PREFIX}/"
}

# ---------------------------------------------------------------------------
# Step 2 — Download dumps on new instance and restore
# ---------------------------------------------------------------------------
step2_restore_new_instance() {
  log "================================================================"
  log "STEP 2: Restoring SQLite databases on new instance (${NEW_INSTANCE_ID})"
  log "================================================================"

  for db_file in ${SQLITE_FILES}; do
    local dump_name="${db_file%.db}.sql"
    local s3_key="${S3_PREFIX}/${dump_name}.gz"
    local dest_path="${NEW_SQLITE_DIR}/${db_file}"

    log "  Restoring ${dump_name}.gz -> ${dest_path} ..."

    # Build a multi-line shell script and pass it as a single SSM command
    local restore_script
    restore_script="$(cat << SCRIPT
set -euo pipefail
mkdir -p ${NEW_SQLITE_DIR} ${NEW_TMP_DIR}

# Download compressed dump from S3
aws s3 cp s3://${S3_BUCKET}/${s3_key} ${NEW_TMP_DIR}/${dump_name}.gz \
  --region ${AWS_REGION}

# Decompress
gunzip -f ${NEW_TMP_DIR}/${dump_name}.gz

# Restore into a temporary database first, then atomic-rename
TMP_DB=${NEW_TMP_DIR}/${db_file}
sqlite3 \"\${TMP_DB}\" < ${NEW_TMP_DIR}/${dump_name}

# Verify the restored database is not corrupt
sqlite3 \"\${TMP_DB}\" 'PRAGMA integrity_check;' | grep -q 'ok' \
  || { echo 'Integrity check FAILED'; exit 1; }

# If destination already exists, back it up
if [[ -f ${dest_path} ]]; then
  cp ${dest_path} ${dest_path}.pre-migration-bak
  echo 'Existing DB backed up to ${dest_path}.pre-migration-bak'
fi

# Atomic rename into place
mv \"\${TMP_DB}\" ${dest_path}
chown ec2-user:ec2-user ${dest_path}

echo 'Restore complete for ${db_file}'
SCRIPT
)"

    ssm_run "${restore_script//[$'\n']/; }"

    log "  Restore of ${db_file} complete."
  done

  log "STEP 2 complete — databases restored on new instance."
}

# ---------------------------------------------------------------------------
# Step 3 — Verify restoration
# ---------------------------------------------------------------------------
step3_verify() {
  log "================================================================"
  log "STEP 3: Verifying restored databases on new instance"
  log "================================================================"

  for db_file in ${SQLITE_FILES}; do
    local dest_path="${NEW_SQLITE_DIR}/${db_file}"

    log "  Verifying ${dest_path} ..."

    local verify_script
    verify_script="$(cat << SCRIPT
set -euo pipefail
[[ -f ${dest_path} ]] || { echo 'MISSING: ${dest_path}'; exit 1; }
RESULT=\$(sqlite3 ${dest_path} 'PRAGMA integrity_check;')
echo \"Integrity check: \${RESULT}\"
echo \"File size: \$(du -sh ${dest_path} | cut -f1)\"
echo \"Tables:\"
sqlite3 ${dest_path} '.tables'
SCRIPT
)"

    ssm_run "${verify_script//[$'\n']/; }"
  done

  log "STEP 3 complete — verification passed."
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup_tmp() {
  log "Cleaning up temporary files on new instance..."
  ssm_run "rm -rf ${NEW_TMP_DIR}" || log "  (cleanup skipped — not critical)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  log "============================================================"
  log "NineChronicles ETH Bridge — SQLite Migration"
  log "  Old instance IP : ${OLD_INSTANCE_IP}"
  log "  S3 bucket       : ${S3_BUCKET}"
  log "  New instance ID : ${NEW_INSTANCE_ID}"
  log "  Timestamp       : ${TIMESTAMP}"
  log "============================================================"

  check_prerequisites
  step1_dump_old_instance
  step2_restore_new_instance
  step3_verify
  cleanup_tmp

  log "============================================================"
  log "Migration finished successfully!"
  log ""
  log "S3 dumps are retained at:"
  log "  s3://${S3_BUCKET}/${S3_PREFIX}/"
  log ""
  log "Next steps:"
  log "  1. Start the bridge on the new instance:"
  log "       aws ssm start-session --target ${NEW_INSTANCE_ID}"
  log "       sudo systemctl start ncg-eth-bridge"
  log "  2. Confirm it is syncing correctly via logs."
  log "  3. Update DNS / load balancer to point to the new instance."
  log "  4. Stop the old instance once confirmed stable."
  log "============================================================"
}

main "$@"

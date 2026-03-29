#!/usr/bin/env bash
# env.ssm.sh — Fetch bridge environment variables from AWS SSM Parameter Store
#
# All parameters stored under the /bridge/ path are fetched, decrypted, and
# written as KEY=VALUE pairs to /data/.env so the bridge container can read
# them at runtime.
#
# Usage:
#   sudo ./env.ssm.sh [SSM_PATH_PREFIX] [OUTPUT_FILE]
#
# Arguments (both optional):
#   SSM_PATH_PREFIX  — SSM path to scan recursively (default: /bridge/)
#   OUTPUT_FILE      — Destination file           (default: /data/.env)
#
# Prerequisites:
#   - AWS CLI v2 installed and on $PATH
#   - The EC2 instance profile (or local credentials) must have:
#       ssm:GetParametersByPath on arn:aws:ssm:<region>:<account>:parameter/bridge/*
#
# Typical invocations:
#   Initial bootstrap:
#     sudo /opt/bridge/env.ssm.sh
#
#   Key rotation (re-fetch and restart the service):
#     sudo /opt/bridge/env.ssm.sh && sudo systemctl restart ncg-eth-bridge
#
#   Custom path / output:
#     sudo ./env.ssm.sh /myapp/prod/ /opt/myapp/.env
#
# Parameter naming convention in SSM:
#   /bridge/NCG_MINTER_PRIVATE_KEY
#   /bridge/ETH_RPC_URL
#   /bridge/SLACK_WEBHOOK_URL
#   /bridge/NCG_RPC_ADDRESS
#   /bridge/S3_BUCKET
#   ...
#
# The parameter name after the last "/" becomes the environment variable key.
# For example:
#   /bridge/ETH_RPC_URL  ->  ETH_RPC_URL=https://...

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SSM_PATH="${1:-/bridge/}"
OUTPUT_FILE="${2:-/data/.env}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

# ---------------------------------------------------------------------------
# Validate AWS CLI availability
# ---------------------------------------------------------------------------
if ! command -v aws &>/dev/null; then
    log "ERROR: AWS CLI not found. Install it before running this script."
    exit 1
fi

# ---------------------------------------------------------------------------
# Ensure the output directory exists
# ---------------------------------------------------------------------------
OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"
if [[ ! -d "$OUTPUT_DIR" ]]; then
    log "Creating output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
fi

# ---------------------------------------------------------------------------
# Fetch parameters — paginate through all results
# ---------------------------------------------------------------------------
log "Fetching SSM parameters from path: $SSM_PATH"

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

NEXT_TOKEN=""
PARAM_COUNT=0

while true; do
    if [[ -n "$NEXT_TOKEN" ]]; then
        RESPONSE="$(aws ssm get-parameters-by-path \
            --path "$SSM_PATH" \
            --recursive \
            --with-decryption \
            --next-token "$NEXT_TOKEN" \
            --query 'Parameters[*].{Name:Name,Value:Value}' \
            --output json)"
    else
        RESPONSE="$(aws ssm get-parameters-by-path \
            --path "$SSM_PATH" \
            --recursive \
            --with-decryption \
            --query 'Parameters[*].{Name:Name,Value:Value}' \
            --output json)"
    fi

    # Parse and append KEY=VALUE pairs
    while IFS= read -r LINE; do
        NAME="$(echo "$LINE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Name'])")"
        VALUE="$(echo "$LINE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Value'])")"

        # Strip the path prefix to get the bare key name
        KEY="${NAME##*/}"

        if [[ -z "$KEY" ]]; then
            log "WARNING: Empty key derived from parameter name '$NAME' — skipping."
            continue
        fi

        # Escape any embedded newlines in the value (store as literal \n)
        ESCAPED_VALUE="${VALUE//$'\n'/\\n}"

        echo "${KEY}=${ESCAPED_VALUE}" >> "$TMP_FILE"
        PARAM_COUNT=$(( PARAM_COUNT + 1 ))
    done < <(echo "$RESPONSE" | python3 -c "
import sys, json
params = json.load(sys.stdin)
for p in params:
    import json as _j
    print(_j.dumps(p))
")

    # Check for NextToken to paginate
    NEXT_TOKEN="$(aws ssm get-parameters-by-path \
        --path "$SSM_PATH" \
        --recursive \
        --with-decryption \
        --query 'NextToken' \
        --output text 2>/dev/null || true)"

    if [[ "$NEXT_TOKEN" == "None" || -z "$NEXT_TOKEN" ]]; then
        break
    fi

    log "Paginating — fetching next page..."
done

log "Fetched $PARAM_COUNT parameter(s)."

if [[ "$PARAM_COUNT" -eq 0 ]]; then
    log "WARNING: No parameters found under '$SSM_PATH'. Verify the path and IAM permissions."
fi

# ---------------------------------------------------------------------------
# Atomically replace the output file
# ---------------------------------------------------------------------------
# Write to a temp file in the same directory so the move is atomic
DEST_TMP="$(dirname "$OUTPUT_FILE")/.env.tmp.$$"
cp "$TMP_FILE" "$DEST_TMP"

# Restrict permissions before moving into place (readable only by root)
chmod 600 "$DEST_TMP"

mv "$DEST_TMP" "$OUTPUT_FILE"

log "Environment file written to: $OUTPUT_FILE (mode 600)"
log "Done."

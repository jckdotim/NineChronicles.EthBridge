#!/usr/bin/env bash
# check-health.sh — Health check for the ncg-eth-bridge Docker container
#
# Usage:
#   ./check-health.sh
#
# Returns:
#   0  — All checks passed (healthy)
#   1  — One or more checks failed (unhealthy)
#
# Cron example (every 5 minutes, alert on failure):
#   */5 * * * * /opt/bridge/check-health.sh || \
#       aws sns publish --topic-arn "$SNS_TOPIC_ARN" \
#           --message "ncg-eth-bridge health check FAILED on $(hostname)"

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CONTAINER_NAME="ncg-eth-bridge"
DB_DIR="/data/sqlite"
DB_FILES=("bridge.db" "exchange_histories.db")

# Minimum uptime before we raise a "not running long enough" alarm (seconds)
MIN_UPTIME_SECONDS=300   # 5 minutes

# Maximum allowed age (seconds) for the last DB write before we consider
# the bridge stale
MAX_DB_AGE_SECONDS=1800  # 30 minutes

# ---------------------------------------------------------------------------
# State tracking
# ---------------------------------------------------------------------------
HEALTHY=0   # 0 = healthy so far; set to 1 on any failure

pass() { echo "  [PASS] $*"; }
fail() { echo "  [FAIL] $*"; HEALTHY=1; }
info() { echo "  [INFO] $*"; }

echo "========================================"
echo " NineChronicles.EthBridge Health Check"
echo " $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "========================================"

# ---------------------------------------------------------------------------
# 1. Container existence & running state
# ---------------------------------------------------------------------------
echo
echo "--- Container Status ---"

if ! docker inspect "$CONTAINER_NAME" &>/dev/null; then
    fail "Container '$CONTAINER_NAME' does not exist."
    # No point continuing — all remaining checks depend on the container
    echo
    echo "Result: UNHEALTHY (container missing)"
    exit 1
fi

CONTAINER_STATUS="$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)"
info "Container status: $CONTAINER_STATUS"

if [[ "$CONTAINER_STATUS" != "running" ]]; then
    fail "Container is not running (status: $CONTAINER_STATUS)."
else
    pass "Container is running."
fi

# ---------------------------------------------------------------------------
# 2. Uptime check — avoid false alarms during restart window
# ---------------------------------------------------------------------------
echo
echo "--- Uptime Check ---"

STARTED_AT="$(docker inspect --format '{{.State.StartedAt}}' "$CONTAINER_NAME" 2>/dev/null)"
info "Container started at: $STARTED_AT"

# Convert ISO-8601 start time to epoch seconds (GNU date)
START_EPOCH="$(date -u -d "$STARTED_AT" '+%s' 2>/dev/null \
    || date -u -j -f '%Y-%m-%dT%H:%M:%S' "${STARTED_AT%%.*}" '+%s' 2>/dev/null \
    || echo 0)"

NOW_EPOCH="$(date -u '+%s')"
UPTIME_SECONDS=$(( NOW_EPOCH - START_EPOCH ))

info "Uptime: ${UPTIME_SECONDS}s (threshold: ${MIN_UPTIME_SECONDS}s)"

if [[ "$UPTIME_SECONDS" -lt "$MIN_UPTIME_SECONDS" ]]; then
    info "Container started less than ${MIN_UPTIME_SECONDS}s ago — skipping further checks to avoid restart false-alarms."
    echo
    echo "Result: HEALTHY (container recently started, deferring full check)"
    exit 0
else
    pass "Container has been running for ${UPTIME_SECONDS}s."
fi

# ---------------------------------------------------------------------------
# 3. SQLite file existence and non-empty
# ---------------------------------------------------------------------------
echo
echo "--- SQLite File Checks ---"

for DB_NAME in "${DB_FILES[@]}"; do
    DB_PATH="$DB_DIR/$DB_NAME"

    if [[ ! -f "$DB_PATH" ]]; then
        fail "$DB_PATH does not exist."
        continue
    fi

    DB_SIZE="$(stat -c%s "$DB_PATH" 2>/dev/null || stat -f%z "$DB_PATH" 2>/dev/null || echo 0)"
    info "$DB_PATH size: ${DB_SIZE} bytes"

    if [[ "$DB_SIZE" -eq 0 ]]; then
        fail "$DB_PATH is empty (0 bytes)."
    else
        pass "$DB_PATH exists and is non-empty."
    fi
done

# ---------------------------------------------------------------------------
# 4. SQLite files recently modified (bridge is actively updating state)
# ---------------------------------------------------------------------------
echo
echo "--- SQLite Freshness Checks ---"

for DB_NAME in "${DB_FILES[@]}"; do
    DB_PATH="$DB_DIR/$DB_NAME"

    if [[ ! -f "$DB_PATH" ]]; then
        # Already reported above
        continue
    fi

    # Get modification time as epoch seconds
    MTIME_EPOCH="$(stat -c%Y "$DB_PATH" 2>/dev/null || stat -f%m "$DB_PATH" 2>/dev/null || echo 0)"
    DB_AGE_SECONDS=$(( NOW_EPOCH - MTIME_EPOCH ))
    info "$DB_NAME last modified ${DB_AGE_SECONDS}s ago (threshold: ${MAX_DB_AGE_SECONDS}s)"

    if [[ "$DB_AGE_SECONDS" -gt "$MAX_DB_AGE_SECONDS" ]]; then
        fail "$DB_NAME has not been modified in ${DB_AGE_SECONDS}s — bridge may be stalled."
    else
        pass "$DB_NAME was modified ${DB_AGE_SECONDS}s ago — bridge appears active."
    fi
done

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
echo
echo "========================================"
if [[ "$HEALTHY" -eq 0 ]]; then
    echo "Result: HEALTHY"
    echo "========================================"
    exit 0
else
    echo "Result: UNHEALTHY"
    echo "========================================"
    exit 1
fi

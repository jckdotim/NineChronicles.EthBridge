#!/bin/bash
# cloudwatch-alarm.sh
#
# Sets up CloudWatch alarms for the NineChronicles ETH Bridge EC2 instance:
#
#   1. EC2 Auto-Recovery alarm
#      Triggers ec2:recover when the system status check fails for 2 consecutive
#      minutes.  Auto-recovery restarts the instance on a new host while
#      preserving the instance ID, EIP, and EBS volumes — zero manual
#      intervention required.
#
#   2. Memory usage alarm (high threshold: 80%)
#      A t4g.nano has only 512 MB of RAM.  The CloudWatch agent publishes the
#      'mem_used_percent' custom metric; this alarm fires when memory stays
#      above 80% for 5 minutes and notifies via SNS so you can scale up before
#      the process starts swap-thrashing.
#
#   3. Disk usage alarm (high threshold: 85%)
#      Alerts when the root volume or /data is more than 85% full.
#
# Prerequisites:
#   - AWS CLI configured with cloudwatch:PutMetricAlarm, ec2:DescribeInstances
#   - SNS topic must already exist (or update SNS_TOPIC_ARN to a real ARN)
#   - For alarms 2 & 3: CloudWatch Agent must be installed and running on the
#     instance (install via: dnf install -y amazon-cloudwatch-agent)
#
# Usage:
#   INSTANCE_ID=i-0abc123 bash cloudwatch-alarm.sh
#   # Or pass as positional argument:
#   bash cloudwatch-alarm.sh i-0abc123

set -euo pipefail

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
INSTANCE_ID="${1:-${INSTANCE_ID:-}}"
REGION="${AWS_REGION:-ap-northeast-2}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# SNS topic ARN for notifications — replace with your actual ARN
SNS_TOPIC_ARN="${SNS_TOPIC_ARN:-arn:aws:sns:${REGION}:${ACCOUNT_ID}:ncg-eth-bridge-alerts}"

# Memory alarm threshold (percent)
MEMORY_THRESHOLD=80

# Disk alarm threshold (percent)
DISK_THRESHOLD=85

# Alarm name prefix
ALARM_PREFIX="ncg-eth-bridge"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
[[ -z "${INSTANCE_ID}" ]] && {
  echo "Usage: $0 <INSTANCE_ID>"
  echo "  or set INSTANCE_ID env var"
  exit 1
}

# Validate the instance exists
aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${REGION}" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text >/dev/null \
  || { echo "ERROR: Instance ${INSTANCE_ID} not found in ${REGION}"; exit 1; }

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ---------------------------------------------------------------------------
# Helper: create / overwrite an alarm and print a one-liner summary
# ---------------------------------------------------------------------------
put_alarm() {
  local name="$1"
  shift
  aws cloudwatch put-metric-alarm --alarm-name "${name}" "$@" --region "${REGION}"
  log "  OK: ${name}"
}

# ---------------------------------------------------------------------------
# Alarm 1 — EC2 Auto-Recovery
#
# Metric  : StatusCheckFailed_System (built-in, no agent needed)
# Period  : 60 s
# Evaluate: 2 consecutive periods  -> triggers after 2 minutes of failure
# Action  : ec2:recover  (re-launch on healthy hardware, preserving instance ID)
# ---------------------------------------------------------------------------
log "Creating EC2 auto-recovery alarm..."

put_alarm "${ALARM_PREFIX}-auto-recovery" \
  --alarm-description "Auto-recover ${INSTANCE_ID} when system status check fails for 2 minutes" \
  --namespace "AWS/EC2" \
  --metric-name "StatusCheckFailed_System" \
  --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
  --statistic "Maximum" \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 1 \
  --comparison-operator "GreaterThanOrEqualToThreshold" \
  --treat-missing-data "notBreaching" \
  --alarm-actions \
    "arn:aws:automate:${REGION}:ec2:recover" \
    "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}"

# ---------------------------------------------------------------------------
# Alarm 2 — Memory Usage (via CloudWatch Agent custom metric)
#
# The CloudWatch Agent on the instance must be configured to publish
# CWAgent/mem_used_percent.  Minimal agent config (save to
# /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json):
#
# {
#   "metrics": {
#     "append_dimensions": { "InstanceId": "${aws:InstanceId}" },
#     "metrics_collected": {
#       "mem": { "measurement": ["mem_used_percent"], "metrics_collection_interval": 60 }
#     }
#   }
# }
#
# Then start: amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:...
# ---------------------------------------------------------------------------
log "Creating memory usage alarm (>${MEMORY_THRESHOLD}%)..."

put_alarm "${ALARM_PREFIX}-memory-high" \
  --alarm-description "Bridge instance memory > ${MEMORY_THRESHOLD}% for 5 minutes on ${INSTANCE_ID}" \
  --namespace "CWAgent" \
  --metric-name "mem_used_percent" \
  --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
  --statistic "Average" \
  --period 60 \
  --evaluation-periods 5 \
  --threshold "${MEMORY_THRESHOLD}" \
  --comparison-operator "GreaterThanThreshold" \
  --treat-missing-data "notBreaching" \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}"

# ---------------------------------------------------------------------------
# Alarm 3 — Disk Usage on /data (SQLite storage)
#
# The CloudWatch Agent must also collect disk metrics:
#   "disk": {
#     "measurement": ["used_percent"],
#     "metrics_collection_interval": 60,
#     "resources": ["/", "/data"]
#   }
# ---------------------------------------------------------------------------
log "Creating disk usage alarm for /data (>${DISK_THRESHOLD}%)..."

put_alarm "${ALARM_PREFIX}-disk-data-high" \
  --alarm-description "Bridge /data disk > ${DISK_THRESHOLD}% on ${INSTANCE_ID}" \
  --namespace "CWAgent" \
  --metric-name "disk_used_percent" \
  --dimensions \
    "Name=InstanceId,Value=${INSTANCE_ID}" \
    "Name=path,Value=/data" \
    "Name=fstype,Value=xfs" \
  --statistic "Maximum" \
  --period 300 \
  --evaluation-periods 2 \
  --threshold "${DISK_THRESHOLD}" \
  --comparison-operator "GreaterThanThreshold" \
  --treat-missing-data "notBreaching" \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}"

# ---------------------------------------------------------------------------
# Alarm 4 — Instance CPU credit balance (t4g.nano is burstable)
#
# t4g.nano earns 6 CPU credits/hour at baseline 5% CPU.
# Warn when the credit balance drops below 10 (< ~100 minutes of burst left).
# ---------------------------------------------------------------------------
log "Creating CPU credit balance alarm (<10 credits)..."

put_alarm "${ALARM_PREFIX}-cpu-credit-low" \
  --alarm-description "Bridge t4g.nano CPU credit balance < 10 on ${INSTANCE_ID}" \
  --namespace "AWS/EC2" \
  --metric-name "CPUCreditBalance" \
  --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
  --statistic "Minimum" \
  --period 300 \
  --evaluation-periods 3 \
  --threshold 10 \
  --comparison-operator "LessThanThreshold" \
  --treat-missing-data "notBreaching" \
  --alarm-actions "${SNS_TOPIC_ARN}" \
  --ok-actions "${SNS_TOPIC_ARN}"

# ---------------------------------------------------------------------------
# Print summary of created alarms
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  CloudWatch alarms created for ${INSTANCE_ID}:"
echo ""
aws cloudwatch describe-alarms \
  --alarm-name-prefix "${ALARM_PREFIX}" \
  --region "${REGION}" \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue}' \
  --output table
echo ""
echo "  SNS notifications -> ${SNS_TOPIC_ARN}"
echo ""
echo "  IMPORTANT: If the SNS topic does not exist yet, create it:"
echo "    aws sns create-topic --name ncg-eth-bridge-alerts --region ${REGION}"
echo "    aws sns subscribe --topic-arn ${SNS_TOPIC_ARN} \\"
echo "      --protocol email --notification-endpoint your@email.com \\"
echo "      --region ${REGION}"
echo ""
echo "  For memory/disk alarms to work, ensure the CloudWatch Agent is"
echo "  installed and configured on the instance:"
echo "    sudo dnf install -y amazon-cloudwatch-agent"
echo "    # Then configure and start it (see comment in this script)"
echo "============================================================"

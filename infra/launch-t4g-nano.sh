#!/bin/bash
# launch-t4g-nano.sh
#
# Launches a new Amazon Linux 2023 ARM64 t4g.nano EC2 instance for the
# NineChronicles ETH Bridge.
#
# Cost profile (ap-northeast-2, on-demand, 2025):
#   t4g.nano  ~$0.0052/hr  ~$3.78/month
#   8 GB gp3 EBS           ~$0.64/month
#   Data transfer / misc   ~$7-8/month
#   Total estimate         ~$12/month   (vs ~$612/month on previous setup)
#
# Prerequisites:
#   - AWS CLI configured with ec2:RunInstances, ec2:CreateSecurityGroup,
#     ec2:AuthorizeSecurityGroupEgress / Ingress, iam:PassRole permissions
#   - The IAM role "bridge-ec2-role" must already exist (see create-iam-role.sh)
#   - setup-instance.sh must be accessible at the path specified by SETUP_SCRIPT
#
# Usage:
#   VPC_ID=vpc-xxxx SUBNET_ID=subnet-xxxx ECR_IMAGE=<uri> bash launch-t4g-nano.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Variables — required
# ---------------------------------------------------------------------------
VPC_ID="${VPC_ID:-}"          # Target VPC (must be set)
SUBNET_ID="${SUBNET_ID:-}"    # Target PUBLIC subnet (퍼블릭 서브넷 필수 — NAT Gateway 제거의 핵심)
ECR_IMAGE="${ECR_IMAGE:-}"    # Full ECR image URI with tag

# ---------------------------------------------------------------------------
# Variables — optional / with sensible defaults
# ---------------------------------------------------------------------------
REGION="${AWS_REGION:-ap-northeast-2}"
INSTANCE_TYPE="t4g.nano"
IAM_INSTANCE_PROFILE="bridge-ec2-role"
KEY_NAME="${KEY_NAME:-}"      # SSH key pair name; leave blank for SSM-only access

# Amazon Linux 2023 ARM64 (aarch64) — latest AMI in ap-northeast-2.
# To find the current AMI ID:
#   aws ec2 describe-images \
#     --owners amazon \
#     --filters 'Name=name,Values=al2023-ami-*-arm64' \
#               'Name=state,Values=available' \
#     --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
#     --output text \
#     --region ap-northeast-2
AMI_ID="${AMI_ID:-ami-0b7a8b7a8b7a8b7a8}"   # <-- Replace with current AMI

EBS_SIZE_GB=8
EBS_TYPE="gp3"

# Resource names / tags
INSTANCE_NAME="ncg-eth-bridge"
PROJECT_TAG="NineChronicles.EthBridge"

# Path to setup-instance.sh on this machine (will be embedded in User Data)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/setup-instance.sh"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
[[ -z "${VPC_ID}"    ]] && { echo "ERROR: VPC_ID is not set."    ; exit 1; }
[[ -z "${SUBNET_ID}" ]] && { echo "ERROR: SUBNET_ID is not set." ; exit 1; }
[[ -z "${ECR_IMAGE}" ]] && { echo "ERROR: ECR_IMAGE is not set."  ; exit 1; }
[[ -f "${SETUP_SCRIPT}" ]] || { echo "ERROR: ${SETUP_SCRIPT} not found."; exit 1; }

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ---------------------------------------------------------------------------
# Step 1 — Create outbound-only security group
#   No inbound rules are added (access is via SSM only).
#   Outbound: HTTPS (443) for ECR, S3, SSM, and CloudWatch; nothing else.
# ---------------------------------------------------------------------------
log "Creating security group (outbound-only, SSM access)..."

SG_ID="$(aws ec2 create-security-group \
  --group-name "${INSTANCE_NAME}-sg" \
  --description "Outbound-only SG for ${INSTANCE_NAME}; inbound via SSM only" \
  --vpc-id "${VPC_ID}" \
  --region "${REGION}" \
  --tag-specifications \
    "ResourceType=security-group,Tags=[{Key=Name,Value=${INSTANCE_NAME}-sg},{Key=Project,Value=${PROJECT_TAG}}]" \
  --query 'GroupId' \
  --output text)"

log "  Security group created: ${SG_ID}"

# Remove the default all-traffic egress rule that AWS adds automatically
aws ec2 revoke-security-group-egress \
  --group-id "${SG_ID}" \
  --region "${REGION}" \
  --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' \
  2>/dev/null || true   # May already have been removed; ignore error

# Allow outbound HTTPS only (ECR pull, SSM, CloudWatch, S3, KMS)
aws ec2 authorize-security-group-egress \
  --group-id "${SG_ID}" \
  --region "${REGION}" \
  --ip-permissions \
    '[{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"0.0.0.0/0","Description":"HTTPS for AWS APIs and ECR"}]}]'

log "  Outbound HTTPS rule added."

# ---------------------------------------------------------------------------
# Step 2 — Build User Data script
#   Embeds setup-instance.sh inline so the instance bootstraps itself on
#   first boot without needing an external download.
# ---------------------------------------------------------------------------
log "Building User Data..."

USERDATA="$(cat << USERDATA_EOF
#!/bin/bash
set -euo pipefail
# ---- Embedded setup-instance.sh ----
export ECR_IMAGE="${ECR_IMAGE}"
$(cat "${SETUP_SCRIPT}")
# ---- End of embedded script ----
USERDATA_EOF
)"

# Base64-encode the User Data for the AWS CLI
USERDATA_B64="$(echo "${USERDATA}" | base64)"

# ---------------------------------------------------------------------------
# Step 3 — Launch the EC2 instance
# ---------------------------------------------------------------------------
log "Launching t4g.nano instance..."

# Build optional key-pair argument
KEY_ARG=""
if [[ -n "${KEY_NAME}" ]]; then
  KEY_ARG="--key-name ${KEY_NAME}"
fi

INSTANCE_ID="$(aws ec2 run-instances \
  --region "${REGION}" \
  --image-id "${AMI_ID}" \
  --instance-type "${INSTANCE_TYPE}" \
  --subnet-id "${SUBNET_ID}" \
  --associate-public-ip-address \
  --security-group-ids "${SG_ID}" \
  --iam-instance-profile Name="${IAM_INSTANCE_PROFILE}" \
  --user-data "${USERDATA_B64}" \
  --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1" \
  --block-device-mappings \
    "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${EBS_SIZE_GB},\"VolumeType\":\"${EBS_TYPE}\",\"DeleteOnTermination\":true,\"Encrypted\":true}}]" \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=${PROJECT_TAG}}]" \
    "ResourceType=volume,Tags=[{Key=Name,Value=${INSTANCE_NAME}-root},{Key=Project,Value=${PROJECT_TAG}}]" \
  ${KEY_ARG} \
  --query 'Instances[0].InstanceId' \
  --output text)"

log "  Instance launched: ${INSTANCE_ID}"

# ---------------------------------------------------------------------------
# Step 4 — Wait for the instance to reach the "running" state
# ---------------------------------------------------------------------------
log "Waiting for instance to enter 'running' state..."
aws ec2 wait instance-running \
  --instance-ids "${INSTANCE_ID}" \
  --region "${REGION}"
log "  Instance is running."

# ---------------------------------------------------------------------------
# Step 5 — Print summary
# ---------------------------------------------------------------------------
INSTANCE_INFO="$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region "${REGION}" \
  --query 'Reservations[0].Instances[0].{PrivateIP:PrivateIpAddress,AZ:Placement.AvailabilityZone}' \
  --output json)"

PRIVATE_IP="$(echo "${INSTANCE_INFO}" | python3 -c "import sys,json; print(json.load(sys.stdin)['PrivateIP'])")"
AZ="$(echo "${INSTANCE_INFO}"        | python3 -c "import sys,json; print(json.load(sys.stdin)['AZ'])")"

echo ""
echo "============================================================"
echo "  t4g.nano instance launched!"
echo ""
echo "  Instance ID : ${INSTANCE_ID}"
echo "  Private IP  : ${PRIVATE_IP}"
echo "  AZ          : ${AZ}"
echo "  Region      : ${REGION}"
echo ""
echo "  Connect (no SSH needed — use SSM):"
echo "    aws ssm start-session --target ${INSTANCE_ID} --region ${REGION}"
echo ""
echo "  Monitor bootstrap progress:"
echo "    aws ssm start-session --target ${INSTANCE_ID} --region ${REGION}"
echo "    sudo tail -f /var/log/cloud-init-output.log"
echo ""
echo "  Set up alarms next:"
echo "    bash ${SCRIPT_DIR}/cloudwatch-alarm.sh ${INSTANCE_ID}"
echo "============================================================"

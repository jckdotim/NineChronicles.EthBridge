#!/bin/bash
# create-iam-role.sh
#
# Creates the EC2 IAM instance profile for the NineChronicles ETH Bridge
# with the minimum required permissions (principle of least privilege).
#
# Permissions granted:
#   KMS        — Sign, GetPublicKey, DescribeKey on bridge signer keys
#   SSM Params — GetParameter / GetParameters for /bridge/* namespace
#   ECR        — Pull images from ECR
#   S3         — Read/write objects in the bridge-backups bucket
#   CloudWatch — Publish custom metrics and write logs
#
# Usage:
#   bash create-iam-role.sh
#
# To re-run after updating policy content, set UPDATE=true:
#   UPDATE=true bash create-iam-role.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Variables — update these to match your environment
# ---------------------------------------------------------------------------
ROLE_NAME="bridge-ec2-role"
INSTANCE_PROFILE_NAME="bridge-ec2-role"   # Must match IAM_INSTANCE_PROFILE in launch-t4g-nano.sh
POLICY_NAME="bridge-ec2-policy"
REGION="${AWS_REGION:-ap-northeast-2}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

# KMS key ARNs used by the bridge signer — replace placeholders before running
KMS_KEY_ARN_1="arn:aws:kms:${REGION}:${ACCOUNT_ID}:key/REPLACE-WITH-ACTUAL-KEY-ID-1"
KMS_KEY_ARN_2="arn:aws:kms:${REGION}:${ACCOUNT_ID}:key/REPLACE-WITH-ACTUAL-KEY-ID-2"

# S3 bucket for bridge backups (created separately)
BACKUP_BUCKET="bridge-backups-${ACCOUNT_ID}"

# SSM parameter path prefix (all bridge secrets live under this path)
SSM_PATH_PREFIX="arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter/bridge/*"

# ECR repository ARN for the bridge image
ECR_REPO_ARN="arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/ncg-eth-bridge"

# CloudWatch log group
CW_LOG_GROUP_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/ncg-eth-bridge:*"

UPDATE="${UPDATE:-false}"   # Set to "true" to update an existing role/policy

# ---------------------------------------------------------------------------
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ---------------------------------------------------------------------------
# Step 1 — Trust policy: allows EC2 to assume this role
# ---------------------------------------------------------------------------
TRUST_POLICY="$(cat << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)"

# ---------------------------------------------------------------------------
# Step 2 — Inline permission policy
# ---------------------------------------------------------------------------
INLINE_POLICY="$(cat << EOF
{
  "Version": "2012-10-17",
  "Statement": [

    {
      "Sid": "KmsSignerOperations",
      "Effect": "Allow",
      "Action": [
        "kms:Sign",
        "kms:GetPublicKey",
        "kms:DescribeKey"
      ],
      "Resource": [
        "${KMS_KEY_ARN_1}",
        "${KMS_KEY_ARN_2}"
      ],
      "Condition": {
        "StringEquals": {
          "kms:CallerAccount": "${ACCOUNT_ID}"
        }
      }
    },

    {
      "Sid": "SsmParameterRead",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": "${SSM_PATH_PREFIX}"
    },

    {
      "Sid": "EcrImagePull",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EcrImagePullRepo",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "${ECR_REPO_ARN}"
    },

    {
      "Sid": "S3BackupReadWrite",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${BACKUP_BUCKET}",
        "arn:aws:s3:::${BACKUP_BUCKET}/*"
      ]
    },

    {
      "Sid": "CloudWatchMetrics",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricData"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "cloudwatch:namespace": "NineChronicles/EthBridge"
        }
      }
    },

    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": [
        "${CW_LOG_GROUP_ARN}",
        "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/ncg-eth-bridge"
      ]
    },

    {
      "Sid": "SsmSessionManagerCore",
      "Effect": "Allow",
      "Action": [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
        "ssm:UpdateInstanceInformation"
      ],
      "Resource": "*"
    }

  ]
}
EOF
)"

# ---------------------------------------------------------------------------
# Step 3 — Create or update the IAM role
# ---------------------------------------------------------------------------
log "Account ID : ${ACCOUNT_ID}"
log "Region     : ${REGION}"
log ""

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  if [[ "${UPDATE}" == "true" ]]; then
    log "Role '${ROLE_NAME}' already exists — updating trust policy..."
    aws iam update-assume-role-policy \
      --role-name "${ROLE_NAME}" \
      --policy-document "${TRUST_POLICY}"
  else
    log "Role '${ROLE_NAME}' already exists. Set UPDATE=true to update it."
  fi
else
  log "Creating IAM role '${ROLE_NAME}'..."
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "EC2 role for NineChronicles ETH Bridge (t4g.nano)" \
    --tags Key=Project,Value=NineChronicles.EthBridge
  log "  Role created."
fi

# ---------------------------------------------------------------------------
# Step 4 — Attach SSM managed policy (needed for SSM Session Manager)
# ---------------------------------------------------------------------------
log "Attaching AmazonSSMManagedInstanceCore managed policy..."
aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
  2>/dev/null || log "  (already attached)"

# ---------------------------------------------------------------------------
# Step 5 — Put or update inline permission policy
# ---------------------------------------------------------------------------
log "Putting inline policy '${POLICY_NAME}'..."
aws iam put-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-name "${POLICY_NAME}" \
  --policy-document "${INLINE_POLICY}"
log "  Inline policy applied."

# ---------------------------------------------------------------------------
# Step 6 — Create instance profile and attach role
# ---------------------------------------------------------------------------
if aws iam get-instance-profile --instance-profile-name "${INSTANCE_PROFILE_NAME}" >/dev/null 2>&1; then
  log "Instance profile '${INSTANCE_PROFILE_NAME}' already exists — skipping creation."
else
  log "Creating instance profile '${INSTANCE_PROFILE_NAME}'..."
  aws iam create-instance-profile \
    --instance-profile-name "${INSTANCE_PROFILE_NAME}"
  log "  Instance profile created."

  log "Attaching role to instance profile..."
  aws iam add-role-to-instance-profile \
    --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
    --role-name "${ROLE_NAME}"
  log "  Role attached."
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)"

echo ""
echo "============================================================"
echo "  IAM role ready!"
echo ""
echo "  Role name    : ${ROLE_NAME}"
echo "  Role ARN     : ${ROLE_ARN}"
echo "  Profile name : ${INSTANCE_PROFILE_NAME}"
echo ""
echo "  IMPORTANT: Before using this role, update the placeholder"
echo "  KMS key ARNs in this script:"
echo "    KMS_KEY_ARN_1: ${KMS_KEY_ARN_1}"
echo "    KMS_KEY_ARN_2: ${KMS_KEY_ARN_2}"
echo ""
echo "  Then re-run with UPDATE=true to apply the corrected policy."
echo "============================================================"

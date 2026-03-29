#!/bin/bash
# setup-instance.sh
#
# Configures a fresh Amazon Linux 2023 ARM64 (t4g.nano) EC2 instance for
# running the NineChronicles ETH Bridge Docker container.
#
# Usage:
#   ECR_IMAGE=<your-ecr-image-uri> bash setup-instance.sh
#
# This script is designed to be run as EC2 User Data or manually via SSH.
# It is idempotent — safe to run more than once.

set -euo pipefail

# ---------------------------------------------------------------------------
# Variables — set ECR_IMAGE before running, or pass it as an env var
# ---------------------------------------------------------------------------
CONTAINER_NAME="ncg-eth-bridge"
DATA_DIR="/data"
ENV_FILE="${DATA_DIR}/.env"
SQLITE_DIR="${DATA_DIR}/sqlite"
ECR_IMAGE="${ECR_IMAGE:-}"  # e.g. 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ncg-eth-bridge:latest
SERVICE_FILE="/etc/systemd/system/${CONTAINER_NAME}.service"

# ---------------------------------------------------------------------------
# Sanity check
# ---------------------------------------------------------------------------
if [[ -z "${ECR_IMAGE}" ]]; then
  echo "ERROR: ECR_IMAGE is not set. Export it before running this script."
  echo "  export ECR_IMAGE=<ecr-image-uri>"
  exit 1
fi

echo "==> [1/6] Updating system packages..."
dnf update -y

# ---------------------------------------------------------------------------
# Install Docker (Amazon Linux 2023 ships 'docker' in the default repos)
# ---------------------------------------------------------------------------
echo "==> [2/6] Installing Docker..."
dnf install -y docker

# Enable and start Docker daemon
systemctl enable docker
systemctl start docker

# Allow ec2-user to run Docker commands without sudo
usermod -aG docker ec2-user

echo "    Docker version: $(docker --version)"

# ---------------------------------------------------------------------------
# Install AWS CLI v2 (ARM64 / aarch64 build)
# ---------------------------------------------------------------------------
echo "==> [3/6] Installing AWS CLI v2 (ARM64)..."
AWSCLI_TMP="$(mktemp -d)"
curl -fsSL \
  "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" \
  -o "${AWSCLI_TMP}/awscliv2.zip"

# Verify the download is a valid zip before unpacking
file "${AWSCLI_TMP}/awscliv2.zip" | grep -q "Zip archive" || {
  echo "ERROR: AWS CLI download appears corrupted."
  exit 1
}

cd "${AWSCLI_TMP}"
unzip -q awscliv2.zip
./aws/install --update
cd -
rm -rf "${AWSCLI_TMP}"

echo "    AWS CLI version: $(aws --version)"

# ---------------------------------------------------------------------------
# Create persistent data directory for SQLite and environment variables
# ---------------------------------------------------------------------------
echo "==> [4/6] Creating data directories..."

# /data persists across container restarts; mount it on a separate EBS volume
# if you need crash-safe storage (see launch-t4g-nano.sh).
mkdir -p "${SQLITE_DIR}"
chown -R ec2-user:ec2-user "${DATA_DIR}"

# Create a placeholder .env file if it does not already exist.
# The real secrets should be pushed here before starting the service —
# e.g. via AWS Systems Manager Parameter Store + a bootstrap script,
# or by copying a pre-populated file from S3.
if [[ ! -f "${ENV_FILE}" ]]; then
  cat > "${ENV_FILE}" << 'EOF'
# NineChronicles ETH Bridge — runtime environment variables
# 실제 값으로 채운 후 서비스를 시작하세요.
# SSM Parameter Store를 사용하는 경우 env.ssm.sh를 실행하면 자동으로 채워집니다.

GRAPHQL_API_ENDPOINT=
STAGE_HEADLESSES=
WNCG_CONTRACT_ADDRESS=
MONITOR_STATE_STORE_PATH=/data/bridge.db
EXCHANGE_HISTORY_STORE_PATH=/data/exchange_histories.db
MAXIMUM_NCG=100000
MINIMUM_NCG=100
EXPLORER_ROOT_URL=
NCSCAN_URL=
USE_NCSCAN_URL=FALSE
ETHERSCAN_ROOT_URL=
KMS_PROVIDER_URL=
KMS_PROVIDER_KEY_ID=
KMS_PROVIDER_ENDPOINT=
KMS_PROVIDER_REGION=
KMS_PROVIDER_AWS_ACCESSKEY=
KMS_PROVIDER_AWS_SECRETKEY=
KMS_PROVIDER_PUBLIC_KEY=
NCG_MINTER=
PRIORITY_FEE=
GAS_TIP_RATIO=0.1
MAX_GAS_PRICE=300
PAGERDUTY_ROUTING_KEY=
OPENSEARCH_ENDPOINT=
OPENSEARCH_AUTH=
OPENSEARCH_INDEX=
SLACK_CHANNEL_NAME=
SLACK_URL=
ZERO_EXCHANGE_FEE_RATIO_ADDRESSES=
USE_SAFE_WRAPPED_NCG_MINTER=FALSE
FEE_RANGE1_RATIO=
FEE_RANGE2_RATIO=
FEE_RANGE_DIVIDER_AMOUNT=
PLANET_ODIN_ID=
PLANET_HEIMDALL_ID=
ODIN_TO_HEIMDALL_VALUT_ADDRESS=
FEE_KMS_REGION=
FEE_KMS_KEY_ID=
FEE_KMS_AWS_ACCESSKEY=
FEE_KMS_AWS_SECRETKEY=
FEE_COLLECTOR_ADDRESS=
BRIDGE_ADDRESS=
USE_GOOGLE_SPREAD_SHEET=FALSE
GOOGLE_SPREADSHEET_ID=
GOOGLE_CLIENT_EMAIL=
GOOGLE_CLIENT_PRIVATE_KEY=
SHEET_MINT=
SHEET_BURN=
EOF
  chmod 600 "${ENV_FILE}"
  echo "    Created placeholder ${ENV_FILE} — 실제 값으로 채운 후 서비스를 시작하세요."
fi

# ---------------------------------------------------------------------------
# Pull the bridge image from ECR so the systemd service can start immediately
# ---------------------------------------------------------------------------
echo "==> [5/6] Authenticating to ECR and pulling image..."

# Derive the ECR registry URL from the image URI (everything before the first /)
ECR_REGISTRY="$(echo "${ECR_IMAGE}" | cut -d'/' -f1)"
REGION="$(echo "${ECR_REGISTRY}" | grep -oP '(?<=\.ecr\.)[^.]+(?=\.amazonaws)')"

aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

docker pull "${ECR_IMAGE}"

echo "    Image pulled: ${ECR_IMAGE}"

# ---------------------------------------------------------------------------
# Install systemd service so the container auto-restarts on crash or reboot
# ---------------------------------------------------------------------------
echo "==> [6/6] Installing systemd service (${CONTAINER_NAME})..."

cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=NineChronicles ETH Bridge Docker Container
Documentation=https://github.com/planetarium/NineChronicles.EthBridge
# Wait until Docker is fully up before trying to start the container
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10

# Pull the latest image on each start so deployments are automatic.
# Remove the ExecStartPre line if you prefer manual deploys.
ExecStartPre=/bin/sh -c 'aws ecr get-login-password --region ${REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY}'
ExecStartPre=-/usr/bin/docker stop ${CONTAINER_NAME}
ExecStartPre=-/usr/bin/docker rm   ${CONTAINER_NAME}
ExecStartPre=/usr/bin/docker pull  ${ECR_IMAGE}

ExecStart=/usr/bin/docker run --rm \\
  --name ${CONTAINER_NAME} \\
  --env-file ${ENV_FILE} \\
  --mount type=bind,source=${SQLITE_DIR},target=/data \\
  --log-driver=awslogs \\
  --log-opt awslogs-region=${REGION} \\
  --log-opt awslogs-group=/ncg-eth-bridge \\
  --log-opt awslogs-create-group=true \\
  --restart no \\
  ${ECR_IMAGE}

ExecStop=/usr/bin/docker stop ${CONTAINER_NAME}

# Give the container 30 s to shut down gracefully before SIGKILL
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${CONTAINER_NAME}.service"

echo ""
echo "============================================================"
echo "  Setup complete!"
echo ""
echo "  Next steps:"
echo "  1. Edit ${ENV_FILE} and fill in real secrets."
echo "  2. Start the bridge:  systemctl start ${CONTAINER_NAME}"
echo "  3. Check status:      systemctl status ${CONTAINER_NAME}"
echo "  4. Follow logs:       journalctl -fu ${CONTAINER_NAME}"
echo "============================================================"

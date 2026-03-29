#!/bin/bash
# downsize-ec2.sh
#
# us-east-2 EC2 인스턴스를 m6i.large/t2.medium에서 t3.small로 다운사이징합니다.
#
# 현황:
#   - eth-bridge (i-0cfd55f8a88bb4c0c):     m6i.large → t3.small  절감 $54/월
#   - bsc-bridge (i-01f3117bf4b28e0b3):     m6i.large → t3.small  절감 $54/월
#   - operation-instance (i-087262278ac573137): t2.medium → t3.small 절감 $18/월
#   - bsc-bridge-operation (i-0e3fc72f85be6a0d2): t2.medium → t3.small 절감 $18/월
#
# ⚠️  주의사항:
#   - 인스턴스 타입 변경은 재시작(stop/start)이 필요합니다 (~2-5분 다운타임)
#   - 인스턴스 재시작 시 Public IP가 변경될 수 있습니다 (Elastic IP 미사용 시)
#   - t2.medium은 x86이고, t3는 더 빠른 세대이므로 호환성 문제 없음
#   - m6i.large EBS root 볼륨은 그대로 유지됨 (데이터 손실 없음)
#
# 사용법:
#   DRY_RUN=true  bash downsize-ec2.sh              # 시뮬레이션
#   DRY_RUN=false TARGET=eth-bridge bash downsize-ec2.sh   # eth-bridge만
#   DRY_RUN=false bash downsize-ec2.sh              # 전체 실행

set -euo pipefail

AWS="${AWS_CLI:-aws}"
REGION="us-east-2"
DRY_RUN="${DRY_RUN:-true}"
TARGET="${TARGET:-all}"  # all | eth-bridge | bsc-bridge | operation-instance | bsc-bridge-operation

TARGET_INSTANCE_TYPE="t3.small"  # 2 vCPU, 2GB RAM, $0.0208/hr = $15.18/월

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
info() { echo "  ℹ $*"; }
warn() { echo "  ⚠ $*"; }
ok()   { echo "  ✓ $*"; }
skip() { echo "  ↷ [DRY_RUN] $*"; }

resize_instance() {
  local name="$1"
  local instance_id="$2"
  local current_type="$3"

  echo ""
  log "[$name] $instance_id: $current_type → $TARGET_INSTANCE_TYPE"

  if [[ "$DRY_RUN" == "true" ]]; then
    skip "stop → modify → start: $instance_id"
    return
  fi

  # 1. 현재 상태 재확인
  state=$($AWS ec2 describe-instances --region "$REGION" \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text)

  if [[ "$state" != "running" ]]; then
    warn "$name 상태가 $state — running이 아니면 진행 불가"
    return
  fi

  # 2. 인스턴스 중지
  log "  [$name] 중지 중..."
  $AWS ec2 stop-instances --region "$REGION" --instance-ids "$instance_id" > /dev/null
  $AWS ec2 wait instance-stopped --region "$REGION" --instance-ids "$instance_id"
  ok "[$name] 중지됨"

  # 3. 인스턴스 타입 변경
  log "  [$name] 타입 변경: $current_type → $TARGET_INSTANCE_TYPE"
  $AWS ec2 modify-instance-attribute \
    --region "$REGION" \
    --instance-id "$instance_id" \
    --instance-type Value="$TARGET_INSTANCE_TYPE"
  ok "[$name] 타입 변경됨"

  # 4. 재시작
  log "  [$name] 시작 중..."
  $AWS ec2 start-instances --region "$REGION" --instance-ids "$instance_id" > /dev/null
  $AWS ec2 wait instance-running --region "$REGION" --instance-ids "$instance_id"

  # 5. 새 Public IP 확인
  new_ip=$($AWS ec2 describe-instances --region "$REGION" \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

  ok "[$name] 재시작 완료! 새 Public IP: $new_ip"
  info "→ 환경변수나 설정에서 IP가 사용되는 경우 업데이트 필요"
}

if [[ "$DRY_RUN" == "true" ]]; then
  warn "DRY_RUN=true — 실제 변경은 하지 않습니다."
  echo ""
fi

log "=== EC2 다운사이징: $REGION ==="
info "목표 인스턴스 타입: $TARGET_INSTANCE_TYPE (2vCPU, 2GB, \$15.18/월)"
echo ""

case "$TARGET" in
  "all"|"eth-bridge")
    resize_instance "eth-bridge" "i-0cfd55f8a88bb4c0c" "m6i.large"
    ;;& # fallthrough only for "all"

  "all"|"bsc-bridge")
    [[ "$TARGET" == "all" || "$TARGET" == "bsc-bridge" ]] && \
    resize_instance "bsc-bridge" "i-01f3117bf4b28e0b3" "m6i.large"
    ;;&

  "all"|"operation-instance")
    [[ "$TARGET" == "all" || "$TARGET" == "operation-instance" ]] && \
    resize_instance "operation-instance" "i-087262278ac573137" "t2.medium"
    ;;&

  "all"|"bsc-bridge-operation")
    [[ "$TARGET" == "all" || "$TARGET" == "bsc-bridge-operation" ]] && \
    resize_instance "bsc-bridge-operation" "i-0e3fc72f85be6a0d2" "t2.medium"
    ;;
esac

echo ""
log "=== 완료 ==="
if [[ "$DRY_RUN" == "false" ]]; then
  echo ""
  echo "  비용 절감 효과:"
  echo "    eth-bridge:           m6i.large(\$69.26) → t3.small(\$15.18)  = -\$54.08/월"
  echo "    bsc-bridge:           m6i.large(\$69.26) → t3.small(\$15.18)  = -\$54.08/월"
  echo "    operation-instance:   t2.medium(\$33.58) → t3.small(\$15.18)  = -\$18.40/월"
  echo "    bsc-bridge-operation: t2.medium(\$33.58) → t3.small(\$15.18)  = -\$18.40/월"
  echo "    ─────────────────────────────────────────────────────────────"
  echo "    합계:                                                        -\$144.96/월"
fi

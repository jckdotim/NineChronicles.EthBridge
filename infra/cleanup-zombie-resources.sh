#!/bin/bash
# cleanup-zombie-resources.sh
#
# EKS 클러스터 삭제 후 남겨진 좀비 리소스를 제거합니다.
# 모든 리소스는 현재 미연결(available) 상태이거나 뒤에 인스턴스가 없는 상태입니다.
#
# ⚠️  실행 전 반드시 확인:
#   1. 각 리소스 목록이 실제 삭제 대상인지 AWS 콘솔에서 육안 재확인
#   2. 스냅샷이 필요한 볼륨은 없는지 확인 (EBS 스냅샷 자동 생성 옵션 제공)
#   3. DRY_RUN=true 로 먼저 실행하여 삭제 대상 확인
#
# 월 절감 효과:
#   - 서울 EBS 19개 (930GB gp2):      $106.02/월
#   - 서울 CLB 4개:                    $74.40/월
#   - 싱가포르 NAT GW + EIP:           $47.62/월
#   - 도쿄 EBS 2개 (250GB gp2):        $28.50/월
#   - 싱가포르 EBS 2개 (250GB gp2):    $28.50/월
#   ─────────────────────────────────────────────
#   합계 (세전):                       $285.04/월
#   Tax 포함 예상:                    ~$320/월
#
# 사용법:
#   DRY_RUN=true  bash cleanup-zombie-resources.sh   # 삭제 대상 확인만
#   DRY_RUN=false bash cleanup-zombie-resources.sh   # 실제 삭제 실행
#   TAKE_SNAPSHOTS=true DRY_RUN=false bash cleanup-zombie-resources.sh  # 삭제 전 스냅샷

set -euo pipefail

AWS="${AWS_CLI:-aws}"
DRY_RUN="${DRY_RUN:-true}"
TAKE_SNAPSHOTS="${TAKE_SNAPSHOTS:-false}"

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
info() { echo "  ℹ $*"; }
warn() { echo "  ⚠ $*"; }
ok()   { echo "  ✓ $*"; }
skip() { echo "  ↷ [DRY_RUN] $*"; }

if [[ "$DRY_RUN" == "true" ]]; then
  warn "DRY_RUN=true — 실제 삭제는 하지 않습니다. 삭제 대상만 출력합니다."
  warn "실제 삭제하려면: DRY_RUN=false bash cleanup-zombie-resources.sh"
  echo ""
fi

# ---------------------------------------------------------------------------
# PHASE A: ap-northeast-2 (서울) — 좀비 EBS 19개 (930GB gp2, $106.02/월)
# ---------------------------------------------------------------------------
log "=== PHASE A: 서울 좀비 EBS 볼륨 삭제 (ap-northeast-2) ==="
info "총 19개, 930GB gp2, $106.02/월 낭비 중"

ZOMBIE_VOLS_APN2=(
  vol-0b2edd170b0bb66f9   # 20GB  kubernetes-dynamic-pvc-d838134e
  vol-0e4aa3c0556d37b06   # 20GB  kubernetes-dynamic-pvc-2649dd6a
  vol-0b63bfc3cc201190d   # 20GB  kubernetes-dynamic-pvc-93041010
  vol-053e577e2f818f062   # 20GB  kubernetes-dynamic-pvc-87194b30
  vol-0337a1c82c1e5c7c9   # 20GB  kubernetes-dynamic-pvc-9f45abca
  vol-0e777f39f3db749d8   # 200GB kubernetes-dynamic-pvc-b8052f2e
  vol-0aa3f8cee320a804b   # 20GB  kubernetes-dynamic-pvc-6d134205
  vol-018a2543363141d33   # 20GB  kubernetes-dynamic-pvc-f8fd119b
  vol-0ca0b039291779f9a   # 200GB kubernetes-dynamic-pvc-093cc4fd
  vol-06dd94c3b805da1ee   # 20GB  kubernetes-dynamic-pvc-ef096a4d
  vol-0eaf6be3865583395   # 10GB  kubernetes-dynamic-pvc-7c6ec8d5
  vol-0bf9914c4e8d15806   # 10GB  kubernetes-dynamic-pvc-f675cadb
  vol-05d7d7088e44e7941   # 20GB  kubernetes-dynamic-pvc-c0e9f15d
  vol-073d5edfe020dd003   # 20GB  kubernetes-dynamic-pvc-9f87d085
  vol-0aaad3155e79c0b13   # 20GB  kubernetes-dynamic-pvc-7768bf07
  vol-0d33b7b97e73c0c73   # 200GB kubernetes-dynamic-pvc-75270e7a
  vol-0a64a03235f83a241   # 50GB  kubernetes-dynamic-pvc-f78fcb50
  vol-0178f286333b3aefd   # 20GB  kubernetes-dynamic-pvc-bb190dc7
  vol-0ab0f1b802faf03a1   # 20GB  kubernetes-dynamic-pvc-f381c668
)

for vol_id in "${ZOMBIE_VOLS_APN2[@]}"; do
  # 삭제 전 현재 상태 재확인
  state=$($AWS ec2 describe-volumes --region ap-northeast-2 \
    --volume-ids "$vol_id" \
    --query 'Volumes[0].State' --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$state" != "available" ]]; then
    warn "$vol_id: 상태=$state — 미연결 아님, 건너뜁니다 (확인 필요)"
    continue
  fi

  size=$($AWS ec2 describe-volumes --region ap-northeast-2 \
    --volume-ids "$vol_id" \
    --query 'Volumes[0].Size' --output text 2>/dev/null)

  if [[ "$DRY_RUN" == "true" ]]; then
    skip "삭제 예정: $vol_id (${size}GB, available)"
  else
    if [[ "$TAKE_SNAPSHOTS" == "true" ]]; then
      log "  스냅샷 생성 중: $vol_id ..."
      snap_id=$($AWS ec2 create-snapshot --region ap-northeast-2 \
        --volume-id "$vol_id" \
        --description "pre-cleanup-$(date +%Y%m%d)-$vol_id" \
        --query 'SnapshotId' --output text)
      info "스냅샷 생성됨: $snap_id (삭제는 계속 진행)"
    fi
    $AWS ec2 delete-volume --region ap-northeast-2 --volume-id "$vol_id"
    ok "삭제됨: $vol_id (${size}GB)"
  fi
done

echo ""

# ---------------------------------------------------------------------------
# PHASE B: ap-northeast-2 (서울) — 좀비 CLB 4개 ($74.40/월)
# ---------------------------------------------------------------------------
log "=== PHASE B: 서울 좀비 CLB 삭제 (ap-northeast-2) ==="
info "4개 CLB, 인스턴스 0개, $74.40/월 낭비 중"
info "모두 eksctl-bridge-internal-cluster 소속 (EKS 클러스터 이미 삭제됨)"

ZOMBIE_CLBS_APN2=(
  a52ae07db401e4e239b868d6da49afe8
  ab0c9c2e48a984e15af1b082597f0328
  a4335ba280a3e4cb0a8f374d46963ccc
  aa2a8924921b143d9a62d3204510ea62
)

for lb_name in "${ZOMBIE_CLBS_APN2[@]}"; do
  # 인스턴스 수 재확인
  inst_count=$($AWS elb describe-instance-health \
    --region ap-northeast-2 \
    --load-balancer-name "$lb_name" \
    --query 'length(InstanceStates)' \
    --output text 2>/dev/null || echo "0")

  if [[ "$inst_count" -gt 0 ]]; then
    warn "$lb_name: 인스턴스 ${inst_count}개 연결됨 — 건너뜁니다 (확인 필요!)"
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    skip "삭제 예정: CLB $lb_name (인스턴스 0개)"
  else
    $AWS elb delete-load-balancer --region ap-northeast-2 --load-balancer-name "$lb_name"
    ok "삭제됨: CLB $lb_name"
  fi
done

echo ""

# ---------------------------------------------------------------------------
# PHASE C: ap-southeast-1 (싱가포르) — NAT Gateway + EIP ($47.62/월)
# ---------------------------------------------------------------------------
log "=== PHASE C: 싱가포르 NAT Gateway 삭제 (ap-southeast-1) ==="
info "nat-0ba9f68640524b1e6, 데이터 처리량 0GB, $43.90/월 낭비 중"
info "9c-bridge-mainnet-cluster EKS 삭제 후 잔존 리소스"

NAT_GW_APS1="nat-0ba9f68640524b1e6"
EIP_ALLOC_APS1="eipalloc-027a94367e7947afa"

if [[ "$DRY_RUN" == "true" ]]; then
  skip "삭제 예정: NAT Gateway $NAT_GW_APS1"
  skip "해제 예정: EIP $EIP_ALLOC_APS1 (13.251.80.247)"
else
  log "  NAT Gateway 삭제 요청 중..."
  $AWS ec2 delete-nat-gateway --region ap-southeast-1 --nat-gateway-id "$NAT_GW_APS1"
  ok "삭제 요청됨: $NAT_GW_APS1 (삭제 완료까지 약 60초 소요)"

  log "  NAT Gateway 삭제 완료 대기 중..."
  $AWS ec2 wait nat-gateway-deleted --region ap-southeast-1 --nat-gateway-ids "$NAT_GW_APS1" 2>/dev/null || true

  log "  EIP 해제 중..."
  $AWS ec2 release-address --region ap-southeast-1 --allocation-id "$EIP_ALLOC_APS1"
  ok "EIP 해제됨: 13.251.80.247"
fi

echo ""

# ---------------------------------------------------------------------------
# PHASE D: ap-northeast-1 (도쿄) — 좀비 EBS 2개 ($28.50/월)
# ---------------------------------------------------------------------------
log "=== PHASE D: 도쿄 좀비 EBS 볼륨 삭제 (ap-northeast-1) ==="
info "250GB gp2, $28.50/월 낭비 중"

ZOMBIE_VOLS_APN1=(
  vol-0bf62206aef352e17   # 50GB
  vol-0a1f5da4168be277d   # 200GB
)

for vol_id in "${ZOMBIE_VOLS_APN1[@]}"; do
  state=$($AWS ec2 describe-volumes --region ap-northeast-1 \
    --volume-ids "$vol_id" \
    --query 'Volumes[0].State' --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$state" != "available" ]]; then
    warn "$vol_id: 상태=$state — 건너뜁니다"
    continue
  fi

  size=$($AWS ec2 describe-volumes --region ap-northeast-1 \
    --volume-ids "$vol_id" --query 'Volumes[0].Size' --output text 2>/dev/null)

  if [[ "$DRY_RUN" == "true" ]]; then
    skip "삭제 예정: $vol_id (${size}GB, available)"
  else
    $AWS ec2 delete-volume --region ap-northeast-1 --volume-id "$vol_id"
    ok "삭제됨: $vol_id (${size}GB)"
  fi
done

echo ""

# ---------------------------------------------------------------------------
# PHASE E: ap-southeast-1 (싱가포르) — 좀비 EBS 2개 ($28.50/월)
# ---------------------------------------------------------------------------
log "=== PHASE E: 싱가포르 좀비 EBS 볼륨 삭제 (ap-southeast-1) ==="
info "250GB gp2, $28.50/월 낭비 중"

ZOMBIE_VOLS_APS1=(
  vol-0910fbb8a003540a5   # 200GB
  vol-0b45cce8cf20fd5a8   # 50GB
)

for vol_id in "${ZOMBIE_VOLS_APS1[@]}"; do
  state=$($AWS ec2 describe-volumes --region ap-southeast-1 \
    --volume-ids "$vol_id" \
    --query 'Volumes[0].State' --output text 2>/dev/null || echo "NOT_FOUND")

  if [[ "$state" != "available" ]]; then
    warn "$vol_id: 상태=$state — 건너뜁니다"
    continue
  fi

  size=$($AWS ec2 describe-volumes --region ap-southeast-1 \
    --volume-ids "$vol_id" --query 'Volumes[0].Size' --output text 2>/dev/null)

  if [[ "$DRY_RUN" == "true" ]]; then
    skip "삭제 예정: $vol_id (${size}GB, available)"
  else
    $AWS ec2 delete-volume --region ap-southeast-1 --volume-id "$vol_id"
    ok "삭제됨: $vol_id (${size}GB)"
  fi
done

echo ""

# ---------------------------------------------------------------------------
# 완료 요약
# ---------------------------------------------------------------------------
log "=== 완료 ==="
if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "  DRY_RUN 실행 완료. 위의 '삭제 예정' 목록을 확인하세요."
  echo ""
  echo "  실제 삭제 실행:"
  echo "    DRY_RUN=false bash cleanup-zombie-resources.sh"
  echo ""
  echo "  삭제 전 스냅샷 생성 후 삭제:"
  echo "    TAKE_SNAPSHOTS=true DRY_RUN=false bash cleanup-zombie-resources.sh"
else
  echo ""
  echo "  ✅ 좀비 리소스 정리 완료!"
  echo ""
  echo "  예상 절감 (다음 달 청구서부터):"
  echo "    서울 EBS 930GB:      $106.02/월"
  echo "    서울 CLB 4개:         $74.40/월"
  echo "    싱가포르 NAT+EIP:     $47.62/월"
  echo "    도쿄 EBS 250GB:       $28.50/월"
  echo "    싱가포르 EBS 250GB:   $28.50/월"
  echo "    ─────────────────────────────"
  echo "    세전 합계:           $285.04/월"
  echo "    Tax 포함 예상:       ~$320/월"
  echo ""
  echo "  다음 단계:"
  echo "    bash downsize-ec2.sh   # Phase 2: EC2 다운사이징 (m6i.large → t3.small)"
fi

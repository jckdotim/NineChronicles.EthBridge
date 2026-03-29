# AWS 비용 최적화 마이그레이션 런북

> 작성일: 2026-03-29
> AWS Account: 504460216450
> 데이터 출처: AWS Cost Explorer + CLI 직접 조회
> Jan 2026 실측: **$611.80/월** → Phase 1 완료 후: **~$278/월** → 최종 목표: **~$69/월** (89% 절감)

---

## 현재 아키텍처 요약

```
[us-east-2 오하이오] ← 실제 서비스 운영 중
  ├── eth-bridge           (m6i.large, CPU avg 1.6%, 2021년부터 가동)
  ├── bsc-bridge           (m6i.large, 2024-03부터)
  ├── operation-instance   (t2.medium, 2024-04부터)
  └── bsc-bridge-operation (t2.medium, 2024-04부터)

[ap-northeast-2 서울] ← EKS 클러스터 삭제 후 좀비 잔존 중
  ├── CLB 4개 (뒤에 인스턴스 0개) ← $74.40/월 낭비
  └── EBS 19개 (930GB, 전부 미연결) ← $106.02/월 낭비

[ap-northeast-1 도쿄] ← EKS 잔존
  └── EBS 2개 (250GB, 전부 미연결) ← $28.50/월 낭비

[ap-southeast-1 싱가포르] ← EKS 잔존
  ├── NAT Gateway (처리량 0GB) ← $43.90/월 낭비
  └── EBS 2개 (250GB, 전부 미연결) ← $28.50/월 낭비
```

---

## 단계별 작업 계획

### Phase 1: 좀비 리소스 삭제 — 즉시, 리스크 없음

**절감 효과**: ~$320/월 (세금 포함)
**다운타임**: 없음
**위험도**: ★☆☆ (매우 낮음 — 미연결/미사용 리소스만 삭제)

#### Phase 1 실행 절차

**Step 1-0: 사전 확인 (DRY RUN)**
```bash
DRY_RUN=true bash infra/cleanup-zombie-resources.sh
```

출력 내용을 검토하여 삭제 예정 리소스가 맞는지 확인합니다.

**Step 1-1: 실제 삭제 실행**
```bash
DRY_RUN=false bash infra/cleanup-zombie-resources.sh
```

**Step 1-2: 삭제 확인**
```bash
# 서울 EBS 잔존 여부 확인 (결과 없어야 정상)
aws ec2 describe-volumes --region ap-northeast-2 \
  --filters "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' --output text

# 서울 CLB 잔존 여부 확인 (결과 없어야 정상)
aws elb describe-load-balancers --region ap-northeast-2 \
  --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text

# 싱가포르 NAT GW 상태 확인 (deleted여야 정상)
aws ec2 describe-nat-gateways --region ap-southeast-1 \
  --query 'NatGateways[].[NatGatewayId,State]' --output table
```

**✅ Phase 1 체크리스트 — 2026-03-29 완료**
- [x] DRY_RUN 출력 검토 완료
- [x] 서울 EBS 19개 삭제 완료
- [x] 서울 CLB 4개 삭제 완료
- [x] 싱가포르 NAT Gateway 삭제 완료
- [x] 싱가포르 EIP 해제 완료
- [x] 도쿄 EBS 2개 삭제 완료
- [x] 싱가포르 EBS 2개 삭제 완료

---

### Phase 2: EC2 다운사이징 — 브릿지별 순차 진행

**절감 효과**: ~$145/월 추가 절감
**다운타임**: 인스턴스당 약 2~5분 (순차 진행)
**위험도**: ★★☆ (중간 — 재시작 필요)

#### 브릿지별 절감 효과

| 인스턴스 | 현재 타입 | 현재 비용 | 목표 타입 | 목표 비용 | 절감 |
|---------|---------|---------|---------|---------|------|
| eth-bridge | m6i.large | $69.26 | t3.small | $15.18 | -$54.08 |
| bsc-bridge | m6i.large | $69.26 | t3.small | $15.18 | -$54.08 |
| operation-instance | t2.medium | $33.58 | t3.small | $15.18 | -$18.40 |
| bsc-bridge-operation | t2.medium | $33.58 | t3.small | $15.18 | -$18.40 |

> **t3.small 선택 이유**:
> eth-bridge 30일 CPU 평균 1.6%, 최대 8.4% — m6i.large(8GB RAM)는 극심한 과대 프로비저닝.
> t3.small(2GB RAM)로도 Node.js 브릿지 프로세스에 충분히 여유 있음.

#### Phase 2 실행 절차

**Step 2-1: eth-bridge 먼저 (가장 오래된 과다 프로비저닝)**
```bash
DRY_RUN=true TARGET=eth-bridge bash infra/downsize-ec2.sh   # 확인
DRY_RUN=false TARGET=eth-bridge bash infra/downsize-ec2.sh  # 실행
```

재시작 후 정상 동작 확인 (Slack 알림 수신 확인):
```bash
# 재시작 후 5분 CPU 확인
aws cloudwatch get-metric-statistics \
  --region us-east-2 \
  --namespace AWS/EC2 --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=i-0cfd55f8a88bb4c0c \
  --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Average --output table
```

**Step 2-2: bsc-bridge**
```bash
DRY_RUN=false TARGET=bsc-bridge bash infra/downsize-ec2.sh
```

**Step 2-3: operation 인스턴스**
```bash
DRY_RUN=false TARGET=operation-instance bash infra/downsize-ec2.sh
DRY_RUN=false TARGET=bsc-bridge-operation bash infra/downsize-ec2.sh
```

**⚠️ 주의: Public IP 변경 가능성**

재시작 시 Public IP가 바뀔 수 있습니다. 재시작 후 확인:
```bash
aws ec2 describe-instances --region us-east-2 \
  --instance-ids i-0cfd55f8a88bb4c0c i-01f3117bf4b28e0b3 i-087262278ac573137 i-0e3fc72f85be6a0d2 \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0],PublicIpAddress]' \
  --output table
```

**✅ Phase 2 체크리스트**
- [ ] eth-bridge: t3.small 변경 + Slack 알림 정상 확인
- [ ] bsc-bridge: t3.small 변경 + 정상 동작 확인
- [ ] operation-instance: t3.small 변경
- [ ] bsc-bridge-operation: t3.small 변경
- [ ] Public IP 변경 여부 확인 및 관련 설정 업데이트

---

### Phase 3: t4g.nano 이전 (팀 검토 후 진행)

**절감 효과**: ~$68/월 추가 절감 (Phase 2 대비)
**다운타임**: 인스턴스당 약 10분 (순차 진행)
**위험도**: ★★☆ (ARM64 이미지 빌드 필요)

eth-bridge, bsc-bridge를 ARM64 Graviton2 t4g.nano 신규 인스턴스로 이전.

#### 전제 조건

- Phase 2 완료 (t3.small 다운사이징 후 안정 운영 확인)
- ARM64 Docker 이미지 빌드: `bridge/Dockerfile.arm64` (준비 완료)
- ARM64 SQLite 바이너리 대응: Dockerfile 내 musl arm64 빌드 포함 (준비 완료)

#### 실행 절차

```bash
# 신규 t4g.nano 인스턴스 프로비저닝
bash infra/launch-t4g-nano.sh

# 인스턴스 초기 설정 (ARM64 AL2023)
bash infra/setup-instance.sh <NEW_INSTANCE_ID>

# SQLite 상태 마이그레이션 (S3 경유)
bash infra/migrate-sqlite.sh <OLD_INSTANCE_IP> <S3_BUCKET> <NEW_INSTANCE_ID>
```

#### 주의사항

- eth-bridge와 bsc-bridge는 **절대 동시에 중단하지 않음** (순차 진행)
- 신규 인스턴스 기동 후 최소 **10분 관찰** (Slack 알림 정상 수신 확인)
- `PendingTransactionHandler`가 시작 시 in-flight 트랜잭션을 FAILED 처리 → Slack 알림으로 확인 가능
- 구 인스턴스는 중지 후 1주일 모니터링 후 종료

**✅ Phase 3 체크리스트**
- [ ] ARM64 Docker 이미지 빌드 및 ECR 푸시
- [ ] eth-bridge: t4g.nano 신규 기동 + SQLite 마이그레이션 + Slack 알림 확인
- [ ] bsc-bridge: t4g.nano 신규 기동 + SQLite 마이그레이션 + Slack 알림 확인
- [ ] 구 인스턴스 중지 → 1주일 후 종료

---

### Phase 4: operation 인스턴스 통합 (선택, 팀 검토 필요)

`operation-instance`와 `bsc-bridge-operation`이 같은 서브넷, 같은 타입.
실제 역할을 팀에서 확인 후 1개로 통합 가능 시 $15/월 추가 절감.

---

## 예상 월 비용 변화

```
Jan 2026 실측:       $611.80/월
Phase 1 완료:       ~$278/월  ✅ 2026-03-29 완료
Phase 2 완료 후:    ~$115/월  (EC2 다운사이징, 팀 결정 대기)
Phase 3 완료 후:    ~$69/월   (t4g.nano 이전, 팀 결정 대기)
```

---

## 롤백 절차

### Phase 1 (삭제 후 복구)

미연결 EBS는 삭제 후 복구 불가. `TAKE_SNAPSHOTS=true`로 실행 시 스냅샷 복구 가능.
CLB는 삭제 후 재생성 가능하나 DNS가 바뀝니다 (어차피 인스턴스가 없으므로 무의미).

### Phase 2 (인스턴스 타입 원복)

즉시 원복 가능 (5분):
```bash
aws ec2 stop-instances --region us-east-2 --instance-ids i-0cfd55f8a88bb4c0c
aws ec2 modify-instance-attribute --region us-east-2 \
  --instance-id i-0cfd55f8a88bb4c0c --instance-type Value=m6i.large
aws ec2 start-instances --region us-east-2 --instance-ids i-0cfd55f8a88bb4c0c
```

---

## 비용 모니터링 설정

```bash
# 월 $150 초과 시 이메일 알림
aws budgets create-budget \
  --account-id 504460216450 \
  --budget '{
    "BudgetName": "bridge-cost-alert",
    "BudgetLimit": {"Amount": "150", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[{
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80
    },
    "Subscribers": [
      {"SubscriptionType": "EMAIL", "Address": "your-email@example.com"}
    ]
  }]'
```

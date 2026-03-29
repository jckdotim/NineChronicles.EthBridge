# 아키텍처 문서: NineChronicles.EthBridge

> 최종 업데이트: 2026-03-29 (AWS 실계정 직접 조회 기반)
> AWS Account: 504460216450
> 실제 운영 리전: **us-east-2 (오하이오)**

---

## 1. 현재 아키텍처 (AS-IS) — Phase 1 완료 후

```
[us-east-2, 오하이오] ← 실제 운영
  |
  [Default VPC, 퍼블릭 서브넷]
  |
  +-- eth-bridge (i-0cfd55f8a88bb4c0c)
  |     m6i.large, CPU avg 1.6%, 2021년~
  |     EBS: 100GB gp2 (vol-032d28a1c199a314e)
  |
  +-- bsc-bridge (i-01f3117bf4b28e0b3)
  |     m6i.large, 2024-03~
  |     EBS: 100GB gp3 (vol-0de0b51a280890490)
  |
  +-- operation-instance (i-087262278ac573137)
  |     t2.medium, 2024-04~
  |     EBS: 8GB gp3
  |
  +-- bsc-bridge-operation (i-0e3fc72f85be6a0d2)
        t2.medium, 2024-04~
        EBS: 8GB gp3

모두 퍼블릭 서브넷, 퍼블릭 IP 보유
NAT Gateway 없음 (default VPC는 원래 퍼블릭)
ELB 없음 (Phase 1에서 정리)

          |
    +-----------+-----------+-----------+
    |           |           |           |
  [AWS KMS]  [ETH RPC]  [9c Node]  [Slack/PagerDuty/OpenSearch]
```

**Phase 1에서 제거된 좀비 리소스 (2026-03-29):**
- ap-northeast-2: EBS 19개 (930GB) + CLB 4개
- ap-northeast-1: EBS 2개 (250GB)
- ap-southeast-1: NAT Gateway + EIP + EBS 2개 (250GB)
- 절감: $285/월

---

## 2. 목표 아키텍처 (TO-BE) — Phase 2+3

```
[us-east-2, 오하이오]
  |
  [Default VPC, 퍼블릭 서브넷]
  |
  +-- eth-bridge (신규 t4g.nano)
  |     ARM64 Graviton2, $3.80/월
  |     EBS: 8GB gp3
  |     Docker: bridge 컨테이너 (Dockerfile.arm64)
  |     보안그룹: 인바운드 없음, 아웃바운드 443만 허용
  |
  +-- bsc-bridge (신규 t4g.nano)
  |     ARM64 Graviton2, $3.80/월
  |     EBS: 8GB gp3
  |     Docker: bridge 컨테이너 (Dockerfile.arm64)
  |
  +-- operation-instance (t3.small으로 다운사이징)
  |     $15.18/월
  |
  +-- bsc-bridge-operation (t3.small으로 다운사이징)
        $15.18/월

관리 접근: SSM Session Manager만 허용 (SSH 포트 불필요)

          |
    +-----------+-----------+-----------+
    |           |           |           |
  [AWS KMS]  [ETH RPC]  [9c Node]  [Slack/PagerDuty]
```

---

## 3. 비용 변화 로드맵

```
Jan 2026 실측:  $611.80/월
                │
Phase 1 완료    │ -$285 (좀비 EBS/CLB/NAT 삭제) ← 2026-03-29 완료
                ▼
현재:          ~$278/월
                │
Phase 2         │ -$145 (m6i.large × 2, t2.medium × 2 → t3.small × 4)
                ▼
               ~$133/월
                │
Phase 3         │ -$68 (t3.small → t4g.nano, EBS 축소)
                ▼
               ~$65/월
```

| 단계 | 월 비용 | 절감 | 다운타임 | 위험도 |
|------|---------|------|---------|--------|
| 현재 (Phase 1 후) | ~$278 | - | 없음 | - |
| Phase 2: EC2 다운사이징 | ~$133 | $145 | 인스턴스당 5분 | 낮음 |
| Phase 3: t4g.nano 이전 | ~$65 | $68 | 인스턴스당 10분 | 중간 |

---

## 4. Phase 3: t4g.nano 이전 핵심 사항

### ARM64 Docker 이미지 빌드

기존 Dockerfile은 x64 전용이었음. `Dockerfile.arm64`로 빌드:

```bash
# t4g.nano 전용 ARM64 이미지 빌드
docker buildx build \
  --platform linux/arm64 \
  -f bridge/Dockerfile.arm64 \
  -t <ecr-uri>/ncg-eth-bridge:latest-arm64 \
  bridge/

docker push <ecr-uri>/ncg-eth-bridge:latest-arm64
```

### SQLite 마이그레이션 절차

1. 현재 인스턴스에서 SQLite dump (컨테이너 중지 후)
2. S3 경유로 신규 인스턴스에 복원
3. 신규 인스턴스에서 컨테이너 정상 기동 확인
4. 구 인스턴스 중지 → 1주일 후 종료

```bash
# 마이그레이션 스크립트
bash infra/migrate-sqlite.sh <OLD_INSTANCE_IP> <S3_BUCKET> <NEW_INSTANCE_ID>
```

### 컷오버 주의사항

- eth-bridge와 bsc-bridge는 **절대 동시에 중단하지 않음** (순차 진행)
- 신규 인스턴스 기동 후 최소 **10분 관찰** (Slack 알림 정상 수신 확인)
- `PendingTransactionHandler`가 시작 시 in-flight 트랜잭션을 FAILED 처리 → Slack 알림으로 확인 가능

---

## 5. 왜 Lambda/Fargate가 아닌 EC2인가

### Lambda 불가 이유

`index.ts`의 실행 구조:
```typescript
// 두 개의 영구 루프 — Lambda 15분 제한으로 구조적 불가
await Promise.all([
  ethereumBurnEventMonitor.run(),   // while(true) + 15초 sleep
  nineChroniclesMonitor.run(),      // while(true) + 15초 sleep
]);
```
SQLite를 인메모리 상태로 유지하며 재시작 시 체크포인트 복원 필요.

### Fargate 대비 t4g.nano 비용

| | Fargate (0.25vCPU/0.5GB) | t4g.nano |
|--|--|--|
| 월 비용 | ~$12-15 + EFS $3-5 | **$3.80** |
| SQLite 저장 | EFS 필요 (네트워크 레이턴시) | EBS 직접 (로컬) |
| 관리 복잡도 | Task Definition, Service | systemd 1개 |

---

## 6. 보안

### 보안 그룹 설정 (신규 t4g.nano)

```
인바운드: 없음 (전부 거부)
아웃바운드: TCP 443 → 0.0.0.0/0 (HTTPS: KMS, RPC, Slack 등)
```

SSH 포트 불필요. 관리는 **SSM Session Manager** 전용:
```bash
aws ssm start-session --target <INSTANCE_ID> --region us-east-2
```

### KMS 접근 방식 (기존 유지)

인스턴스 프로파일이 아닌 환경변수로 별도 IAM 사용자 접근:
```
KMS_PROVIDER_AWS_ACCESSKEY=...
KMS_PROVIDER_AWS_SECRETKEY=...
```

---

## 7. 운영 스크립트 목록

| 스크립트 | 용도 |
|---------|------|
| `infra/launch-t4g-nano.sh` | t4g.nano 신규 인스턴스 프로비저닝 |
| `infra/setup-instance.sh` | AL2023 ARM64 초기 설정 자동화 |
| `infra/migrate-sqlite.sh` | SQLite 상태 S3 경유 마이그레이션 |
| `infra/downsize-ec2.sh` | EC2 인스턴스 타입 변경 (Phase 2) |
| `infra/cleanup-zombie-resources.sh` | 좀비 리소스 삭제 (**Phase 1 완료**) |
| `infra/backup-sqlite.sh` | S3 야간 SQLite 백업 |
| `infra/check-health.sh` | 브릿지 헬스체크 |
| `infra/cloudwatch-alarm.sh` | EC2 Auto Recovery + 알람 설정 |
| `infra/create-iam-role.sh` | 최소권한 IAM 역할 생성 |
| `infra/env.ssm.sh` | SSM Parameter Store → .env 동기화 |
| `bridge/Dockerfile` | 멀티 아키텍처 (amd64/arm64) |
| `bridge/Dockerfile.arm64` | t4g.nano 전용 ARM64 |

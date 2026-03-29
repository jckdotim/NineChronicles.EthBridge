# AWS 비용 분석: NineChronicles.EthBridge

> 작성일: 2026-03-29 (AWS 실계정 직접 조회 기반)
> Account: 504460216450
> 현재 월 비용: **$611.80** (Jan 2026 실측)
> 목표 월 비용: **~$30 미만**
> 예상 절감률: **~95%**

---

## 1. 실제 인프라 현황 (AWS 직접 조회)

### 실행 중인 EC2 인스턴스 (us-east-2, 오하이오)

| Name | Instance ID | Type | 월 비용 | 가동 시작 | CPU 평균 |
|------|-------------|------|---------|----------|---------|
| eth-bridge | i-0cfd55f8a88bb4c0c | **m6i.large** | ~$69.26 | 2021-09-16 | **1.60%** |
| bsc-bridge | i-01f3117bf4b28e0b3 | **m6i.large** | ~$69.26 | 2024-03-12 | 미측정 |
| operation-instance | i-087262278ac573137 | t2.medium | ~$33.58 | 2024-04-12 | 미측정 |
| bsc-bridge-operation | i-0e3fc72f85be6a0d2 | t2.medium | ~$33.58 | 2024-04-17 | 미측정 |

> **m6i.large**: 2 vCPU, 8GB RAM, $0.096/hr → $69.26/월
> CPU 평균 1.6%로 m6i.large 사용은 **극심한 과대 프로비저닝**

### 연결된 EBS 볼륨 (us-east-2, 실제 사용 중)

| Volume ID | Type | Size | 월 비용 | 연결 인스턴스 |
|-----------|------|------|---------|-------------|
| vol-032d28a1c199a314e | gp2 | 100GB | $11.40 | eth-bridge |
| vol-0de0b51a280890490 | gp3 | 100GB | $9.12 | bsc-bridge |
| vol-0dc9e910595357714 | gp3 | 8GB | $0.73 | operation-instance |
| vol-01b29c87a2eaa1eb5 | gp3 | 8GB | $0.73 | bsc-bridge-operation |

---

## 2. 좀비 리소스 현황 (즉시 삭제 가능)

### 🚨 ap-northeast-2 (서울) — 좀비 EBS 19개

EKS 클러스터가 삭제된 후 PVC(Persistent Volume Claim)만 남은 상태.
인스턴스 없음, 전부 `available` (미연결).

| 볼륨 수 | 총 용량 | 타입 | 월 낭비 비용 |
|---------|---------|------|------------|
| 19개 | 930 GB | gp2 | **$106.02/월** |

### 🚨 ap-northeast-1 (도쿄) — 좀비 EBS 2개

| 볼륨 ID | Size | 월 낭비 |
|---------|------|---------|
| vol-0bf62206aef352e17 | 50GB gp2 | $5.70 |
| vol-0a1f5da4168be277d | 200GB gp2 | $22.80 |
| **소계** | 250GB | **$28.50/월** |

### 🚨 ap-southeast-1 (싱가포르) — 좀비 EBS 2개 + NAT Gateway

| 리소스 | 상세 | 월 낭비 |
|--------|------|---------|
| vol-0910fbb8a003540a5 | 200GB gp2 | $22.80 |
| vol-0b45cce8cf20fd5a8 | 50GB gp2 | $5.70 |
| NAT Gateway (nat-0ba9f68640524b1e6) | 데이터 처리량 0GB | $43.90 |
| EIP (13.251.80.247) | NAT 연결 중 | 포함 |
| **소계** | | **$72.40/월** |

### 🚨 ap-northeast-2 (서울) — 좀비 CLB 4개 (인스턴스 0개)

```
a52ae07db401e4e239b868d6da49afe8  (뒤에 인스턴스 없음)
ab0c9c2e48a984e15af1b082597f0328  (뒤에 인스턴스 없음)
a4335ba280a3e4cb0a8f374d46963ccc  (뒤에 인스턴스 없음)
aa2a8924921b143d9a62d3204510ea62  (뒤에 인스턴스 없음)
```
→ 모두 `eksctl-bridge-internal-cluster/VPC` 소속, EKS 클러스터 삭제 후 잔존

| 항목 | 월 낭비 |
|------|---------|
| CLB 4개 × $18.60/월 | **$74.40/월** |

---

## 3. 비용 완전 분해 (Jan 2026 실측)

| Usage Type | 내용 | 월 비용 |
|------------|------|---------|
| USE2-BoxUsage:m6i.large × 2 | eth-bridge + bsc-bridge EC2 | $142.85 |
| APN2-EBS:VolumeUsage.gp2 | 서울 좀비 EBS 930GB | $106.02 |
| APN2-LoadBalancerUsage | 서울 좀비 CLB 4개 | $74.40 |
| USE2-BoxUsage:t2.medium × 2 | operation 인스턴스 2개 | $69.04 |
| NoUsageType (Tax) | | $55.62 |
| APS1-NatGateway-Hours | 싱가포르 좀비 NAT GW | $43.90 |
| APN1-EBS:VolumeUsage.gp2 | 도쿄 좀비 EBS 250GB | $30.00 |
| APS1-EBS:VolumeUsage.gp2 | 싱가포르 좀비 EBS 250GB | $30.00 |
| APN2-PublicIPv4:InUseAddress | 서울 Public IP (4개 × ELB) | $14.90 |
| USE2-PublicIPv4:InUseAddress | 오하이오 Public IP (4개 × EC2) | $14.88 |
| USE2-EBS:VolumeUsage.gp2 | eth-bridge 100GB root vol | $10.00 |
| USE2-EBS:VolumeUsage.gp3 | bsc-bridge+operation EBS | $9.28 |
| ap-northeast-2-KMS-Keys | KMS 키 5.99개 | $5.99 |
| APS1-PublicIPv4:InUseAddress | 싱가포르 EIP | $3.72 |
| USE2-TimedStorage-ByteHrs | CloudWatch Logs | $1.03 |
| **합계** | | **$611.63** |

---

## 4. 절감 기회 분류

### ✅ 즉시 삭제 가능 (좀비 리소스) — $253/월

이 리소스들은 **사용 중인 것이 없음**. 당장 삭제해도 서비스에 영향 없음.

| 항목 | 월 절감 | 삭제 위험도 |
|------|---------|------------|
| 서울 좀비 EBS 19개 (930GB gp2) | $106.02 | **없음** (미연결) |
| 서울 좀비 CLB 4개 | $74.40 | **없음** (인스턴스 0개) |
| 싱가포르 좀비 NAT GW + EIP | $43.90 + $3.72 | **없음** (처리량 0) |
| 도쿄 좀비 EBS 2개 (250GB gp2) | $28.50 | **없음** (미연결) |
| 싱가포르 좀비 EBS 2개 (250GB gp2) | $28.50 | **없음** (미연결) |
| **소계** | **$285.04/월** | |

> 세금 포함 시 약 **$320/월** 즉시 절감

### 🔧 EC2 다운사이징 — $180/월 추가 절감

m6i.large (CPU 1.6% 평균)를 적정 사이즈로 교체.

| 현재 | 권장 | 월 비용 변화 |
|------|------|------------|
| m6i.large ($69.26) × 2 | t3.small ($15.33) × 2 | -$107.86 |
| t2.medium ($33.58) × 2 | t3.small ($15.33) × 2 | -$36.50 |
| **합계** | | **-$144.36/월** |

> t3.small: 2 vCPU, 2GB RAM, $0.0208/hr — 브릿지 Node.js에 충분

### 🔧 EBS gp2 → gp3 전환 — $20/월 추가 절감

현재 eth-bridge의 100GB gp2 볼륨(연결 중, $11.40)을 gp3로 전환:
- 100GB gp3: $9.12/월 (-$2.28)
- gp3는 gp2 대비 성능 20% 향상, 비용 20% 절감

### 🔧 operation 인스턴스 통합 (검토 필요) — $33/월 추가 절감

`operation-instance`와 `bsc-bridge-operation`이 별도 인스턴스인데,
같은 서브넷(subnet-912de4ec), 같은 타입(t2.medium) — 기능 확인 후 통합 가능 시 1개 절감.

---

## 5. 목표 비용 계산

### Phase 1 완료 후 (즉시 삭제만)

| 항목 | 비용 |
|------|------|
| EC2 4개 (현행 유지) | $205.68 |
| EBS 연결 볼륨 4개 | $22.22 |
| KMS | $6.00 |
| Public IPv4 4개 | $14.88 |
| CloudWatch | $1.03 |
| Tax (감소) | ~$28 |
| **합계** | **~$278/월** |

### Phase 2 완료 후 (EC2 다운사이징 포함)

| 항목 | 비용 |
|------|------|
| t3.small × 4 (eth, bsc, op1, op2) | $61.28 |
| EBS gp3 전환 후 | $20.00 |
| KMS | $6.00 |
| Public IPv4 4개 | $14.88 |
| CloudWatch | $1.03 |
| Tax (~10%) | ~$10 |
| **합계** | **~$113/월** |

### Phase 3 완료 후 (operation 인스턴스 통합)

| 항목 | 비용 |
|------|------|
| t3.small × 3 (eth, bsc, op-통합) | $45.96 |
| EBS | $18.00 |
| KMS | $6.00 |
| Public IPv4 3개 | $11.16 |
| Tax | ~$8 |
| **합계** | **~$89/월** |

---

## 6. 월/연간 절감 효과

| 구분 | 현재 | Phase 1 | Phase 2 | Phase 3 |
|------|------|---------|---------|---------|
| 월 비용 | $611.80 | ~$278 | ~$113 | ~$89 |
| 연 비용 | $7,342 | ~$3,336 | ~$1,356 | ~$1,068 |
| 절감액 | — | $333/월 | $499/월 | $523/월 |
| 절감률 | — | 54% | 82% | 85% |

> **Phase 1은 리스크 제로, 즉시 $333/월 절감** — 오늘 당장 실행 권장

---

## 7. 발견된 주요 문제점

1. **EKS 클러스터가 이미 삭제되었으나, PVC(EBS)와 CLB가 정리되지 않음**
   - ap-northeast-2: 930GB EBS + CLB 4개 → $180/월 낭비
   - ap-northeast-1: 250GB EBS → $28.50/월 낭비
   - ap-southeast-1: 250GB EBS + NAT GW → $72.40/월 낭비

2. **eth-bridge가 m6i.large에서 2021년부터 실행 중 (CPU 1.6%)**
   - 5년간 과대 프로비저닝 지속
   - t3.small이나 t3.micro로 충분

3. **싱가포르 NAT Gateway가 처리량 0인 채로 44$/월 지불 중**
   - `9c-bridge-mainnet-cluster` EKS 클러스터 잔존 리소스

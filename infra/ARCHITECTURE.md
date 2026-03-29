# 아키텍처 문서: NineChronicles.EthBridge

> 작성일: 2026-03-29
> 대상 환경: AWS ap-northeast-2 (서울 리전)

---

## 1. 현재 아키텍처 (AS-IS)

```
인터넷
  |
  | (인바운드 없음)
  |
[Internet Gateway]
  |
  +--[Public Subnet]--+
  |                   |
  |            [ALB]  |  <-- 실제로 트래픽 없음
  |                   |
  +-------------------+
  |
  +--[Private Subnet]--+
  |                    |
  |   [EC2 Instance]   |  <-- 브리지 Docker 컨테이너
  |   (과대 프로비전)  |
  |                    |
  +--------------------+
          |
          | (아웃바운드 전용)
          |
     [NAT Gateway]  <-- 월 $229 낭비
          |
          |
     [Internet Gateway]
          |
    +-----------+-----------+-----------+
    |           |           |           |
  [AWS KMS]  [ETH RPC]  [9c Node]  [Slack/OpenSearch]
```

**문제점 요약:**
- ALB: 브리지는 인바운드 HTTP 요청을 받지 않아 ALB가 전혀 불필요
- NAT Gateway: 프라이빗 서브넷의 아웃바운드를 처리하나, 블록체인 폴링 데이터로 인해 월 $229 발생
- EC2 과대 프로비전: Node.js 프로세스 1개에 엔터프라이즈급 인스턴스 사용

---

## 2. 목표 아키텍처 (TO-BE)

```
인터넷
  |
  |
[Internet Gateway]
  |
  +--[Public Subnet]---------------------------+
  |                                            |
  |   [EC2 t4g.nano]                          |
  |   +---------------------------------+      |
  |   | Docker: bridge 컨테이너         |      |
  |   |   - SQLite 상태 파일            |      |
  |   |   - /data/monitor_state.db     |      |
  |   |   - /data/exchange_history.db  |      |
  |   +---------------------------------+      |
  |   |  보안 그룹: 인바운드 모두 차단  |      |
  |   |  아웃바운드: 443/80 허용        |      |
  |   +---------------------------------+      |
  |                                            |
  |   [SSM Session Manager] <-- 유일한 접근 경로|
  +--------------------------------------------+
          |
          | (아웃바운드: 인터넷 게이트웨이 직접 경유)
          |
    +-----------+-----------+-----------+----------+
    |           |           |           |          |
  [AWS KMS]  [ETH RPC]  [9c Node]  [Slack]  [OpenSearch]

  [EC2 Auto Recovery] <-- 하드웨어 장애 시 자동 복구
  [S3 Backup]         <-- 야간 SQLite 백업
  [CloudWatch Alarm]  <-- 상태 모니터링
```

**개선 사항:**
- NAT Gateway 제거: 아웃바운드 트래픽이 인터넷 게이트웨이를 직접 경유
- ALB 제거: 인바운드 트래픽이 없으므로 불필요
- 인스턴스 다운사이징: 실제 사용량에 맞는 t4g.nano 사용

---

## 3. 왜 t4g.nano + 퍼블릭 서브넷인가?

### Lambda를 선택하지 않은 이유

| 기준 | Lambda | t4g.nano EC2 |
|------|--------|--------------|
| 실행 모델 | 이벤트 기반, 최대 15분 | 장기 실행 프로세스 |
| 상태 저장 | 불가 (SQLite 사용 불가) | EBS 볼륨 영구 저장 |
| 블록체인 폴링 | 매 블록마다 invocation 비용 발생 | 무제한 루프 실행 |
| 콜드 스타트 | 있음 (트랜잭션 지연 가능) | 없음 |
| **결론** | **부적합** | **적합** |

이 브리지 애플리케이션은 `index.ts`에서 볼 수 있듯이 `ethereumBurnEventMonitor.run()`과 `nineChroniclesMonitor.run()`을 영구 루프로 실행합니다. Lambda의 실행 시간 제한(15분)과 상태 비저장 특성은 이 아키텍처와 근본적으로 맞지 않습니다.

### Fargate를 선택하지 않은 이유

| 기준 | Fargate | t4g.nano EC2 |
|------|---------|--------------|
| 기본 비용 | ~$30–40/월 (0.25 vCPU, 0.5GB) | $3.02/월 |
| SQLite 파일 저장 | EFS 필요 ($추가) 또는 재시작 시 손실 | EBS 직접 마운트 |
| 관리 복잡도 | ECS Task Definition, Service 관리 필요 | systemd/docker 단일 설정 |
| 인스턴스 타입 유연성 | 제한적 | 자유로운 업그레이드 |
| **결론** | **과도한 비용** | **적합** |

Fargate는 관리 부담을 줄여주지만, 이 규모(하루 10건 미만)에서는 비용 대비 효과가 없습니다.

### 퍼블릭 서브넷을 선택한 이유

- **NAT Gateway 비용 제거**: 프라이빗 서브넷은 아웃바운드 인터넷 접근을 위해 NAT Gateway가 필수. 월 $32 고정 + 데이터 처리 요금 발생
- **인터넷 게이트웨이 직접 사용**: 퍼블릭 서브넷은 인터넷 게이트웨이를 통해 무료로 아웃바운드 가능 (AWS 데이터 전송 비용은 첫 100GB/월 무료)
- **보안 동등성**: 인바운드 포트를 모두 차단하면 퍼블릭 IP가 있어도 외부에서 접근 불가. SSM Session Manager로만 관리 접근

---

## 4. SQLite 영속성 전략

### 파일 위치

```
/data/monitor_state.db      # 블록체인 모니터 상태 (마지막 처리 블록 번호)
/data/exchange_history.db   # 거래 기록 및 중복 방지
```

환경변수 매핑:
```
MONITOR_STATE_STORE_PATH=/data/monitor_state.db
EXCHANGE_HISTORY_STORE_PATH=/data/exchange_history.db
```

### EBS 볼륨 설정

- 볼륨 타입: `gp3` (gp2보다 20% 저렴, 기본 3000 IOPS)
- 볼륨 크기: 20GB (실제 SQLite 파일은 수 MB이나 여유분 확보)
- Delete on termination: **false** (인스턴스 종료 시에도 데이터 보존)
- 암호화: KMS CMK로 암호화 권장

### Docker 볼륨 마운트

```yaml
# docker-compose.yaml (운영용)
services:
  bridge:
    image: planetariumhq/9c-eth-bridge:latest
    volumes:
      - /data:/data
    env_file:
      - /etc/bridge/.env
    restart: always
```

### 데이터 중요도별 분류

| 파일 | 손실 시 영향 | 복구 방법 |
|------|------------|---------|
| `exchange_history.db` | **치명적**: 거래 중복 처리 가능성 | S3 백업에서 복원 |
| `monitor_state.db` | **중간**: 처리된 블록을 재스캔, 중복은 exchange_history가 방지 | 0부터 재시작 가능 (단 시간 소요) |

---

## 5. EC2 Auto Recovery 설정

### 설정 목적

EC2 Auto Recovery는 AWS 하드웨어 장애(시스템 상태 체크 실패) 시 자동으로 인스턴스를 다른 하드웨어로 이전합니다. 인스턴스 ID, Elastic IP, EBS 볼륨이 모두 유지됩니다.

### CloudWatch Alarm 설정

```bash
# Auto Recovery 알람 생성
aws cloudwatch put-metric-alarm \
  --alarm-name "bridge-auto-recovery" \
  --alarm-description "EC2 Auto Recovery for bridge instance" \
  --metric-name StatusCheckFailed_System \
  --namespace AWS/EC2 \
  --statistic Minimum \
  --period 60 \
  --evaluation-periods 2 \
  --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold \
  --dimensions Name=InstanceId,Value=<INSTANCE_ID> \
  --alarm-actions arn:aws:automate:<REGION>:ec2:recover \
  --treat-missing-data notBreaching
```

### Auto Recovery vs Auto Scaling

| 기준 | Auto Recovery | Auto Scaling |
|------|--------------|--------------|
| 목적 | 하드웨어 장애 자동 복구 | 트래픽에 따른 스케일 인/아웃 |
| 인스턴스 ID 유지 | 유지됨 | 새 인스턴스 생성 |
| EBS 볼륨 유지 | 유지됨 | 별도 설정 필요 |
| 비용 | 추가 없음 | 추가 없음 |
| **이 서비스에 적합** | **적합** | **불필요** |

---

## 6. 보안 설정

### 인바운드 포트 완전 차단

```
Security Group: bridge-sg
Inbound Rules:
  - 없음 (모두 거부)

Outbound Rules:
  - TCP 443 (HTTPS) -> 0.0.0.0/0  # KMS, ETH RPC, Slack 등
  - TCP 80  (HTTP)  -> 0.0.0.0/0  # 필요시
```

SSH(22번 포트)는 허용하지 않습니다. 모든 관리 접근은 **SSM Session Manager**를 통해 수행합니다.

### SSM Session Manager 접근 방법

```bash
# SSM을 통한 세션 시작 (AWS CLI v2 + session-manager-plugin 필요)
aws ssm start-session --target <INSTANCE_ID> --region ap-northeast-2

# 포트 포워딩 예시 (로컬 디버깅 시)
aws ssm start-session \
  --target <INSTANCE_ID> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```

### IAM 인스턴스 프로파일

EC2 인스턴스에 부여해야 하는 최소 권한:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
        "ec2messages:AcknowledgeMessage",
        "ec2messages:DeleteMessage",
        "ec2messages:FailMessage",
        "ec2messages:GetEndpoint",
        "ec2messages:GetMessages",
        "ec2messages:SendReply"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::bridge-backup-bucket/sqlite/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "cloudwatch:PutMetricData",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
```

> KMS 접근 권한은 인스턴스 프로파일이 아닌 **KMS_PROVIDER_AWS_ACCESSKEY / KMS_PROVIDER_AWS_SECRETKEY 환경변수**를 통해 별도 IAM 사용자로 접근합니다 (기존 설정 유지).

---

## 7. S3 야간 백업 전략

### 백업 스크립트

```bash
#!/bin/bash
# /usr/local/bin/backup-sqlite.sh

set -e

BACKUP_BUCKET="bridge-backup-bucket"
BACKUP_PREFIX="sqlite/$(date +%Y/%m/%d)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# SQLite 핫 백업 (실행 중에도 안전하게 복사)
# .backup 명령어는 WAL 모드에서도 일관성 보장
sqlite3 /data/monitor_state.db ".backup /tmp/monitor_state_${TIMESTAMP}.db"
sqlite3 /data/exchange_history.db ".backup /tmp/exchange_history_${TIMESTAMP}.db"

# S3 업로드
aws s3 cp /tmp/monitor_state_${TIMESTAMP}.db \
  s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/monitor_state_${TIMESTAMP}.db

aws s3 cp /tmp/exchange_history_${TIMESTAMP}.db \
  s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/exchange_history_${TIMESTAMP}.db

# 임시 파일 정리
rm -f /tmp/monitor_state_${TIMESTAMP}.db /tmp/exchange_history_${TIMESTAMP}.db

echo "Backup completed: ${TIMESTAMP}"
```

### Cron 설정

```bash
# /etc/cron.d/bridge-backup
# 매일 오전 3시 (KST 기준 낮 12시) 백업
0 3 * * * root /usr/local/bin/backup-sqlite.sh >> /var/log/bridge-backup.log 2>&1
```

### 보존 정책

```bash
# 30일 이상 된 백업 자동 삭제 (S3 Lifecycle Policy)
aws s3api put-bucket-lifecycle-configuration \
  --bucket bridge-backup-bucket \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "delete-old-backups",
      "Status": "Enabled",
      "Filter": {"Prefix": "sqlite/"},
      "Expiration": {"Days": 30}
    }]
  }'
```

### 백업에서 복원하는 방법

```bash
# 특정 날짜 백업 목록 확인
aws s3 ls s3://bridge-backup-bucket/sqlite/2026/03/29/

# 복원
aws s3 cp s3://bridge-backup-bucket/sqlite/2026/03/29/exchange_history_20260329_030000.db \
  /data/exchange_history.db

# Docker 컨테이너 재시작
docker compose -f /etc/bridge/docker-compose.yaml restart bridge
```

---

## 8. 모니터링 및 알람

### CloudWatch 권장 알람

| 알람명 | 메트릭 | 임계값 | 알람 동작 |
|--------|--------|--------|-----------|
| bridge-cpu-high | CPUUtilization | >80% (5분) | SNS 알림 |
| bridge-memory-low | mem_available_percent | <10% | SNS 알림 |
| bridge-disk-low | disk_free | <2GB | SNS 알림 |
| bridge-instance-recover | StatusCheckFailed_System | >=1 (2분) | EC2 Auto Recovery |
| bridge-instance-alarm | StatusCheckFailed_Instance | >=1 (5분) | SNS 알림 (수동 확인 필요) |

### CloudWatch Agent 설정 (메모리/디스크 모니터링)

기본 EC2 메트릭에는 메모리와 디스크 사용량이 포함되지 않습니다. CloudWatch Agent를 설치하면 수집 가능합니다.

```bash
# CloudWatch Agent 설치 (Amazon Linux 2023)
sudo yum install -y amazon-cloudwatch-agent

# 설정 파일 생성
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-config-wizard
```

### 브리지 프로세스 상태 확인

```bash
# 컨테이너 실행 상태 확인
docker ps --filter name=bridge

# 최근 로그 확인
docker logs bridge --tail 50

# SQLite 파일 크기 및 최근 수정 시간 확인
ls -lh /data/*.db
sqlite3 /data/exchange_history.db "SELECT COUNT(*), MAX(timestamp) FROM exchange_histories;"
```

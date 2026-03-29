# AWS 비용 최적화 마이그레이션 런북
# NineChronicles.EthBridge

> 작성일: 2026-03-29
> 현재 비용: $611.80/월 → 목표 비용: ~$12–15/월
> 예상 작업 시간: 총 2–3시간 (Phase별 독립 실행 가능)

---

## 개요

### 현재 아키텍처 vs 목표 아키텍처

```
[현재 AS-IS]                          [목표 TO-BE]
=================                     ==================

인터넷                                 인터넷
  |                                      |
[IGW]                                  [IGW]
  |                                      |
[퍼블릭 서브넷]                          [퍼블릭 서브넷]
  |                                      |
 [ALB] <-- 사용 안 됨             [EC2 t4g.nano]
  |                               [보안그룹: 인바운드 전체 차단]
[프라이빗 서브넷]                   [Docker: bridge 컨테이너]
  |                               [EBS: SQLite 파일]
[EC2 과대 프로비전]                  [SSM으로만 접근]
[Docker: bridge]                         |
  |                               [AWS KMS / ETH RPC / 9c Node]
[NAT Gateway] <-- 월 $229
  |
[IGW]
  |
[AWS KMS / ETH RPC / 9c Node]
```

### 비용 비교 표

| 항목 | 현재 (월) | 목표 (월) | 절감액 |
|------|----------|----------|--------|
| EC2 인스턴스 | $211.89 | $3.02 (t4g.nano) | $208.87 |
| NAT Gateway | $229.34 | $0.00 | $229.34 |
| ALB | $74.40 | $0.00 | $74.40 |
| VPC (EIP 등) | $33.50 | ~$0.00 | ~$33.50 |
| EBS 스토리지 | (포함) | $1.60 (gp3 20GB) | - |
| KMS | $6.01 | $6.01 | $0.00 |
| CloudWatch | $1.03 | $1.03 | $0.00 |
| Tax | $55.62 | ~$1.17 | $54.45 |
| **합계** | **$611.80** | **~$12.83** | **~$598.97** |

### 예상 절감액

- **월 절감**: ~$599
- **연 절감**: ~$7,188
- **절감률**: ~98%

---

## 사전 준비 (Phase 0)

Phase 0은 실제 변경 없이 현황을 파악하는 단계입니다. 반드시 완료 후 Phase 1을 진행하세요.

### 0-1. 현재 인프라 인벤토리 확인

```bash
# 실행 중인 EC2 인스턴스 목록
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].{ID:InstanceId,Type:InstanceType,AZ:Placement.AvailabilityZone,PublicIP:PublicIpAddress,PrivateIP:PrivateIpAddress,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table \
  --region ap-northeast-2

# ALB 목록
aws elbv2 describe-load-balancers \
  --query 'LoadBalancers[*].{Name:LoadBalancerName,DNS:DNSName,State:State.Code}' \
  --output table \
  --region ap-northeast-2

# NAT Gateway 목록
aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available" \
  --query 'NatGateways[*].{ID:NatGatewayId,State:State,SubnetId:SubnetId,PublicIP:NatGatewayAddresses[0].PublicIp}' \
  --output table \
  --region ap-northeast-2

# VPC 목록
aws ec2 describe-vpcs \
  --query 'Vpcs[*].{VpcId:VpcId,CIDR:CidrBlock,Name:Tags[?Key==`Name`]|[0].Value,Default:IsDefault}' \
  --output table \
  --region ap-northeast-2

# Elastic IP 목록
aws ec2 describe-addresses \
  --query 'Addresses[*].{AllocationId:AllocationId,PublicIP:PublicIp,AssociatedInstance:InstanceId,AssociationId:AssociationId}' \
  --output table \
  --region ap-northeast-2
```

인벤토리 결과를 아래에 기록하세요:

```
EC2 인스턴스 ID: i-__________________
인스턴스 타입: ______________________
현재 퍼블릭/프라이빗 IP: ____________
ALB ARN: ___________________________
NAT Gateway ID: ____________________
VPC ID: ____________________________
Elastic IP: ________________________
```

### 0-2. SQLite 파일 경로 확인

현재 운영 중인 EC2 인스턴스에 SSM으로 접속하여 확인합니다.

```bash
# SSM 세션 시작
aws ssm start-session --target <INSTANCE_ID> --region ap-northeast-2

# 접속 후: Docker 컨테이너 내 환경변수 확인
docker exec bridge env | grep -E "STORE_PATH|HISTORY"

# 실제 파일 위치 확인
docker exec bridge ls -lh /data/ 2>/dev/null || \
docker exec bridge find / -name "*.db" 2>/dev/null | grep -v proc

# 파일 크기 확인
docker exec bridge sqlite3 /data/exchange_history.db \
  "SELECT COUNT(*) as total_records FROM exchange_histories;"
docker exec bridge sqlite3 /data/monitor_state.db \
  "SELECT * FROM monitor_states;"
```

확인된 SQLite 경로를 기록하세요:

```
MONITOR_STATE_STORE_PATH: ___________
EXCHANGE_HISTORY_STORE_PATH: ________
호스트 마운트 경로: _________________
```

### 0-3. ALB RequestCount 확인 (0인지 검증)

ALB가 실제로 사용되지 않음을 확인합니다.

```bash
# 최근 7일간 ALB RequestCount 확인
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name RequestCount \
  --dimensions Name=LoadBalancer,Value=<ALB_ARN_SUFFIX> \
  --start-time $(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 \
  --statistics Sum \
  --region ap-northeast-2

# ALB 타겟 그룹 헬스 상태 확인
aws elbv2 describe-target-health \
  --target-group-arn <TARGET_GROUP_ARN> \
  --region ap-northeast-2
```

> **체크**: RequestCount가 7일간 0이거나 극히 소수 (헬스체크 정도)여야 합니다.

### 0-4. 현재 EC2 인스턴스 메모리 사용량 확인

```bash
# SSM 세션에서 실행
free -h
# 예시 출력:
#               total        used        free      shared  buff/cache   available
# Mem:          7.5Gi       1.2Gi       5.8Gi        12Mi       500Mi       6.1Gi

# Docker 컨테이너 메모리 사용량
docker stats bridge --no-stream

# 프로세스별 메모리 확인
ps aux | grep node | grep -v grep
```

> **체크 포인트**: Node.js 프로세스의 RSS(Resident Set Size)가 350MB 미만이면 t4g.nano (512MB)로 안전하게 이전 가능합니다.

### 0-5. 현재 Docker 이미지 확인

```bash
# 현재 실행 중인 이미지 태그 확인
docker ps --format "{{.Image}}"

# 또는 docker-compose 파일에서 확인
cat /etc/bridge/docker-compose.yaml
# 또는
cat /home/ec2-user/docker-compose.yaml
```

이미지 정보를 기록하세요:

```
Docker 이미지: _____________________
docker-compose 파일 위치: __________
환경변수 파일 위치: _________________
```

### 0-6. Phase 0 완료 체크리스트

- [ ] EC2 인스턴스 ID, 타입 기록 완료
- [ ] SQLite 파일 경로 확인 완료
- [ ] ALB RequestCount 7일간 0 확인
- [ ] Node.js 메모리 사용량 350MB 미만 확인
- [ ] Docker 이미지 태그 기록 완료
- [ ] 환경변수 파일 위치 기록 완료
- [ ] 스냅샷 백업 생성 완료 (아래 참고)

```bash
# EBS 스냅샷 생성 (이전 시작 전 필수)
VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids <INSTANCE_ID> \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
  --output text --region ap-northeast-2)

aws ec2 create-snapshot \
  --volume-id $VOLUME_ID \
  --description "Pre-migration backup $(date +%Y%m%d)" \
  --region ap-northeast-2
```

---

## Phase 1: ALB 제거

> **위험도**: 낮음
> **예상 소요 시간**: 30분
> **즉시 절감 효과**: $74.40/월
> **서비스 영향**: 없음 (ALB를 통한 트래픽이 없으므로)

### 1-1. ALB 타겟 그룹에서 인스턴스 제거

```bash
# 타겟 그룹 ARN 확인
aws elbv2 describe-target-groups \
  --region ap-northeast-2 \
  --query 'TargetGroups[*].{ARN:TargetGroupArn,Name:TargetGroupName}' \
  --output table

# 타겟 그룹에서 인스턴스 제거
aws elbv2 deregister-targets \
  --target-group-arn <TARGET_GROUP_ARN> \
  --targets Id=<INSTANCE_ID> \
  --region ap-northeast-2

# 제거 확인 (30초 대기 후)
aws elbv2 describe-target-health \
  --target-group-arn <TARGET_GROUP_ARN> \
  --region ap-northeast-2
```

### 1-2. ALB 리스너 삭제

```bash
# 리스너 목록 확인
aws elbv2 describe-listeners \
  --load-balancer-arn <ALB_ARN> \
  --region ap-northeast-2

# 각 리스너 삭제
aws elbv2 delete-listener \
  --listener-arn <LISTENER_ARN> \
  --region ap-northeast-2
```

### 1-3. ALB 삭제

```bash
# ALB 삭제 (리스너 먼저 삭제해야 함)
aws elbv2 delete-load-balancer \
  --load-balancer-arn <ALB_ARN> \
  --region ap-northeast-2

# 삭제 완료 확인 (삭제까지 최대 5분 소요)
aws elbv2 describe-load-balancers \
  --load-balancer-arns <ALB_ARN> \
  --region ap-northeast-2
# 오류가 발생하면 삭제 완료
```

### 1-4. 타겟 그룹 삭제

```bash
aws elbv2 delete-target-group \
  --target-group-arn <TARGET_GROUP_ARN> \
  --region ap-northeast-2
```

### 1-5. Phase 1 검증

```bash
# ALB가 없어졌는지 확인
aws elbv2 describe-load-balancers --region ap-northeast-2

# 브리지 서비스가 정상 동작 중인지 확인
aws ssm start-session --target <INSTANCE_ID> --region ap-northeast-2
# 세션에서:
docker logs bridge --tail 20
docker ps
```

### Phase 1 롤백 방법

ALB를 다시 생성하는 것은 시간이 걸립니다. 하지만 브리지 서비스는 ALB와 직접적인 관련이 없으므로, ALB 삭제 후 브리지 서비스에 문제가 생기면 그것은 무관한 원인입니다.

```bash
# 롤백이 필요한 경우 (실제로 필요할 가능성 낮음)
# 1. ALB 재생성
aws elbv2 create-load-balancer \
  --name bridge-alb \
  --subnets <SUBNET_ID_1> <SUBNET_ID_2> \
  --security-groups <SG_ID> \
  --region ap-northeast-2

# 2. 타겟 그룹 재생성 및 인스턴스 등록 (필요 시)
```

---

## Phase 2: NAT Gateway 제거 + 퍼블릭 서브넷 이전

> **위험도**: 중간
> **예상 소요 시간**: 1–2시간
> **즉시 절감 효과**: ~$229/월 (NAT Gateway) + ~$209/월 (EC2 다운사이징)
> **서비스 중단 시간**: 약 10–15분 (컷오버 시점)

이 Phase는 다음 작업을 포함합니다:
1. 새 t4g.nano 인스턴스를 퍼블릭 서브넷에 프로비저닝
2. SQLite 파일 복사 (브리지 중단 없이 준비)
3. 컷오버: 기존 브리지 중단 → 파일 최종 동기화 → 새 브리지 시작
4. 구 인스턴스 및 NAT Gateway 제거

### 2-1. 퍼블릭 서브넷 ID 확인

```bash
# 퍼블릭 서브넷 확인 (인터넷 게이트웨이 라우팅이 있는 서브넷)
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<VPC_ID>" \
  --query 'Subnets[*].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,Public:MapPublicIpOnLaunch,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table \
  --region ap-northeast-2

# 라우팅 테이블 확인 (0.0.0.0/0 -> igw-xxxx 가 있어야 퍼블릭)
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=<VPC_ID>" \
  --query 'RouteTables[*].{ID:RouteTableId,Routes:Routes[*].{Dest:DestinationCidrBlock,GW:GatewayId}}' \
  --output json \
  --region ap-northeast-2
```

### 2-2. 새 EC2 보안 그룹 생성

```bash
# 인바운드 없는 보안 그룹 생성
SG_ID=$(aws ec2 create-security-group \
  --group-name "bridge-ng-sg" \
  --description "NineChronicles Bridge - no inbound" \
  --vpc-id <VPC_ID> \
  --region ap-northeast-2 \
  --query 'GroupId' \
  --output text)

echo "Security Group ID: $SG_ID"

# 인바운드 규칙: 없음 (기본적으로 모두 거부)
# 아웃바운드 규칙: HTTPS/HTTP 허용 (기본값이 all allow이므로 별도 설정 불필요)

# 태그 추가
aws ec2 create-tags \
  --resources $SG_ID \
  --tags Key=Name,Value=bridge-ng-sg \
  --region ap-northeast-2
```

### 2-3. IAM 인스턴스 프로파일 생성 (SSM 접근용)

```bash
# IAM 역할 생성
aws iam create-role \
  --role-name BridgeEC2Role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

# SSM 정책 연결
aws iam attach-role-policy \
  --role-name BridgeEC2Role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

# S3 백업 정책 연결 (백업 버킷이 있는 경우)
# aws iam attach-role-policy \
#   --role-name BridgeEC2Role \
#   --policy-arn <BACKUP_POLICY_ARN>

# 인스턴스 프로파일 생성
aws iam create-instance-profile \
  --instance-profile-name BridgeEC2Profile

aws iam add-role-to-instance-profile \
  --instance-profile-name BridgeEC2Profile \
  --role-name BridgeEC2Role
```

### 2-4. 새 t4g.nano 인스턴스 프로비저닝

```bash
# 최신 Amazon Linux 2023 ARM64 AMI ID 확인 (ap-northeast-2)
AMI_ID=$(aws ec2 describe-images \
  --owners amazon \
  --filters \
    "Name=name,Values=al2023-ami-*-arm64" \
    "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text \
  --region ap-northeast-2)

echo "AMI ID: $AMI_ID"

# User Data 스크립트 작성
cat > /tmp/userdata.sh << 'USERDATA'
#!/bin/bash
set -e

# 시스템 업데이트
yum update -y

# Docker 설치
yum install -y docker
systemctl enable docker
systemctl start docker

# Docker Compose 설치
curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-linux-aarch64" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# SSM Agent (Amazon Linux 2023에는 기본 설치됨)
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# 데이터 디렉토리 생성
mkdir -p /data
chmod 755 /data

# SQLite 설치 (백업 스크립트용)
yum install -y sqlite

echo "Setup completed" > /tmp/setup-done
USERDATA

# EC2 인스턴스 생성
NEW_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t4g.nano \
  --key-name <YOUR_KEY_NAME> \
  --security-group-ids $SG_ID \
  --subnet-id <PUBLIC_SUBNET_ID> \
  --associate-public-ip-address \
  --iam-instance-profile Name=BridgeEC2Profile \
  --block-device-mappings '[{
    "DeviceName": "/dev/xvda",
    "Ebs": {
      "VolumeSize": 20,
      "VolumeType": "gp3",
      "DeleteOnTermination": false,
      "Encrypted": true
    }
  }]' \
  --user-data file:///tmp/userdata.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=bridge-ng}]' \
  --region ap-northeast-2 \
  --query 'Instances[0].InstanceId' \
  --output text)

echo "New Instance ID: $NEW_INSTANCE_ID"

# 인스턴스가 running 상태가 될 때까지 대기
aws ec2 wait instance-running \
  --instance-ids $NEW_INSTANCE_ID \
  --region ap-northeast-2

echo "Instance is running"
```

### 2-5. 새 인스턴스 초기 설정 확인

```bash
# SSM 세션 준비 대기 (1–2분 소요)
sleep 60

# 새 인스턴스 SSM 접속
aws ssm start-session --target $NEW_INSTANCE_ID --region ap-northeast-2

# 접속 후 확인:
docker --version
systemctl status docker
ls /data/
cat /tmp/setup-done  # "Setup completed" 확인
```

### 2-6. 환경변수 파일 복사

기존 인스턴스에서 환경변수를 가져와 새 인스턴스에 설정합니다.

```bash
# === 기존 인스턴스에서 실행 ===
# 환경변수 파일 내용 확인 (민감 정보 포함, 출력 주의)
cat /etc/bridge/.env

# === 로컬 또는 새 인스턴스에서 실행 ===
# S3를 통한 안전한 전달 방법 (권장)
aws s3 cp /etc/bridge/.env s3://<SECURE_BUCKET>/bridge-config/.env \
  --sse aws:kms

# 새 인스턴스 SSM 세션에서:
mkdir -p /etc/bridge
aws s3 cp s3://<SECURE_BUCKET>/bridge-config/.env /etc/bridge/.env
chmod 600 /etc/bridge/.env

# S3에서 즉시 삭제
aws s3 rm s3://<SECURE_BUCKET>/bridge-config/.env
```

### 2-7. docker-compose 파일 설정

```bash
# 새 인스턴스 SSM 세션에서:
cat > /etc/bridge/docker-compose.yaml << 'EOF'
version: '3'
services:
  bridge:
    image: <현재_사용_중인_이미지>
    container_name: bridge
    volumes:
      - /data:/data
    env_file:
      - /etc/bridge/.env
    restart: always
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
EOF
```

### 2-8. SQLite 파일 사전 복사 (브리지 실행 중)

> 이 단계는 브리지를 중단하지 않고 수행합니다. 실시간 변경 중인 파일이므로 최신 버전은 컷오버 시 다시 복사합니다.

```bash
# === 기존 인스턴스에서 실행 ===
# S3를 통해 SQLite 파일 전송 (sqlite3 .backup 명령으로 일관성 보장)
docker exec bridge sqlite3 /data/exchange_history.db \
  ".backup /tmp/exchange_history_pre.db"
docker exec bridge sqlite3 /data/monitor_state.db \
  ".backup /tmp/monitor_state_pre.db"

# 호스트로 복사 (경로는 실제 마운트 경로에 맞게 조정)
docker cp bridge:/tmp/exchange_history_pre.db /tmp/
docker cp bridge:/tmp/monitor_state_pre.db /tmp/

# S3 업로드
aws s3 cp /tmp/exchange_history_pre.db s3://<SECURE_BUCKET>/migration/exchange_history_pre.db --sse aws:kms
aws s3 cp /tmp/monitor_state_pre.db s3://<SECURE_BUCKET>/migration/monitor_state_pre.db --sse aws:kms

# === 새 인스턴스 SSM 세션에서 실행 ===
aws s3 cp s3://<SECURE_BUCKET>/migration/exchange_history_pre.db /data/exchange_history.db
aws s3 cp s3://<SECURE_BUCKET>/migration/monitor_state_pre.db /data/monitor_state.db
ls -lh /data/
```

### 2-9. 새 인스턴스에서 브리지 사전 검증 (트래픽 없이)

컷오버 전에 설정이 올바른지 확인합니다.

```bash
# 새 인스턴스 SSM 세션에서:
cd /etc/bridge

# Docker 이미지 pull
docker compose pull

# 컨테이너 시작 시도 (에러가 있는지 확인)
docker compose up -d

# 로그 확인 (정상 시작되는지)
sleep 10
docker logs bridge --tail 30

# KMS 연결 확인 (로그에 kmsAddress가 출력되어야 함)
docker logs bridge 2>&1 | grep -E "0x[0-9a-fA-F]{40}|Error|error"
```

> **중요**: 이 시점에 브리지 2개가 동시에 실행 중입니다. SQLite 파일이 구 인스턴스에만 있으므로 신규 인스턴스의 브리지는 이전 상태의 파일로 실행됩니다. 실제 트랜잭션 처리는 **컷오버 이후부터** 신규 인스턴스가 담당합니다. 짧은 시간 동안 중복 처리 가능성이 있으나, `exchange_history.db`의 `tx_id` 기반 중복 방지 로직으로 실제 중복 송금은 발생하지 않습니다.

### 2-10. 컷오버 실행

> **이 단계부터 서비스 중단이 발생합니다 (약 5–10분)**
> 가급적 트랜잭션이 없는 시간대 (예: 새벽 시간) 에 진행하세요.

```bash
# === STEP 1: 기존 브리지 중단 ===
# 기존 인스턴스 SSM 세션에서:
docker stop bridge
echo "기존 브리지 중단: $(date)"

# === STEP 2: 최종 SQLite 파일 동기화 ===
# 기존 인스턴스 SSM 세션에서:
sqlite3 /data/exchange_history.db ".backup /tmp/exchange_history_final.db"
sqlite3 /data/monitor_state.db ".backup /tmp/monitor_state_final.db"

aws s3 cp /tmp/exchange_history_final.db \
  s3://<SECURE_BUCKET>/migration/exchange_history_final.db --sse aws:kms
aws s3 cp /tmp/monitor_state_final.db \
  s3://<SECURE_BUCKET>/migration/monitor_state_final.db --sse aws:kms

echo "최종 파일 S3 업로드 완료: $(date)"

# === STEP 3: 새 인스턴스에 최종 파일 적용 ===
# 새 인스턴스 SSM 세션에서:
# 기존에 사전 복사한 파일 제거
docker stop bridge 2>/dev/null || true
rm -f /data/exchange_history.db /data/monitor_state.db

# 최신 파일 다운로드
aws s3 cp s3://<SECURE_BUCKET>/migration/exchange_history_final.db /data/exchange_history.db
aws s3 cp s3://<SECURE_BUCKET>/migration/monitor_state_final.db /data/monitor_state.db
ls -lh /data/

# === STEP 4: 새 인스턴스 브리지 시작 ===
cd /etc/bridge
docker compose up -d

sleep 15
docker logs bridge --tail 30
echo "새 브리지 시작: $(date)"
```

### 2-11. 컷오버 검증

```bash
# 새 인스턴스 SSM 세션에서:

# 1. 컨테이너 상태 확인
docker ps

# 2. KMS 주소 출력 확인 (기존과 동일해야 함)
docker logs bridge 2>&1 | head -20

# 3. SQLite 레코드 수 확인 (기존과 동일해야 함)
sqlite3 /data/exchange_history.db \
  "SELECT COUNT(*) FROM exchange_histories; SELECT MAX(timestamp) FROM exchange_histories;"

sqlite3 /data/monitor_state.db "SELECT * FROM monitor_states;"

# 4. 오류 없이 폴링 중인지 확인 (1–2분 로그 관찰)
docker logs bridge -f
# Ctrl+C로 종료
```

### 2-12. Elastic IP 이전 (선택사항)

외부에서 이 인스턴스의 IP를 참조하는 곳이 있다면 Elastic IP를 이전합니다.

```bash
# 기존 Elastic IP 분리
aws ec2 disassociate-address \
  --association-id <ASSOCIATION_ID> \
  --region ap-northeast-2

# 새 인스턴스에 연결
aws ec2 associate-address \
  --instance-id $NEW_INSTANCE_ID \
  --allocation-id <ALLOCATION_ID> \
  --region ap-northeast-2
```

### 2-13. NAT Gateway 제거

신규 인스턴스가 안정적으로 동작함을 확인한 후 (최소 30분 관찰) NAT Gateway를 제거합니다.

```bash
# NAT Gateway 삭제
aws ec2 delete-nat-gateway \
  --nat-gateway-id <NAT_GATEWAY_ID> \
  --region ap-northeast-2

# 삭제 상태 확인 (완전 삭제까지 수 분 소요)
aws ec2 describe-nat-gateways \
  --nat-gateway-ids <NAT_GATEWAY_ID> \
  --query 'NatGateways[0].State' \
  --output text \
  --region ap-northeast-2
# "deleted" 출력 시 완료

# NAT Gateway용 Elastic IP 해제 (별도 EIP가 있는 경우)
aws ec2 release-address \
  --allocation-id <NAT_EIP_ALLOCATION_ID> \
  --region ap-northeast-2
```

### 2-14. 기존 인스턴스 종료

```bash
# 최소 24시간 관찰 후 기존 인스턴스 종료
aws ec2 terminate-instances \
  --instance-ids <OLD_INSTANCE_ID> \
  --region ap-northeast-2
```

### Phase 2 롤백 방법

컷오버 후 문제 발생 시:

```bash
# 1. 신규 브리지 중단
docker stop bridge

# 2. 기존 브리지 재시작
# 기존 인스턴스 SSM 세션에서:
docker start bridge

# NAT Gateway가 아직 살아있다면 (24시간 이내): 즉시 복원 가능
# NAT Gateway가 삭제된 경우:
# - 기존 인스턴스를 퍼블릭 서브넷으로 이동하거나
# - 신규 NAT Gateway 생성 (요금 재발생)
```

---

## Phase 3: 정리 및 검증

> **위험도**: 없음 (정리 작업)
> **예상 소요 시간**: 30분

### 3-1. 불필요한 VPC 리소스 정리

```bash
# 사용하지 않는 보안 그룹 확인
aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=<VPC_ID>" \
  --query 'SecurityGroups[*].{ID:GroupId,Name:GroupName,InUse:length(IpPermissions)}' \
  --output table \
  --region ap-northeast-2

# 빈 서브넷 확인 (인스턴스 없는 프라이빗 서브넷)
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=<VPC_ID>" \
  --query 'Subnets[*].{ID:SubnetId,AZ:AvailabilityZone,Available:AvailableIpAddressCount}' \
  --output table \
  --region ap-northeast-2

# 사용하지 않는 Elastic IP 확인 (인스턴스 미연결 시 요금 발생)
aws ec2 describe-addresses \
  --query 'Addresses[?AssociationId==`null`].{AllocationId:AllocationId,PublicIP:PublicIp}' \
  --output table \
  --region ap-northeast-2

# 미연결 EIP 해제
aws ec2 release-address \
  --allocation-id <UNASSOCIATED_EIP_ALLOCATION_ID> \
  --region ap-northeast-2
```

### 3-2. EC2 Auto Recovery 설정

```bash
# Auto Recovery CloudWatch Alarm 생성
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
  --dimensions "Name=InstanceId,Value=$NEW_INSTANCE_ID" \
  --alarm-actions "arn:aws:automate:ap-northeast-2:ec2:recover" \
  --treat-missing-data notBreaching \
  --region ap-northeast-2
```

### 3-3. S3 백업 설정

```bash
# 새 인스턴스 SSM 세션에서:

# 백업 스크립트 생성
cat > /usr/local/bin/backup-sqlite.sh << 'SCRIPT'
#!/bin/bash
set -e

BACKUP_BUCKET="bridge-backup-bucket"
BACKUP_PREFIX="sqlite/$(date +%Y/%m/%d)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

sqlite3 /data/monitor_state.db ".backup /tmp/monitor_state_${TIMESTAMP}.db"
sqlite3 /data/exchange_history.db ".backup /tmp/exchange_history_${TIMESTAMP}.db"

aws s3 cp /tmp/monitor_state_${TIMESTAMP}.db \
  s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/monitor_state_${TIMESTAMP}.db \
  --region ap-northeast-2

aws s3 cp /tmp/exchange_history_${TIMESTAMP}.db \
  s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/exchange_history_${TIMESTAMP}.db \
  --region ap-northeast-2

rm -f /tmp/monitor_state_${TIMESTAMP}.db /tmp/exchange_history_${TIMESTAMP}.db
echo "Backup completed: ${TIMESTAMP}"
SCRIPT

chmod +x /usr/local/bin/backup-sqlite.sh

# Cron 설정 (매일 오전 3시)
echo "0 3 * * * root /usr/local/bin/backup-sqlite.sh >> /var/log/bridge-backup.log 2>&1" \
  > /etc/cron.d/bridge-backup

# 즉시 백업 테스트
/usr/local/bin/backup-sqlite.sh
```

### 3-4. 비용 모니터링 설정

```bash
# AWS Budgets 알람 설정 (월 $20 초과 시 경보)
aws budgets create-budget \
  --account-id <AWS_ACCOUNT_ID> \
  --budget '{
    "BudgetName": "bridge-monthly-budget",
    "BudgetLimit": {"Amount": "20", "Unit": "USD"},
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }' \
  --notifications-with-subscribers '[{
    "Notification": {
      "NotificationType": "ACTUAL",
      "ComparisonOperator": "GREATER_THAN",
      "Threshold": 80,
      "ThresholdType": "PERCENTAGE"
    },
    "Subscribers": [{
      "SubscriptionType": "EMAIL",
      "Address": "<ALERT_EMAIL>"
    }]
  }]'
```

### 3-5. 운영 확인 체크리스트

마이그레이션 완료 후 1주일 동안 다음 항목을 주기적으로 확인하세요.

```bash
# 브리지 상태 확인 (매일)
docker ps --filter name=bridge
docker logs bridge --tail 20 --timestamps

# 거래 처리 확인
sqlite3 /data/exchange_history.db \
  "SELECT network, COUNT(*), MAX(timestamp) FROM exchange_histories GROUP BY network;"

# 디스크 사용량 확인
df -h /data
ls -lh /data/*.db

# 메모리 사용량 확인
free -h
docker stats bridge --no-stream
```

---

## 긴급 롤백 절차

### Phase 1 롤백 (ALB 복원)

ALB 삭제는 되돌릴 수 없지만, 브리지 서비스에 영향이 없으므로 롤백이 필요한 경우는 없습니다.

### Phase 2 롤백 (기존 인스턴스로 복원)

**기존 인스턴스가 아직 실행 중인 경우 (컷오버 후 24시간 이내):**

```bash
# 1. 신규 브리지 중단
aws ssm start-session --target $NEW_INSTANCE_ID --region ap-northeast-2
# 세션에서:
docker stop bridge

# 2. 기존 브리지 재시작
aws ssm start-session --target <OLD_INSTANCE_ID> --region ap-northeast-2
# 세션에서:
docker start bridge
docker logs bridge --tail 20

# 3. 상태 확인 후 완료
```

**기존 인스턴스가 종료된 경우:**

```bash
# 1. 신규 인스턴스에서 계속 운영 (롤백 불필요)
# 2. 문제가 있다면 S3 백업에서 SQLite 복원
aws s3 ls s3://bridge-backup-bucket/sqlite/ --recursive | sort | tail -10

aws s3 cp s3://bridge-backup-bucket/sqlite/<DATE>/exchange_history_<TIMESTAMP>.db \
  /data/exchange_history.db

docker restart bridge
```

**NAT Gateway 긴급 복원이 필요한 경우:**

```bash
# NAT Gateway 재생성 (비용 재발생)
EIP_ALLOC_ID=$(aws ec2 allocate-address \
  --domain vpc \
  --query 'AllocationId' \
  --output text \
  --region ap-northeast-2)

aws ec2 create-nat-gateway \
  --subnet-id <PUBLIC_SUBNET_ID> \
  --allocation-id $EIP_ALLOC_ID \
  --region ap-northeast-2

# 프라이빗 서브넷 라우팅 테이블 업데이트
aws ec2 replace-route \
  --route-table-id <PRIVATE_RT_ID> \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id <NEW_NAT_ID> \
  --region ap-northeast-2
```

---

## 전체 마이그레이션 체크리스트

### Phase 0 — 사전 준비

- [ ] AWS CLI 설정 및 권한 확인 (`aws sts get-caller-identity`)
- [ ] 현재 EC2 인스턴스 ID 기록
- [ ] 현재 Docker 이미지 태그 기록
- [ ] 환경변수 파일 위치 확인 및 내용 백업
- [ ] SQLite 파일 경로 확인 (`MONITOR_STATE_STORE_PATH`, `EXCHANGE_HISTORY_STORE_PATH`)
- [ ] ALB RequestCount 7일간 0 확인
- [ ] Node.js 메모리 사용량 350MB 미만 확인
- [ ] EBS 스냅샷 생성 완료
- [ ] 팀 공지 완료 (작업 시간 안내)

### Phase 1 — ALB 제거

- [ ] ALB 타겟 그룹에서 인스턴스 제거
- [ ] ALB 리스너 삭제
- [ ] ALB 삭제 완료 확인
- [ ] 타겟 그룹 삭제
- [ ] 브리지 서비스 정상 동작 확인

### Phase 2 — 신규 인스턴스 프로비저닝

- [ ] 퍼블릭 서브넷 ID 확인
- [ ] 새 보안 그룹 생성 (인바운드 없음)
- [ ] IAM 인스턴스 프로파일 생성 (SSM 권한)
- [ ] t4g.nano 인스턴스 생성 완료
- [ ] Docker, Docker Compose 설치 확인
- [ ] SSM Session Manager 접속 확인
- [ ] 환경변수 파일 복사 완료
- [ ] docker-compose.yaml 설정 완료
- [ ] SQLite 파일 사전 복사 완료
- [ ] 새 인스턴스에서 브리지 사전 실행 및 KMS 연결 확인

### Phase 2 — 컷오버

- [ ] 컷오버 시간 결정 (트래픽 낮은 시간대)
- [ ] 기존 브리지 중단
- [ ] 최종 SQLite 파일 S3 업로드
- [ ] 새 인스턴스에 최종 파일 다운로드
- [ ] 새 브리지 시작
- [ ] KMS 주소 일치 확인
- [ ] SQLite 레코드 수 일치 확인
- [ ] 30분 이상 정상 동작 관찰
- [ ] NAT Gateway 삭제
- [ ] 기존 인스턴스 24시간 유지 후 종료

### Phase 3 — 정리

- [ ] 불필요한 보안 그룹 삭제
- [ ] 미연결 Elastic IP 해제
- [ ] EC2 Auto Recovery 알람 설정
- [ ] S3 백업 스크립트 설치 및 테스트
- [ ] Cron 백업 작동 확인
- [ ] AWS Budgets 알람 설정
- [ ] CloudWatch 대시보드 설정
- [ ] 마이그레이션 완료 팀 공지
- [ ] 1주일 후 비용 확인 (AWS Cost Explorer)

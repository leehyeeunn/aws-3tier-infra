# AWS 3-Tier 기반 보안 격리 인프라 구축 및 자동화 파이프라인

FastAPI 백엔드 서비스의 외부 공격 표면(Attack Surface) 차단을 위해 Multi-AZ 3-Tier 네트워크를 설계하고, 보안 그룹 체이닝·모니터링 알람·Docker 컨테이너화 및 OIDC 기반 CI 자동화를 구축한 인프라 프로젝트입니다.

---

## 1. 아키텍처 개요

```text
[Client / Internet]
       │ (HTTP 80)
       ▼
[Internet Gateway (IGW)]
       │
┌──────┼────────────────────────────────────────────────────────────────────────┐
│ VPC (10.0.0.0/16)                                                             │
│      │                                                                        │
│      ▼                                                                        │
│  [Public Subnets (2a: 10.0.0.0/20, 2b: 10.0.16.0/20)]                         │
│    ├─ Application Load Balancer (ALB) ──────────────────────────┐             │
│    └─ Bastion Host (SSH 22: My IP Only)                         │             │
│            │ (SSH ProxyJump 터널링)                             │             │
│            ▼                                                    │             │
│  [Private Subnets (2a: 10.0.128.0/20, 2b: 10.0.144.0/20)]       │             │
│    └─ App Server (Docker: FastAPI Container) ◄──────────────────┘             │
│            │                                    (alb-sg -> app-server-sg)     │
│            │ (Port 3306)                                                      │
│            ▼                                                                  │
│  [Private DB Subnets (Dedicated)]                                             │
│    └─ RDS MySQL (Single-AZ Free-Tier)                                         │
│                                                                               │
│  [CloudWatch & SNS] ◄── 5XX Metrics Alarm (실시간 이메일 경보)                 │
└───────────────────────────────────────────────────────────────────────────────┘
---

## 2. 주요 기술 스택
- Cloud Infrastructure: AWS (VPC, Subnet, IGW, Route Table, EC2, ALB, RDS MySQL, CloudWatch, SNS, IAM, ECR)

- OS & Server: Ubuntu 24.04 LTS, Docker, Linux systemd 데몬

- Backend Runtime: Python 3.11, FastAPI, Uvicorn

- CI/CD & IaC: GitHub Actions, AWS OIDC Federation, Terraform

## 3. 핵심 엔지니어링 의사결정 (How)
### 1. 네트워크 격리 및 공격 표면 차단
기본 VPC를 사용하지 않고 10.0.0.0/16 대역의 커스텀 VPC를 생성하여 2개 가용영역(2a, 2b)에 Public 서브넷과 Private 서브넷을 각각 4,096개(/20) 규모로 분할 배치했습니다.

외부 인터넷 통신이 필요한 ALB와 Bastion Host만 Public 서브넷에 전진 배치하고, 실제 비즈니스 로직(FastAPI)과 데이터베이스(RDS)는 아웃바운드 인터넷이 차단된 Private 서브넷에 격리했습니다.

관리자 접근은 Bastion Host의 22번 포트 인바운드를 본인 공인 IP(My IP)로 한정하고, ProxyJump를 통한 터널링 세션으로만 Private EC2에 진입하도록 단일 진입로를 구성했습니다.

### 2. 보안 그룹 체이닝 (Security Group Chaining)
IP 대역 기반 규칙 설정을 배제하고 보안 그룹 ID 간의 참조 체이닝을 적용했습니다.

ALB SG: 외부 전세계(0.0.0.0/0) HTTP(80) / HTTPS(443) 허용

App EC2 SG: 소스를 alb-sg ID로 지정하여 8000번 포트만 인바운드 허용

RDS DB SG: 소스를 app-server-sg ID로 지정하여 3306번 포트만 인바운드 허용

외부에서 RDS 엔드포인트 직접 호출 시 타임아웃(TimedOut/False)으로 차단되고, Private EC2 내부에서만 nc -zv 명령어로 3306 포트 통신 성공(succeeded!)을 검증했습니다.

### 3. 애플리케이션 안정화 및 컨테이너 패키징
1단계로 호스트 OS 내에서 systemd 서비스 데몬(Restart=always, RestartSec=5s)으로 FastAPI 프로세스를 관리하여 비정상 종료 시 즉각적인 자가 복구(Self-healing)를 보장했습니다.

2단계로 호스트 종속성을 제거하기 위해 경량 베이스 이미지(python:3.11-slim) 기반의 Dockerfile을 작성하여 컨테이너 런타임 환경을 표준화했습니다.

### 4. 보안 표준 준수 CI 자동화 (GitHub Actions & OIDC)
보안 취약점인 장기 IAM Access Key 하드코딩을 배제하고, AWS IAM과 GitHub 간 OIDC(OpenID Connect) 연동을 구성했습니다.

불변 주체 식별자(Immutable Subject Claims, sub: repo-id) 기반의 IAM 신뢰 정책(Trust Policy)을 적용하여 안전한 임시 보안 토큰(sts:AssumeRoleWithWebIdentity)으로 Amazon ECR 프라이빗 저장소에 도커 이미지를 자동 빌드·푸시하는 CI 파이프라인을 완성했습니다.

## 4. 실제 트러블슈팅 및 장애 복구 (Deep Dive)
[Issue 1] ALB 대상 그룹 상태 비정상 및 502 Bad Gateway 대응
현상: ALB 엔드포인트 호출 시 브라우저에서 502 Bad Gateway가 출력되고 Target Group 헬스체크가 Unhealthy로 지속됨.

원인 추적: 백엔드 EC2 터미널 접속 후 curl localhost:8000/health는 정상 응답했으나, 프로세스 실행 바인드가 127.0.0.1:8000(Loopback)으로 설정되어 외부 네트워크 인터페이스(eth0)로 유입되는 ALB 헬스체크 트래픽을 리슨하지 못함.

해결: 바인딩 주소를 모든 인터페이스 수신을 뜻하는 0.0.0.0:8000으로 수정 후 재기동하여 즉각 Healthy 전환 및 200 OK 복구 확인.

[Issue 2] Private 서브넷 폐쇄망 환경의 패키지 통신 단절
현상: Private EC2 내부에서 패키지 설치(apt update) 시 101: Network is unreachable 및 커넥션 타임아웃 발생.

원인 추적: Private 라우팅 테이블에 Internet Gateway가 존재하지 않는 격리망 특성상 외부 패키지 저장소와의 아웃바운드 경로 부재.

해결 (FinOps 의사결정): 고정비(월 $32+)를 발생시키는 NAT Gateway를 무작정 증설하지 않고, Bastion Host에서 의존성 바이너리를 빌드/압축하여 사설망(SCP)으로 반입하는 오프라인 아티팩트 배포 방식을 적용하여 $0 비용으로 격리 배포 완료.

[Issue 3] ECR 이미지 덮어쓰기 시 불변 태그 오류 차단
현상: GitHub Actions 워크플로우 실행 중 The image tag 'latest' already exists and cannot be overwritten 에러로 파이프라인 중단.

원인 추적: ECR 리포지토리의 기본 옵션인 Tag Immutability(태그 불변성) 설정으로 인해 동일 태그(latest) 덮어쓰기가 AWS 정책상 차단됨.

해결: ECR 설정에서 태그 변경 가능(Mutable)으로 전환 후 재실행하여 빌드 및 태그 푸시 자동화 성공.

## 5. 비용 최적화 (FinOps) 및 IaC 검증
0원 인프라 통제: 월 고정비가 상시 발생하는 NAT Gateway를 배제하고, 프리티어 규격(t3.micro, db.t3.micro 8GB)만 통제 사용하여 AWS 청구 비용 $0.00을 유지했습니다.

IaC(Terraform) 수명주기 실증: 콘솔로 구축했던 VPC, IGW, Public/Private 서브넷 구조를 main.tf HCL 코드로 선언하여 terraform plan 및 terraform apply를 통한 원클릭 인프라 프로비저닝을 검증하고, 검증 직후 terraform destroy로 잔여 리소스를 정리했습니다.

Teardown 원칙: 배포 검증 완료 후 유료 전환 가능성이 있는 ALB, RDS, EC2 인스턴스를 즉각 정지/회수하여 불필요한 클라우드 지출을 방지했습니다[cite: 1, 2].

## 6. 저장소 디렉터리 구조

├── .github/
│   └── workflows/
│       └── deploy.yaml         * OIDC 기반 ECR 자동 빌드/푸시 CI 파이프라인
├── app/
│   ├── main.py                 * FastAPI 백엔드 엔드포인트 (/health)
│   ├── requirements.txt        * 종속성 패키지 명세
│   └── Dockerfile              * 경량 Base Image 기반 컨테이너 규격서
├── terraform/
│   └── main.tf                 * VPC, IGW, 서브넷 프로비저닝 HCL 코드
└── README.md                   * 인프라 아키텍처 및 트러블슈팅 문서


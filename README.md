# AWS 3-Tier 기반 보안 격리 인프라 구축 및 자동화

AWS VPC 내부에 **ALB–Private EC2–RDS로 구성된 3-Tier 인프라**를 구축하고, 백엔드 서버를 인터넷에서 직접 접근할 수 없도록 격리한 프로젝트입니다.

보안 그룹 참조 체이닝, Bastion Host 기반 관리 접근, CloudWatch 모니터링, Docker 컨테이너화, GitHub Actions OIDC 인증 및 Terraform을 적용하여 **네트워크 보안부터 GitHub Actions + OIDC 기반의 ECR 자동 빌드/푸시(CI)까지의 인프라 구축 과정을 직접 경험하고 검증**했습니다.


## 1. 프로젝트 소개

### 프로젝트 목표

FastAPI 백엔드 서비스를 AWS 환경에 배포하면서 다음과 같은 인프라 구성을 직접 설계하고 구현했습니다.

* 외부 요청과 애플리케이션 서버의 네트워크 분리
* 인터넷에서 직접 접근할 수 없는 Private EC2 구성
* ALB를 통한 애플리케이션 접근 경로 제한
* 보안 그룹 참조를 활용한 계층별 접근 제어
* 컨테이너 기반 애플리케이션 실행 환경 구성
* 장기 AWS Access Key 없이 동작하는 CI 인증 방식 적용
* CloudWatch와 SNS를 활용한 오류 모니터링
* Terraform을 활용한 인프라 코드화

### 프로젝트 핵심

> **인터넷에 직접 노출되는 리소스를 최소화하고, 필요한 통신만 허용하는 AWS 인프라를 구축하는 것**을 핵심 목표로 삼았습니다.


## 2. 아키텍처
<img width="1024" height="559" alt="image" src="https://github.com/user-attachments/assets/bc797dcf-2f7c-44a0-81a5-a72548f03ada" />

```

### 네트워크 구성

| 구분                 | 구성                                   |
| ------------------ | ------------------------------------ |
| VPC                | `10.0.0.0/16`                        |
| Availability Zone  | `ap-northeast-2a`, `ap-northeast-2b` |
| Public Subnet      | `10.0.0.0/20`, `10.0.16.0/20`        |
| Private App Subnet | `10.0.128.0/20`, `10.0.144.0/20`     |
| Public 리소스         | ALB, Bastion Host                    |
| Private 리소스        | App Server EC2, RDS                  |
| Database           | RDS MySQL Single-AZ                  |
| 외부 접근 경로           | Internet → ALB → App Server          |
| 관리자 접근 경로          | Local PC → Bastion → Private EC2     |

> Public / Private 네트워크를 분리하고, 실제 애플리케이션과 데이터베이스는 인터넷에서 직접 접근할 수 없는 Private 영역에 배치했습니다.


## 3. 주요 기술 스택

### Cloud Infrastructure

* AWS VPC
* Subnet
* Internet Gateway
* Route Table
* EC2
* Application Load Balancer
* RDS MySQL
* CloudWatch
* SNS
* IAM
* ECR

### OS & Application

* Ubuntu 24.04 LTS
* Linux
* Docker
* Python 3.11
* FastAPI
* Uvicorn

### CI/CD & IaC

* GitHub Actions
* AWS OIDC Federation
* Terraform
* HCL


## 4. 주요 구현 내용

### 4.1 Public / Private 네트워크 분리

VPC를 직접 생성하고 2개의 Availability Zone에 Public 및 Private Subnet을 구성했습니다.

인터넷과 통신이 필요한 리소스와 외부에서 직접 접근할 필요가 없는 리소스를 분리하여 네트워크 접근 범위를 제한했습니다.

#### 구성

* Public Subnet

  * Application Load Balancer
  * Bastion Host

* Private App Subnet

  * FastAPI가 실행되는 EC2

* Private DB Subnet

  * RDS MySQL

외부 요청은 ALB를 통해서만 애플리케이션 서버로 전달되도록 구성하고, EC2와 RDS는 인터넷에서 직접 접근할 수 없도록 배치했습니다.


### 4.2 보안 그룹 참조 체이닝

IP 대역을 직접 허용하는 방식 대신, **상위 계층의 보안 그룹을 다음 계층의 인바운드 소스로 지정**했습니다.

```text
Internet
   │
   ▼
ALB
   │ alb-sg
   ▼
App Server
   │ app-server-sg
   ▼
RDS
   │
   ▼
rds-sg
```

#### 접근 제어

* ALB → App Server

  * `alb-sg`를 소스로 허용

* App Server → RDS

  * `app-server-sg`를 소스로 허용

* 외부 PC → RDS

  * 직접 접근 차단

이를 통해 특정 IP 대역 전체를 허용하기보다, **실제로 허가된 리소스 간 통신만 허용하는 방식**으로 접근 제어를 구성했습니다.


### 4.3 Bastion Host 기반 Private EC2 접근

Private EC2에는 외부에서 직접 SSH 접속할 수 없도록 구성했습니다.

관리자 접근이 필요한 경우 Public Subnet의 Bastion Host를 단일 진입점으로 사용했습니다.

```text
Local PC
   │
   │ SSH :22
   ▼
Bastion Host
   │
   │ SSH ProxyJump
   ▼
Private EC2
```

Bastion Host의 SSH 인바운드는 **관리자 공인 IP만 허용**하도록 제한했습니다.

또한 Private EC2에 별도의 비밀키를 저장하지 않고, 로컬 OpenSSH의 `ProxyJump (-J)` 옵션을 활용해 Private 서버에 접근했습니다.


### 4.4 Private 환경에서의 배포 방식

Private EC2에는 NAT Gateway를 연결하지 않아 외부 인터넷 저장소에 직접 접근할 수 없는 환경으로 구성했습니다.

이로 인해 Private 서버에서 외부 패키지 저장소나 Docker Registry에 직접 접근하는 방식은 사용할 수 없었습니다.

따라서 초기 배포 단계에서는 Bastion Host에서 필요한 파일과 패키지를 준비한 뒤, SCP를 통해 Private EC2로 전달하는 방식을 사용했습니다.

```text
Bastion Host
   │
   │ SCP
   ▼
Private EC2
   │
   ▼
Docker Container 실행
```

#### 선택 이유

NAT Gateway를 사용하면 Private Subnet에서도 외부 인터넷 접근이 가능하지만, 시간당 비용과 데이터 처리 비용이 발생합니다.

이번 프로젝트에서는 학습 및 실습 환경의 비용을 고려하여 NAT Gateway를 사용하지 않는 대신, **사설망 내 파일 반입 방식으로 배포하는 구조를 선택했습니다.**


### 4.5 Docker 기반 FastAPI 실행

FastAPI 애플리케이션을 Docker 이미지로 패키징하여 실행 환경의 종속성을 줄였습니다.

#### 주요 구성

* Python 3.11 기반 실행 환경
* `requirements.txt`를 통한 의존성 관리
* Dockerfile을 통한 이미지 빌드
* Uvicorn을 활용한 FastAPI 실행
* `0.0.0.0:8000` 바인딩

컨테이너 내부에서 애플리케이션을 실행하고, ALB에서 전달된 요청을 App Server가 수신할 수 있도록 구성했습니다.


### 4.6 OIDC 기반 GitHub Actions CI 자동화

GitHub Actions에서 AWS Access Key를 직접 저장하지 않고, **OIDC를 활용해 AWS IAM Role을 임시로 Assume하는 인증 방식**을 적용했습니다.

```text
GitHub Actions
      │
      │ OIDC Token
      ▼
AWS IAM OIDC Provider
      │
      │ AssumeRoleWithWebIdentity
      ▼
Temporary AWS Credentials
      │
      ▼
Amazon ECR
      │
      ▼
Docker Image Push
```

#### 적용 내용

* GitHub Actions와 AWS IAM 간 OIDC 연동
* IAM Trust Policy를 통한 저장소 접근 제한
* 장기 Access Key 대신 임시 자격 증명 사용
* Docker 이미지 빌드
* Amazon ECR Private Repository로 이미지 Push

이를 통해 저장소에 AWS Access Key를 저장하지 않고도 CI 파이프라인에서 AWS 리소스에 접근할 수 있도록 구성했습니다.


### 4.7 CloudWatch 및 SNS 모니터링

애플리케이션의 오류 상황을 확인할 수 있도록 CloudWatch Alarm을 구성했습니다.

```text
Application Load Balancer
          │
          ▼
CloudWatch Metrics
          │
          ▼
5XX Error Alarm
          │
          ▼
SNS
          │
          ▼
Email Notification
```

5XX 오류 지표가 설정한 임계치를 초과하면 CloudWatch Alarm이 SNS Topic을 통해 이메일 알림을 전송하도록 구성했습니다.

이를 통해 서비스 오류 발생 여부를 수동으로 확인하지 않고도 모니터링할 수 있도록 했습니다.


### 4.8 Terraform 기반 인프라 코드화

수동으로 구성한 네트워크 리소스를 Terraform HCL 코드로 선언하여 인프라를 코드로 관리하는 과정을 경험했습니다.

#### 관리 대상

* VPC
* Internet Gateway
* Public, Private Subnet

Terraform을 활용해 다음 과정을 검증했습니다.

```text
Terraform Configuration
          │
          ▼
terraform apply
          │
          ▼
AWS Resources Created
          │
          ▼
Infrastructure Verification
          │
          ▼
terraform destroy
          │
          ▼
Resources Removed
```

이를 통해 인프라 생성 및 삭제 과정을 코드 기반으로 재현할 수 있도록 구성했습니다.


## 5. 검증 결과

구축한 인프라가 의도한 접근 제어와 통신 구조로 동작하는지 직접 확인했습니다.

| 검증 항목                 | 검증 방법                       | 결과                 |
| --------------------- | --------------------------- | ------------------ |
| 외부 PC → RDS 직접 접근     | RDS Endpoint 직접 접속 시도       | 타임아웃 발생, 접근 차단 확인  |
| Private EC2 → RDS     | `nc -zv` 명령어 사용             | 3306 포트 연결 성공      |
| ALB → App Server      | ALB를 통한 서비스 요청              | 정상 응답 확인           |
| Bastion → Private EC2 | SSH ProxyJump 접속            | Private 서버 접근 성공   |
| GitHub Actions → ECR  | CI Workflow 실행              | Docker 이미지 Push 확인 |
| CloudWatch → SNS      | 5XX Alarm 발생 조건 확인          | 이메일 알림 수신 확인       |
| Terraform 리소스 관리      | `terraform apply / destroy` | 생성 및 자원 회수 과정 확인   |


## 6. 트러블슈팅 및 장애 복구 (Troubleshooting)
* [Issue 1] ALB 대상 그룹 502 Bad Gateway 및 Unhealthy 해결
현상: ALB 엔드포인트 호출 시 브라우저에서 502 Bad Gateway가 반환되고 대상 그룹 헬스체크가 지속적으로 Unhealthy로 표시됨.

원인: 백엔드 프로세스가 루프백 인터페이스(127.0.0.1:8000)로 바인딩되어 외부 가상 네트워크 카드(eth0)를 통해 들어오는 ALB 트래픽을 거부함.

조치: 실행 호스트 주소를 모든 네트워크 인터페이스 수신을 뜻하는 0.0.0.0:8000으로 변경 후 재기동하여 Healthy 전환 및 정상 200 OK 복구 완료.

* [Issue 2] Private Subnet 내부 패키지 타임아웃 대응 (FinOps)
현상: Private EC2 내부에서 apt update 실행 시 101: Network is unreachable 및 연결 타임아웃 발생.

원인: 격리망 특성상 외부 인터넷으로 나가는 라우팅 경로 부재.

조치: 고정비가 큰 NAT Gateway를 증설하는 대신, Bastion Host에서 아티팩트를 패키징하여 사설 SCP로 반입하는 오프라인 아티팩트 배포 방식을 적용하여 $0 비용으로 격리 배포 완료.

* [Issue 3] ECR 이미지 덮어쓰기 차단 오류
현상: GitHub Actions 워크플로우 실행 중 The image tag 'latest' already exists and cannot be overwritten 에러로 파이프라인 중단.

원인: ECR 리포지토리의 기본 옵션인 Tag Immutability(태그 불변성) 설정으로 동일 태그 덮어쓰기가 AWS 정책상 차단됨.

조치: ECR 리포지토리 설정에서 태그 변경 가능(Mutable)으로 전환하여 CI 파이프라인 정상화 완료.


## 7. 주요 설계 의사결정

### NAT Gateway를 사용하지 않은 이유

Private EC2에서 외부 인터넷 접근이 필요했지만, 실습 환경에서 NAT Gateway를 사용하면 지속적인 비용이 발생합니다.

따라서 이번 프로젝트에서는 NAT Gateway를 추가하지 않고, Bastion Host를 통한 파일 전달 방식으로 배포했습니다.

#### Trade-off

* 장점

  * NAT Gateway 비용 절감
  * Private EC2의 외부 접근 경로 최소화

* 단점

  * 패키지 및 파일 반입 과정이 필요
  * 완전한 자동 배포 환경으로 확장하기에는 추가 구성 필요


### 보안 그룹 ID 참조 방식을 사용한 이유

CIDR 기반으로 넓은 IP 범위를 허용하는 방식보다, 보안 그룹을 소스로 지정하면 특정 계층의 리소스에서 발생하는 트래픽만 허용할 수 있습니다.

따라서 다음과 같은 계층별 접근 구조를 구성했습니다.

```text
ALB SG → App Server SG → RDS SG
```

이를 통해 각 계층의 역할에 맞는 최소한의 네트워크 접근만 허용하도록 설계했습니다.


### OIDC 인증 방식을 사용한 이유

GitHub Actions에서 AWS Access Key를 장기적으로 저장하는 방식은 자격 증명 유출 위험이 있습니다.

OIDC를 사용하면 GitHub Actions가 실행될 때만 임시 자격 증명을 발급받을 수 있으므로, 장기 Access Key를 저장하지 않는 CI 인증 구조를 구성할 수 있습니다.


## 8. 프로젝트를 통해 경험한 내용

* AWS VPC 및 Subnet 설계
* Public / Private 네트워크 분리
* ALB 기반 트래픽 전달 구조
* EC2와 RDS 간 보안 그룹 참조
* Bastion Host 및 SSH ProxyJump
* Private Subnet 환경에서의 배포 방식
* Docker 기반 애플리케이션 실행
* GitHub Actions OIDC 인증
* Amazon ECR 이미지 Push
* CloudWatch Alarm 및 SNS 이메일 알림
* Terraform을 활용한 인프라 코드화
* 네트워크 접근 제어에 대한 연결성 검증


## 9. 저장소 디렉터리 구조

```text
├── .github/
│   └── workflows/
│       └── deploy.yaml
│           └── OIDC 기반 ECR 이미지 빌드 및 Push CI
│
├── app/
│   ├── main.py
│   │   └── FastAPI 애플리케이션 엔드포인트 (/health)
│   ├── requirements.txt
│   │   └── Python 의존성 패키지
│   └── Dockerfile
│       └── FastAPI 실행 환경 및 이미지 설정
│
├── terraform/
│   └── main.tf
│       └── VPC, IGW, Subnet 등 인프라 리소스 정의
│
└── README.md
    └── 프로젝트 아키텍처 및 구축 과정 문서
```


## 10. 프로젝트 핵심 요약

> **AWS VPC 내부에 Public / Private 네트워크를 분리하고, ALB–Private EC2–RDS 구조를 구성했습니다.**
>
> **보안 그룹 참조 체이닝과 Bastion Host를 통해 접근 경로를 제한하고, Docker·OIDC·CloudWatch·Terraform을 적용하여 컨테이너 실행, CI 인증, 모니터링, 인프라 코드화까지 경험했습니다.**


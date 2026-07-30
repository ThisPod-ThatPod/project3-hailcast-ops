# 🧹 teardown 체크리스트 — 인프라 파괴 표준 절차

> **소유:** ⑤ 비용 가드레일 오너 (FinOps) · **적용:** EKS 스택을 내릴 때마다
> **근거:** Context 「비용 가드레일 오너 → destroy 누락 시 야간 과금 → 파괴 체크리스트」의 실물 구현
> **작성 계기:** 2026-07-07 EKS 실습 teardown 중 고아 리소스로 `terraform destroy` 20분 실패 → 추적·복구 경험
>
> **[7/28 대개정] 0~5장은 7/7 EKS 실습 기준 범용 원리(그대로 유효, 보존). 6~9장에 이미선님 실전 런북 3종(destroy 관련정리·destroy 런북·재구축 런북, 2026-07-28)을 반영해 hailcast 4레포 실전 절차를 추가.**
> **⚠️ 8/3 리허설 전 필독 — 조용빈님 지적:** 아래 7-3-2를 반드시 먼저 읽을 것. #58 머지로 `hailcast-rds-secret` 자동 생성 경로가 새로 생겨, 기존 런북의 "수동 kubectl create secret" 단계가 원칙적으로 불필요해졌을 가능성이 높다(단, 실제 자동 채워짐은 미검증 — 8/3에 확인).
>
> **[7/28 3차 개정] 실제 teardown 스크립트 4개(`ops/teardown.sh`·`manifests/teardown_manifest.sh`·`infra/teardown_infra.sh`·`app/teardown_app.sh`) 코드를 직접 검토해 10장에 연결. 치명 버그 1건(`app/teardown_infra.sh` 계정가드 함수명 오류)·설계 충돌 1건(같은 스크립트가 ArgoCD 관리 대상과 삭제 범위 중복) 발견 → 그룹 B 확인 요청 중. 위 4개 스크립트는 재작성본 배포 완료(9장 참고).**
>
> **[7/29 4차 개정 — 미선님 PR 리뷰 반영]** 10-2의 "계정가드 함수명 오류"는 **오탐이었음**(app 레포가 자체 `_lib.sh`를 갖고 있어 ops의 것과 대조한 제 착오). 10-4 "미해결"은 app #40으로 **이미 해결돼 있었음**("공식 경로는 manifests" 문서화). 10-1·10-3의 infra 스크립트 순서 서술을 PR#71 실제 반영 순서(계정→ALB→Karpenter→init→CUR)로 정정. `infra/teardown_infra.sh`는 이후 `terraform state list` 조회 실패를 빈 결과와 구분 못 하던 버그도 추가로 수정(2차 리뷰).
>
> **[7/30 5차 개정 — 용빈님 실행흐름 지적 반영]** `make destroy-all`(=`teardown.sh --yes`) 한 방이 **첫 실행에서 ②infra ALB 가드에서 의도적으로 exit 1 중단**되는 것이 정상임을, 처음 돌리는 사람이 "고장"으로 오해하지 않도록 **신설 10-2절에 3단계 실제 실행 흐름·권장 수동 절차·`plan -destroy` 리허설 분기를 명시.** 코드는 손대지 않음(용빈님 결론과 동일 — 이건 버그가 아니라 안전순서 강제). 기존 10-2~10-4 → 10-3~10-5로, 11장 → 12장으로 밀림.

---

## 0. 왜 이 문서가 필요한가 (한 줄)

`terraform destroy` "성공"은 **terraform이 아는 리소스**만 지웠다는 뜻이다.
**쿠버네티스가 만든 리소스(LB·ENI 등)는 terraform 영수증(state)에 없어서** 고아로 남고,
이 고아가 subnet·SG·VPC 삭제를 막아 **destroy가 통째로 실패**하거나 **과금이 계속된다.**

---

## 1. 핵심 원리 — "누가 만들었나"가 삭제 순서를 정한다

| 만든 주체 | 예시 리소스 | 지우는 법 |
| --- | --- | --- |
| **Terraform** | VPC·subnet·EKS·노드그룹·NAT·RDS | `terraform destroy` |
| **쿠버네티스** (state 밖 = 고아 위험) | LoadBalancer 서비스→**CLB/NLB**, Ingress→**ALB**, VPC CNI→**보조 ENI** | **먼저 kubectl로 삭제** |
| **Karpenter** (state 밖) | **EC2 노드**(terraform 노드그룹과 별개) | **먼저 nodeclaim 삭제** |

**철칙: 쿠버네티스/Karpenter가 만든 것을 먼저 걷어내고 → 그다음 `terraform destroy`.**
순서가 뒤집혀 EKS가 먼저 죽으면, 쿠버네티스의 뒷정리 장치(finalizer)가 돌 기회를 잃어 고아가 발생한다.

---

## 2. Teardown 표준 순서 (⭐ 이 순서대로)

```
① 쿠버네티스가 만든 AWS 리소스부터 제거   (finalizer가 ALB/CLB 청소)
② Karpenter 노드 회수
③ 1~2분 대기  (LB 삭제는 비동기)
④ terraform destroy
⑤ 잔여 스캔  (terraform 밖 고아 색출)
⑥ 다음 날 Billing 확인  (최종 판정)
```

### ① 쿠버네티스 리소스 먼저 삭제
```bash
kubectl get svc,ingress -A          # LoadBalancer/Ingress 목록 확인
kubectl delete ingress --all -A     # ALB 정리 (ALB Controller finalizer가 뒷정리)
kubectl delete svc --all -A --field-selector spec.type=LoadBalancer   # CLB/NLB 정리
```

### ② Karpenter 노드 회수 (Karpenter 사용 시)
```bash
kubectl delete nodeclaim --all      # Karpenter가 띄운 EC2 회수
# (또는 nodepool 삭제로 신규 프로비저닝 중단)
```

### ③ 대기
```bash
sleep 90                            # LB·ENI 실제 삭제가 끝날 시간을 준다
```

### ④ terraform destroy
```bash
terraform destroy
```

### ⑤ 잔여 스캔 — 상시 과금 🔴 리소스 색출
> destroy가 에러 없이 끝나도 **반드시 실행.** 오늘 고아 ENI처럼 terraform이 모르는 게 남을 수 있다.

```bash
REGION=ap-northeast-2

# (a) 고아 ENI — 오늘 destroy를 막은 범인. status=available = 주인 없는 랜선
aws ec2 describe-network-interfaces --region $REGION \
  --filters Name=status,Values=available \
  --query "NetworkInterfaces[*].[NetworkInterfaceId,SubnetId,Description]" --output table

# (b) EC2 노드 — 살아있으면 과금
aws ec2 describe-instances --region $REGION \
  --filters Name=instance-state-name,Values=running,pending,stopping,stopped \
  --query "Reservations[*].Instances[*].[InstanceId,State.Name,InstanceType]" --output table

# (c) NAT Gateway — 상시 과금 1순위 (~$43/월 환산)
aws ec2 describe-nat-gateways --region $REGION \
  --query "NatGateways[?State!='deleted'].[NatGatewayId,State]" --output table

# (d) EIP — 놀면서도 과금 (~$3.6/월). AssociationId 비면 유휴
aws ec2 describe-addresses --region $REGION \
  --query "Addresses[*].[PublicIp,AllocationId,AssociationId]" --output table

# (e) EBS 볼륨 — detach된 노드 디스크 (~$0.092/GB·월)
aws ec2 describe-volumes --region $REGION \
  --filters Name=status,Values=available \
  --query "Volumes[*].[VolumeId,Size,State]" --output table

# (f) 로드밸런서 — Classic + ALB/NLB 둘 다 확인
aws elb describe-load-balancers --region $REGION \
  --query "LoadBalancerDescriptions[*].LoadBalancerName" --output table
aws elbv2 describe-load-balancers --region $REGION \
  --query "LoadBalancers[*].[LoadBalancerName,Type,State.Code]" --output table

# (g) 우리 프로젝트 상시 과금 추가 대상 (본 프로젝트에서 켜질 때)
aws rds describe-db-instances --region $REGION \
  --query "DBInstances[*].[DBInstanceIdentifier,DBInstanceStatus]" --output table   # RDS
aws elasticache describe-cache-clusters --region $REGION \
  --query "CacheClusters[*].[CacheClusterId,CacheClusterStatus]" --output table     # Redis
```

**나온 게 있으면 제거:**
```bash
aws ec2 delete-network-interface --network-interface-id <eni-id> --region $REGION  # available만
aws ec2 release-address --allocation-id <alloc-id> --region $REGION                # 유휴 EIP
aws ec2 delete-volume --volume-id <vol-id> --region $REGION                        # available 볼륨
```
> ⚠️ `<...>` 자리는 **실제 ID로 치환**해서 실행. 스캔이 비어 있으면 이 명령은 실행할 필요 없음.

### ⑥ 다음 날 최종 판정
- **AWS 콘솔 → Billing / Cost Explorer**: EKS·NAT·RDS 등이 **$0로 수렴**했는지 확인.
- **Resource Groups → Tag Editor**: 리전 전체 살아있는 리소스를 한 화면에서 스캔(빠른 눈검사).

---

## 3. 우리 프로젝트 특화 주의점

| 항목 | 주의 | 근거 |
| --- | --- | --- |
| **ALB Controller** | Ingress 삭제 없이 destroy하면 **ALB·TargetGroup·SG 고아** → subnet 삭제 막힘 | 오늘 CLB와 동일 메커니즘 |
| **Karpenter** | 노드가 terraform 밖 → nodeclaim 먼저 삭제 안 하면 **EC2 고아 과금** | Context: Karpenter 노드 오토스케일 |
| **KEDA** | 스케일 아웃 중 노드/파드 많으면 **VPC CNI 보조 ENI 고아**가 더 잘 생김 | 오늘 그 `available` ENI |
| **RDS** | `deletion_protection=true`면 destroy가 **거부됨** → 끄고 재시도. destroy 시 **데이터 삭제**(스냅샷 원하면 `skip_final_snapshot=false`) | Context: RDS 보호장치 아님 |
| **VPC 엔드포인트(Interface)** | SSM 등 Interface 엔드포인트도 상시 과금 🔴 (~$7.3/월 each) | 리소스 사전 |

---

## 4. 자동화 방향 (개선과제 → 대부분 구현 완료, 10장 참고)

- **`teardown.sh`**: ~~위 ①~⑤를 스크립트 한 방으로~~ → **구현 완료.** `ops/teardown.sh`가 manifest→infra→app 순서를 강제하고, 각 스캔이 비었는지는 `infra/teardown_infra.sh`의 CUR·ALB·Karpenter 3중 가드가 담당(10장).
- **AWS Budgets 경보($50/$100/$150)**: teardown이 "능동 방어"라면 Budgets는 "안전망". destroy를 깜빡해도 임계 초과 시 알림. **(아직 구현 안 됨 — 개선과제로 유지)**
- **AWS Instance Scheduler**: 개발/데모 시간(예 14~18시) 외 자동 종료로 상시 과금 최소화. **(아직 구현 안 됨 — 개선과제로 유지)**
- **남은 것:** 스크립트는 다 있지만 **팀 게이트 5개(6장)를 아직 아무도 확정 안 함** — 코드가 완성돼도 게이트값(`ARGOCD_DELETE_PATH`·`CUR_HANDLING`)을 안 넣으면 안전하게 막히도록 설계했다(10-4절).

---

## 6. ⭐ destroy 전 팀이 정할 5가지 (게이트 — 하나라도 미정이면 시작 금지)

> **쉬운 설명:** 옛날 게임에서 보스방 문이 "열쇠 5개 다 모아야 열림"인 것과 같다. 아래 표가 그 열쇠판이다. destroy 런북 0-3절이 원본이고, 여기는 팀장이 진행 상황을 한눈에 보는 체크판이다.
> **[3차 개정] ①②는 이제 스크립트가 직접 읽는 환경변수와 연결됐다(10장) — 표에 그 값을 추가했다.**

| # | 결정 사항 | 선택지 | 실행 시 환경변수 | 상태(2026-07-28 기준) |
| --- | --- | --- | --- | --- |
| 1 | CUR 버킷을 살릴지 버릴지 | 살림(§8-1 A안) / 버림(§8-1 B안) | `CUR_HANDLING=keep`\|`drop` | ⬜ **정하지 않음** |
| 2 | 매니페스트 삭제 경로 | `argocd` CLI / `kubectl` | `ARGOCD_DELETE_PATH=argocd`\|`kubectl` | ⬜ **정하지 않음** |
| 3 | RDS 수동 스냅샷을 뜰지 | 뜸 / 안 뜸(콜·예측·스케일링 이력 전부 소실 감수) | (수동 — `infra/teardown_infra.sh`에 주석 처리된 스니펫 있음) | ⬜ **정하지 않음** |
| 4 | ArgoCD 설치 주체(재구축 때 필요) | 담당자 지정 + 설치 매니페스트 주소 | — | ⬜ **정하지 않음** |
| 5 | 8/3이 실제 destroy인지 `plan -destroy` 리허설인지 | 리허설(읽기전용·1분) / 실제 | `CONFIRM=yes` 여부(리허설=미설정) | ⬜ **정하지 않음** |

**전문가 관점:** 5번이 특히 중요합니다. 리허설이면 destroy 런북 3단계(K8s 삭제)까지만 하고 6-1(plan -destroy)로 건너뛰고 실제 destroy는 안 돌립니다 — 잘못 읽고 5-2(진짜 destroy)까지 실행하면 8/4 발표 전날 인프라가 사라지는 대참사가 됩니다. **이 5가지는 팀장이 임의로 정하지 않습니다** — 팀 회의에서 확정 후 이 표의 상태 칸만 갱신합니다.

**실행 예시(①②③④⑤ 전부 확정됐다고 가정):**
```bash
ARGOCD_DELETE_PATH=argocd CUR_HANDLING=keep bash scripts/teardown.sh --yes
```

---

## 7. ⭐ 실전 destroy 절차 (hailcast 4레포 기준)

> 전체 원본: 이미선님 「destroy 런북」. 여기는 실행 시 놓치기 쉬운 지점 위주로 압축.

### 7-1. 준비 (카메라 밖에서 먼저)
```bash
aws sts get-caller-identity --query Account --output text   # 797452357900 아니면 여기서 중단
cd <작업폴더>/project3-hailcast-infra
aws eks update-kubeconfig --region ap-northeast-2 --name hailcast-dev-eks
kubectl get nodes
terraform -chdir=envs/dev init
```

### 7-2. 백업 (필요한 경우만)
- RDS 스냅샷(6번 게이트에서 "뜸"으로 정했을 때만):
```bash
aws rds create-db-snapshot --db-instance-identifier hailcast-dev-rds-postgres \
  --db-snapshot-identifier hailcast-dev-rds-final-$(date +%Y%m%d)
aws rds wait db-snapshot-available --db-snapshot-identifier hailcast-dev-rds-final-$(date +%Y%m%d)
```
- **모델 파일은 무조건 먼저 내려받는다** (재구축 때 다시 올려야 함, 없으면 예측 전체가 멈춤):
```bash
BUCKET=$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'hailcast-dev-model-artifacts')].Name" --output text)
aws s3 cp "s3://$BUCKET/models/latest/model.pkl" ~/hailcast-backup/
aws s3 cp "s3://$BUCKET/models/latest/metadata.json" ~/hailcast-backup/
terraform -chdir=envs/dev output > ~/hailcast-backup/output_before_destroy.txt
```

### 7-3. CUR 버킷 처리 — **여기서 안 정하면 destroy가 초반부터 실패한다**
> **왜 여기서 막히나(쉬운 설명):** CUR 버킷은 `force_destroy=false`라 "비어있지 않으면 안 지워짐" 설정이다. AWS가 청구 데이터를 계속 채워 넣어서 절대 안 빈다. 그래서 destroy가 이 버킷에서 `BucketNotEmpty` 에러로 멈춘다 — 그것도 비싼 EKS·NAT가 아니라 **의존성 그래프상 앞쪽이라 초반에** 멈춘다.

- **비용 이력을 살리는 경우:**
```bash
aws cur delete-report-definition --report-name hailcast-dev-cur --region us-east-1
terraform -chdir=envs/dev state rm \
  module.storage.aws_s3_bucket.cur \
  module.storage.aws_s3_bucket_policy.cur \
  module.storage.aws_s3_bucket_lifecycle_configuration.cur \
  module.storage.aws_s3_bucket_public_access_block.cur \
  module.storage.aws_s3_bucket_server_side_encryption_configuration.cur \
  module.storage.random_id.cur_suffix
```
  → 버킷은 실제로 안 지워지고 IaC 밖 자원으로 남는다(규약서 5-9절에 옮겨 적기).

- **비용 이력도 버리는 경우:** CUR 정의 먼저 삭제 → `modules/storage/cur.tf`의 `force_destroy`를 `true`로 바꿔 **destroy 시작 전에** apply(순서 바뀌면 EKS·NAT·RDS를 통째로 재생성함) → 그다음 destroy.

### 7-4. K8s 리소스 삭제 — **Ingress부터, ArgoCD selfHeal이 되살리기 전에**
모든 ArgoCD Application에 `selfHeal`·`prune`이 켜져 있어서, Ingress만 kubectl로 지우면 ArgoCD가 즉시 되살립니다. **반드시 Application을 먼저 지웁니다.**

- **경로 A(argocd CLI, 게이트②에서 이걸로 정했을 때):**
```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8080 --username admin --password "$PW" --insecure
argocd app delete hailcast-root --cascade --yes   # 루트 이름 주의: 파일명(app-of-apps.yaml)과 다름
```
  → 삭제 시점에 finalizer를 자동으로 붙여줘서, 아래 finalizer 없는 7종도 하위 자원까지 같이 지워짐.

- **경로 B(kubectl, 게이트②에서 이걸로 정했을 때):**
```bash
kubectl -n argocd delete application --all
```
  → 아래 **finalizer 없는 7종**은 Application 오브젝트만 사라지고 **Karpenter 노드·EBS가 클러스터에 남는다** → 8단계에서 직접 지워야 함:
  ```
  grafana-dashboards, karpenter, keda, kube-prometheus-stack,
  metrics-server, opencost, platform-monitoring
  ```
  (전체 17개 Application 중 7개. `manifests scripts/teardown_manifest.sh`의 실제 삭제 명령 4줄은 주석 처리돼 있어 팀이 A/B를 직접 정하지 않으면 아무것도 안 지워짐 — 스크립트에 맡기지 말 것.)

**확인(3분 넘겨도 안 비면 진행 중단하고 원인 파악):**
```bash
kubectl get ingress -A
kubectl get svc -A | grep -i loadbalancer
aws elbv2 describe-load-balancers --region ap-northeast-2 --query 'LoadBalancers[].LoadBalancerName' --output text
```

### 7-5. 노드·볼륨 회수 확인
```bash
kubectl get nodes
aws ec2 describe-instances --region ap-northeast-2 \
  --filters "Name=tag-key,Values=karpenter.sh/nodepool" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text
# 남아있으면:
aws ec2 terminate-instances --region ap-northeast-2 --instance-ids <ID들>
```

### 7-6. terraform destroy
```bash
terraform -chdir=envs/dev plan -destroy      # 게이트⑤가 리허설이면 여기까지만
# ↓ 실제 destroy로 정했을 때만
terraform -chdir=envs/dev destroy
```
**전문가 관점 — 두 가지를 알고 시작:**
- 아티팩트 버킷 객체가 (2026-07-27 09시 기준) **112만 개**. `force_destroy=true`라 실패는 안 하지만 나눠서 지우느라 오래 걸리고, **Terraform이 진행률을 안 보여줌**. `Still destroying...`만 반복해도 멈춘 게 아니니 중단하지 말 것(중단하면 state와 실제 자원이 어긋남).
- CloudFront는 비활성화→삭제 2단계라 **10분 이상** 걸림.

### 7-7. 잔여 확인
```bash
aws ec2 describe-addresses --region ap-northeast-2 --query 'Addresses[].PublicIp' --output text
aws ec2 describe-volumes --region ap-northeast-2 --filters "Name=status,Values=available" --query 'Volumes[].VolumeId' --output text
aws elbv2 describe-load-balancers --region ap-northeast-2 --query 'LoadBalancers[].LoadBalancerName' --output text
aws ec2 describe-network-interfaces --region ap-northeast-2 --filters "Name=status,Values=available" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text
```
전부 비어야 정상. **`Route53` 호스팅 영역(`hailcast.myminiinfra.store`)은 남는 게 정상**(Terraform이 만들지 않고 조회만 하는 대상 — 지우면 서브도메인 위임이 끊김).

### 7-8. destroy 후에도 남는 것 (계정 단위 자원 — 재구축 때 다시 안 만들어도 됨)
tfstate 버킷(`hailcast-dev-tfstate-7dde`) · EC2 Spot 서비스 연결 역할 · 팀원 IAM 유저 5명 · 콘솔 수동 IAM 정책 2종(버킷 접미사만 재구축 후 수정) · Budgets · Route53 호스팅 영역/NS 위임 · GitHub repo secret 4종 · 계정 지원 플랜.

---

## 8. ⭐ 실전 재구축 절차 요약 — 배포팀 10줄 + hailcast-rds-secret 자동화 갱신

> **쉬운 설명:** destroy로 인프라를 다 지우면, Terraform으로 다시 세운 리소스들은 **이름은 같아도 내부 ID가 다시 뽑힙니다**(주민번호는 같은데 카드번호가 재발급되는 느낌). 매니페스트에 그 ID를 문자 그대로 박아둔 곳이 있어서, 그 자리만 새 값으로 바꿔주면 됩니다. 안 바꾸는 값(IRSA ARN, SQS URL, ECR 주소 등)은 **이름으로 정해지는 값이라 재구축해도 그대로**입니다.

### 8-1. 재구축 시 고쳐야 하는 배포팀 10줄 (인프라가 값을 전달)

| 값 | 받는 곳(manifests) | 안 고치면 |
| --- | --- | --- |
| ACM 인증서 ARN (`alb_certificate_arn`) | `apps/call-api/ingress.yaml:19` · `apps/frontend/ingress.yaml:15` · `apps/predict/ingress.yaml:11` | 없는 인증서 지목 → HTTPS 리스너 안 붙음 |
| VPC ID (`vpc_id`) | `addons/aws-load-balancer-controller/values.yaml:3`의 `vpcId` | 컨트롤러가 없는 VPC 지목 → ALB 자체가 안 생김 |
| RDS 마스터 시크릿 ARN (`rds_master_secret_arn`) | `platform/external-secrets/externalsecret-rds-credentials.yaml:19,23` | ESO가 없는 시크릿 조회 → 계속 실패(단, Merge 정책이라 파드 자체는 뜸 — 로테이션만 안 반영) |
| S3 버킷 이름 (`model_bucket_name`) | `apps/predict·call-api·simulator·weather-cron/deployment.yaml` 4곳 | `NoSuchBucket` |

**바뀌지 않아 손댈 필요 없는 것(재확인):** IRSA 역할 ARN 9곳, SQS 큐 URL 3곳, ECR 주소, EKS 클러스터 이름, EC2NodeClass 셀렉터, 네임스페이스·ServiceAccount·ScaledObject 이름.

### 8-2. 재구축 순서 뼈대
```
1) infra: alb_dns_name=""로 리셋 → 첫 apply(로컬·사람이 직접 — CI가 먼저 하면 사람이 kubectl 못 씀)
2) infra: output 4종을 배포팀에 전달, kubeconfig 재발급
3) 배포팀: ArgoCD 설치(주체 미정 — 게이트④)
4) 배포팀: 위 8-1 10줄 반영 + PR + 머지 → Application 전부 Synced/Healthy 확인
5) 앱팀: 이미지 6종 재빌드(★ dev push 아니라 workflow_dispatch로 — push면 바뀐 서비스만 빌드돼 나머지가 ImagePullBackOff)
6) 인프라: IAM 콘솔 수동 정책의 버킷 접미사 교체 (앱팀 모델 업로드보다 먼저!)
7) 앱팀: model.pkl·metadata.json 재업로드
8) 배포팀: Ingress 올림 → 인프라: alb_dns_name에 새 ALB 주소 넣어 2차 apply(CloudFront 생성)
9) 완료 확인: 노드 Ready·파드 Running·Application 전부 Healthy·plan No changes·서비스 URL 200
```

### 8-3. 🔴 `hailcast-rds-secret` — #58 머지로 절차가 바뀜 (조용빈님 지적 반영)

**기존 런북(2026-07-28 오전 기준) 서술:**
> "자동으로 안 생긴다. 반드시 둘 다 해야 한다 — ① ESO CRD 설치, ② `kubectl create secret`으로 수동 생성"

**변경된 사실 (같은 날 오후 #58 머지 — `feature/rds-secret-placeholder`):**
- `manifests platform/external-secrets/secret-rds-placeholder.yaml`이 **sync-wave `-1`**로 들어와, ExternalSecret(기본 wave 0)보다 먼저 **빈 Secret을 자동 생성**한다.
- ExternalSecret 2개(`creationPolicy: Merge`)가 그 빈 Secret에 `DB_USER`·`DB_PASSWORD`·`DB_HOST` 키를 자동으로 채워 넣는다.

**그래서 절차가 이렇게 바뀝니다:**

| 단계 | 기존(오전) | 갱신(#58 반영) |
| --- | --- | --- |
| ① ESO CRD 설치 | 필요 | **여전히 필요**(자동 경로에서도 CRD 없으면 ExternalSecret 리소스 자체가 안 만들어짐 — 주소는 게이트④와 별개 미정 항목) |
| ② 수동 `kubectl create secret` | 필요 | **원칙적으로 불필요할 가능성 높음** — 다만 "실제로 자동 채워지는지"는 **미검증**(이 자동 경로가 빈 클러스터에서 검증된 적이 없고, 8/3 재구축이 첫 실행) |

**8/3 리허설에서 반드시 확인:**
```bash
kubectl -n argocd get application platform-secrets            # Synced인지 먼저
kubectl -n hailcast get secret hailcast-rds-secret -o jsonpath='{.data}' | jq 'keys'
# 기대값: ["DB_HOST","DB_PASSWORD","DB_USER"]  ← 이 셋이 다 나오면 수동 생성 생략
kubectl -n hailcast get externalsecret                         # rds-credentials·rds-endpoint 둘 다 SecretSynced
```
**키가 비어 있거나 SecretSynced가 아닐 때만** 아래 수동 patch를 백업으로 실행(비용관리.md `:241`·`:261` 절 참조, `create`가 아니라 `patch`인 이유는 빈 Secret이 이미 있기 때문):
```bash
RDS_SECRET="$(terraform -chdir=envs/dev output -raw rds_master_secret_arn)"
CRED="$(aws secretsmanager get-secret-value --secret-id "$RDS_SECRET" --query SecretString --output text)"
kubectl -n hailcast create secret generic hailcast-rds-secret \
  --from-literal=DB_HOST="$(aws ssm get-parameter --name /hailcast/dev/rds/endpoint --query Parameter.Value --output text)" \
  --from-literal=DB_USER="$(echo "$CRED" | jq -r .username)" \
  --from-literal=DB_PASSWORD="$(echo "$CRED" | jq -r .password)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

**전문가 관점 — 왜 이게 "최악은 아니다"인가:** 조용빈님 말대로, 자동 생성이 실패해도 수동 백업 절차가 그대로 유효해서 **파드가 못 뜨는 상황 자체는 안 생깁니다.** 문제는 "8/3에 팀원이 이제는 불필요할 수도 있는 수동 명령을 기계적으로 실행"하는 비효율 + "런북이 최신 상태를 못 따라간다"는 **이번 주 계속 반복된 패턴**이 재현된 것 — 그래서 이 체크리스트 자체를 문서 갱신 시점마다 반드시 재검증해야 합니다(9장 참조).

---

## 9. ⭐ 확인 안 된 것 (8/3 리허설에서 채울 빈칸)

이 항목들은 **팀이 실제로 해보기 전에는 답을 낼 수 없는 것들**입니다. 리허설 중 관찰한 값을 이 표에 채워 넣습니다.

| # | 항목 | 왜 모르나 |
| --- | --- | --- |
| 1 | destroy 전체 소요 시간 | 아티팩트 버킷 112만 객체 삭제 속도가 실측 안 됨 |
| 2 | `alb_dns_name`을 옛 값으로 둔 채 apply했을 때 Route53이 없어진 ELB DNS를 alias 대상으로 받아주는지 | 조회로 판별 불가(7-6·8-2 순서로 이 경우 자체를 피하고 있음) |
| 3 | SQS 큐 삭제 직후 같은 이름으로 재생성 시 `QueueDeletedRecently`로 막히는지 | AWS 권장 대기 60초, 재구축을 바로 이어 하면 걸릴 가능성 |
| 4 | CUR 정의를 새 버킷 이름으로 재생성 시 콘솔이 버킷 정책을 덮는지 | 콘솔 경로 미시도 |
| 5 | 배포팀 계정에 `secretsmanager:GetSecretValue`·`ssm:GetParameter` 권한이 있는지 | 8-3 수동 백업 경로 실행 권한 미확인 — 거부되면 인프라 담당이 대신 실행 |
| ~~6~~ | ~~`ops scripts/teardown.sh`의 매니페스트 단계 호출부 전체~~ | **[3차 개정에서 해소]** 코드 직접 확인함 — manifest 단계는 CONFIRM을 주입하지 않고 각 스크립트 자체 기본값(미리보기)을 따름. 10장 참고 |
| 6 | 8/3을 실제 destroy로 할지 `plan -destroy` 리허설로 할지 | **6장 게이트⑤와 동일 — 팀 결정 대기** |
| ~~7~~ | ~~`app/scripts/teardown_infra.sh`의 존속 여부~~ | **[4차 개정에서 해소]** app #40이 "공식 경로는 manifests 레포"로 이미 문서화·경고 처리 완료. 10-5절 참고 |

**남은 3개 결정 병목(재구축 쪽, 4·7-1·9-2절):** ① ArgoCD 설치 주체·명령, ② ESO CRD 매니페스트 주소, ③ 텔레그램 봇 토큰·채팅ID 보관처. 이 셋이 정해지기 전엔 "제3자가 이 문서만 보고 재구축"이 불가능합니다 — 평가표의 "제3자가 즉시 복제 가능한 운영지침서" 항목은 이 3개 병목 때문에 **8/4 전 완성은 무리**라는 게 이미선님 판단이고, 팀장도 동의합니다. → **개선기간(8/5~) 과제로 이관**을 권장합니다(12장 평가 매핑 갱신).

---

## 10. ⭐ 실행 경로 — Makefile·teardown 스크립트 4종 코드 리뷰 결과

> **쉬운 설명:** 7장이 "무엇을 지워야 하는가"라면, 이 장은 "그걸 실제로 어느 스크립트가, 어떤 순서로, 어떤 안전장치를 달고 실행하는가"입니다. 4개 스크립트(`ops/teardown.sh`가 지휘자, `manifests/teardown_manifest.sh`·`infra/teardown_infra.sh`·`app/teardown_app.sh`가 각 레포 담당)를 2026-07-28에 실제 코드로 직접 검토했습니다.

### 10-1. 호출 구조

```
ops/scripts/teardown.sh  (지휘자 — make destroy-all 이 이걸 부름)
  │
  ├─① manifest ──▶ manifests/scripts/teardown_manifest.sh
  │                 (Application 삭제 — ARGOCD_DELETE_PATH로 argocd/kubectl 분기)
  │
  ├─② infra    ──▶ infra/scripts/teardown_infra.sh   ★CONFIRM=yes 자동 주입
  │                 (계정 가드 → ALB 가드 → Karpenter 노드 가드 → terraform init → CUR 가드 → terraform destroy)
  │
  └─③ app      ──▶ app/scripts/teardown_app.sh
                    (로컬 도커 컨테이너·이미지·볼륨·캐시 정리 — 클라우드 무관)

  [별도, 오케스트레이터 미편입] app/scripts/teardown_infra.sh  ← 10-5절, 존치·미편입으로 확정(app #40)
```

**전문가 관점 — 왜 `infra` 단계에만 `CONFIRM=yes`를 자동 주입하나:** manifest·app은 "미리보기만 하고 사람이 다시 확인 후 재실행"해도 비용 손해가 적지만(K8s 리소스 삭제 지연 정도), infra는 EKS·NAT·RDS라 **정말로 지우는 그 순간이 비용의 갈림길**입니다. 그래서 이 단계만 사람이 최상위 프롬프트(`y` 입력)에 동의하면 자동으로 실제 destroy까지 갑니다 — 대신 그 전에 CUR·ALB·Karpenter 3중 가드가 막아줍니다.

### 10-2. ⚠️ `make destroy-all` 한 방은 첫 실행에서 "정상적으로" 중단된다 — 처음 돌리는 사람 필독

> **쉬운 설명:** `bash teardown.sh --yes` 하나로 다 지워질 것 같지만, **실제로는 중간에서 멈춥니다. 그리고 그 멈춤은 고장이 아니라 안전장치가 제대로 일한 것입니다.** 왜 그런지 모르고 돌리면 "스크립트가 깨졌다"고 오해하기 쉬워서, 실제 실행이 어떻게 흘러가는지 3단계로 미리 적어둡니다.

**`bash scripts/teardown.sh --yes`를 처음 돌렸을 때 실제로 벌어지는 일:**

```
① manifest 단계 → CONFIRM이 주입되지 않음 → "미리보기만" 수행
                   → ArgoCD Application이 실제로는 안 지워짐 → ALB가 살아있음
② infra 단계    → CONFIRM=yes 주입됨 → ALB 가드가 "K8s가 만든 ALB가 아직 있다"를 발견
                   → exit 1 로 의도적으로 중단  ← 여기서 멈춘다 (정상)
③ app 단계     → ②에서 멈췄으므로 아예 도달 안 함
```

**왜 이게 버그가 아니라 설계인가:** manifest 단계에 CONFIRM을 자동 주입하면 "K8s 리소스가 사람 확인 없이 삭제"되는 더 위험한 상황이 됩니다(10-1 전문가 관점). 그래서 manifest는 일부러 미리보기에 머물고, 그 결과 ALB가 남고, infra의 ALB 가드가 그걸 잡아 멈추는 것 — **"K8s를 먼저 확실히 정리하지 않으면 인프라 destroy로 못 넘어간다"는 안전 순서(1장 원칙)를 코드가 강제**하는 것입니다.

**그래서 실제로는 이렇게 3단계로 나눠서 돌린다(권장 절차):**

```bash
# ── 1단계: K8s 워크로드·ALB를 실제로 정리 (사람이 CONFIRM을 직접 준다) ──
ARGOCD_DELETE_PATH=argocd \
  CONFIRM=yes bash ../project3-hailcast-manifests/scripts/teardown_manifest.sh
# → ALB·Ingress가 사라질 때까지 대기. 아래로 넘어가기 전 반드시 확인:
kubectl get ingress -A ; aws elbv2 describe-load-balancers \
  --region ap-northeast-2 --query 'LoadBalancers[].LoadBalancerName' --output text
#   (위 두 줄이 비면 통과 — 안 비면 3분 더 기다렸다 재확인)

# ── 2단계: 인프라 destroy (이제 ALB가 없으니 가드를 통과한다) ──
CUR_HANDLING=keep bash scripts/teardown.sh --only infra --yes
#   또는 infra 레포에서 직접:
#   CUR_HANDLING=keep CONFIRM=yes bash ../project3-hailcast-infra/scripts/teardown_infra.sh

# ── 3단계: 로컬 도커 정리 (클라우드 무관, 실패해도 안전) ──
bash scripts/teardown.sh --only app --yes
```

**핵심:** `--yes` 한 방으로 끝나기를 기대하지 말고, **1단계(manifest)를 사람이 CONFIRM을 줘서 실제로 완료시킨 뒤** 2단계로 넘어가야 합니다. `teardown.sh --yes`를 그냥 돌리면 ②에서 멈추는 게 정상이며, 그때는 "1단계부터 수동으로 다시" 하면 됩니다. **`--only` 플래그로 단계를 하나씩 끊어 도는 게 8/3 리허설에서 가장 안전합니다.**

> **8/3 리허설이 `plan -destroy`(읽기전용)라면:** 2단계에서 `CONFIRM=yes`를 **주지 않습니다.** 그러면 infra 스크립트가 `terraform destroy` 대신 `terraform plan -destroy`(미리보기)만 돌려서, 실제로는 아무것도 안 지우고 "순서·명령이 맞는지"만 검증할 수 있습니다(6장 게이트⑤).

### 10-3. 발견된 문제와 조치

| 심각도 | 스크립트 | 문제 | 조치 |
| --- | --- | --- | --- |
| ~~🔴 P0~~ | ~~`app/teardown_infra.sh`~~ | ~~존재하지 않는 함수 `guard_project_account()` 호출~~ | **[7/29 정정 — 오탐]** app 레포는 **자체 `scripts/_lib.sh:76`**에 `guard_project_account`를 별도로 정의해 그걸 source합니다. 제가 ops의 `_lib.sh`(`verify_project_account`)와 비교해서 "이름 불일치"로 잘못 판단했습니다 — 서로 다른 두 파일을 대조한 오류였습니다. 계정이 다르면 `_lib.sh:89`, 자격증명이 없으면 `:94`에서 정상적으로 `exit 1` 합니다. |
| 🔴 P0 | `app/teardown_infra.sh` | `kubectl delete namespace hailcast`로 네임스페이스 전체 삭제 — 그 안 워크로드는 전부 ArgoCD GitOps 관리 대상이라 `manifests/teardown_manifest.sh`(Application 삭제)와 삭제 책임이 겹침. `selfHeal:true`인 상태에서 이 스크립트를 단독 실행하면 ArgoCD가 되살리려다 충돌 가능 | **이 항목은 그대로 성립**(app/scripts/teardown_infra.sh:58) — 10-5절에서 처리 결론 확정 |
| 🟡 P1 | `manifests/teardown_manifest.sh` | 실 삭제 명령 4줄이 주석 처리 + 주석 내용 자체가 실제 결정과 다름(`hailcast` root Application이 아니라 실제 이름은 `hailcast-root`, helm 릴리스 방식 아님) | **재작성 완료·배포됨**(파일명 동일, `ARGOCD_DELETE_PATH` 분기 반영) |
| 🟡 P1 | `infra/teardown_infra.sh` | ALB만 가드, **CUR 버킷·Karpenter 노드 가드 없음** → 실행하면 CUR 단계에서 즉사하거나 Karpenter 노드 잔존 상태로 destroy해 VPC 삭제가 막힘 | **재작성 완료·배포됨**(계정 가드 → ALB → Karpenter → `terraform init` → **CUR 가드**(init 이후로 배치, PR#71) → destroy) |
| 🟢 P2 | `app/teardown_app.sh`·`manifests/teardown_manifest.sh` | `set -u`만 쓰고 `set -e`가 없어 중간 실패가 조용히 넘어갈 수 있음 | **재작성본에서 `FAILED` 플래그로 실패를 누적해 최종 종료코드에 반영**(단, `-e`를 그대로 켜면 "이미 없는 리소스" 같은 정상 케이스까지 죽어서 의도적으로 유지) |
| ⚪ 정보 | `ops/teardown.sh` | 설계 자체는 양호(계정가드 최우선, 단계별 확인 프롬프트, `--only`/`--yes` 옵션) | **게이트값(`ARGOCD_DELETE_PATH`·`CUR_HANDLING`) 하위 스크립트 전달 기능만 추가**해 재배포 |

### 10-4. 재작성본 — 4개 스크립트 전부 배포 완료

원본 파일명 그대로 교체 가능합니다. 핵심 변경점만 요약:

- **`teardown_manifest.sh`**: `ARGOCD_DELETE_PATH=argocd|kubectl`로 경로 분기(기본 kubectl). 경로 A는 `hailcast-root`(실제 이름) cascade 삭제. 경로 B는 `kubectl -n argocd delete application --all` + finalizer 없는 7종 경고. 클러스터 컨텍스트가 `hailcast`를 안 포함하면 사전 경고.
- **`teardown_infra.sh`**: 계정 가드(단독 실행 대비, `ops/_lib.sh` 존재 시 사용) → **ALB 가드** → **Karpenter 노드 가드**(신규) → `terraform init` → **CUR 버킷 가드**(`CUR_HANDLING` 미설정이면 무조건 중단, `state rm`은 backend 초기화가 전제라 `init` 뒤로 배치 — PR#71 이미선 리뷰 반영) → `terraform destroy`.
- **`teardown_app.sh`**: 컨테이너 정지→이미지→볼륨→빌드캐시 순서로 확장(기존엔 컨테이너 정지 단계가 없어 실행 중인 컨테이너가 이미지를 물고 있으면 완전 정리가 안 됐음).
- **`teardown.sh`**(ops): `ARGOCD_DELETE_PATH`·`CUR_HANDLING`을 최상단에서 `export`해 manifest·infra 단계에 자동 전달. `app/teardown_infra.sh`를 의도적으로 미편입 처리하고 그 사유를 파일 안에 명문화(10-5절과 동일 내용).

**실행 한 줄 예시(6장 게이트 ①②③④⑤ 전부 확정 후):**
```bash
ARGOCD_DELETE_PATH=argocd CUR_HANDLING=keep bash scripts/teardown.sh --yes
```

### 10-5. ✅ 해결됨 — `app/teardown_infra.sh` 존속 여부 (app #40으로 확정)

**[7/29 갱신]** 아래 세 갈래((a)삭제/(b)개명/(c)편입) 중 어느 것도 아니었습니다 — **"존치하되 공식 경로에서 제외"**로 이미 결론이 나 있었습니다.

app 레포 **#40**이 `scripts/README.md`·`Makefile`에 "**EKS 워크로드 정리의 공식 경로는 manifests 레포 Makefile**"이라고 명시했고, `make teardown-infra` 실행 시점에도 경고 메시지를 찍도록 해뒀습니다. 파일 자체는 지우지 않았습니다(디버깅·로컬 용도로 남겨둔 것으로 추정).

이 결론은 이번 ops PR의 `scripts/teardown.sh:145-147`에 있는 **주석 처리된 "APP_INFRA 단계"와 정확히 일치**합니다 — 오케스트레이터에 편입하지 않고 주석으로 사유만 남겨둔 상태 그대로 유지하면 됩니다. 별도 수정 불필요.

**참고로 남겨두는 질의 이력(2026-07-28, 재혁님·창원님께 발송):**
1. ArgoCD 붙기 전 임시 스크립트였는지, 지금도 실제로 쓰는지
2. 쓴다면 ArgoCD가 관리 안 하는 별도 대상이 있는지
3. ~~`guard_project_account()` 함수명 불일치를~~ → **[7/29 정정] 이 항목은 애초에 문제가 아니었음(10-3절 참고, app 자체 `_lib.sh`가 정상 존재)**

**전문가 관점 — 이게 왜 여전히 기록할 가치가 있는가:** 결과적으로 버그는 없었지만, "삭제 책임이 겹치는 스크립트가 죽은 코드로 남아있다"는 구조 자체는 여전히 리스크입니다. `README.md`·`Makefile` 경고문이 실제로 팀원이 실수로 단독 실행하는 걸 막아주는지는 사람이 그 경고를 읽어야만 작동하는 방어라, 8/3 리허설 때 "혹시 이 스크립트를 실행한 사람 있는지" 한 번 구두로 확인하는 걸 권장합니다.

---

## 12. 평가표 연결

- 🎯 **완성도(25):** provision뿐 아니라 **깔끔한 teardown + 잔여 검증**까지 = 인프라 성숙도.
- 🎯 **전문성(30):** 고아 리소스 의존성 추적(`describe-network-interfaces`)·복구 = 실전 트러블슈팅 역량. + **CUR 버킷 의존성 순서, finalizer 유무에 따른 삭제 경로 분기**(7장) + **실제 셸 스크립트 코드 리뷰로 계정가드 버그·설계 충돌을 사전에 잡아낸 것**(10장)까지 실전 트러블슈팅 역량으로 어필 가능.
- 🎯 **개선과제(10):** teardown 자동화 스크립트(→ 대부분 구현·검증 완료, 남은 건 팀 게이트 확정뿐) + Budgets/Scheduler 연동(미구현) + **"제3자 즉시 복제 가능 수준"의 완전한 운영지침서**(9장 3개 병목 해소 — ArgoCD 설치 자동화, ESO CRD 주소 고정, 시크릿 보관 정책) + **`app/teardown_infra.sh` 존속 여부 확정 및 필요 시 오케스트레이터 정식 편입**.

---

*최초 작성 2026-07-07 · 실습 teardown 사고 대응 경험 기반 · 갱신 시 Context 「비용 가드레일」 항목과 동기화*
*2026-07-28 대개정 — 이미선님 실전 런북 3종 반영, 조용빈님 #58 검토 코멘트 반영*
*2026-07-28 3차 개정 — 실제 teardown 스크립트 4종 코드 리뷰·재작성본 배포, `app/teardown_infra.sh` 존속 여부는 그룹 B 확인 대기 중*
*2026-07-29 4차 개정 — 미선님 PR 리뷰 2건 반영: 10장 오탐 정정(계정가드 정상), 10-4 해결 확정(app #40), infra 스크립트 순서 서술 실물 동기화*
*2026-07-30 5차 개정 — 용빈님 지적 반영: teardown.sh 첫 실행이 infra ALB 가드에서 정상 중단됨을 10-2절에 명시(3단계 수동 실행 흐름·plan -destroy 리허설 분기 포함), 코드 무변경*
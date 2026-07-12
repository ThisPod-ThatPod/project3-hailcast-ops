# teardown 체크리스트 (hailcast)

전체 자원을 내리기 전·후에 **사람이 눈으로 확인**하는 절차서. 실행 지휘는 `scripts/teardown.sh`가 하지만,
데이터 유실·과금 잔존·삭제 순서 사고는 이 체크리스트로 막는다.

> 실행 순서 요약:  ① manifest(K8s·ALB) → ② infra(terraform destroy) → ③ app(로컬 청소)
> 지휘 명령:       `bash scripts/teardown.sh`  (단계별 y/N 확인)

---

## 0. 시작 전 — 안전 확인 (데이터·비용)

- [ ] **정말 내려도 되는가?** 데모/발표 일정과 겹치지 않는지 팀 공유.
- [ ] **RDS 데이터 보존 필요?** `skip_final_snapshot=true`라 destroy 시 **사라진다.** 남길 거면 스냅샷 먼저:
      `aws rds create-db-snapshot --db-instance-identifier hailcast-dev-rds-postgres --db-snapshot-identifier hailcast-dev-final-YYYYMMDD --region ap-northeast-2`
- [ ] **S3 모델/예측 JSON 보존 필요?** `force_destroy=true`라 객체째 삭제됨. 남길 거면 로컬로 내려받기.
- [ ] **현재 비용 확인** — Budgets/Cost Explorer로 오늘까지 과금 스냅샷(사후 비교용).
- [ ] 형제 폴더 구조 정상(`~/project3-hailcast/` 아래 4개), `aws sts get-caller-identity` = tptp 계정, region=ap-northeast-2.

## 1. manifest 정리 (가장 먼저 — VPC destroy 막는 원인 제거)

- [ ] ArgoCD Application(또는 helm/kubectl)로 워크로드 삭제.
- [ ] **Ingress(ALB)·LoadBalancer 서비스가 사라졌는지 확인** — 이게 남으면 infra destroy가 VPC에서 몇 시간 막힌다.
      `kubectl get ingress -A` / `kubectl get svc -A | grep -i loadbalancer`  → **비어 있어야 정상.**
- [ ] AWS 콘솔 EC2 → Load Balancers 에서 `k8s-...` ALB 없음 확인.

## 2. infra 정리 (terraform destroy)

- [ ] (1번이 끝난 뒤) `teardown_infra.sh` 실행 → `terraform destroy`.
- [ ] destroy 완료 로그에 error 없음.
- [ ] **잔여 리소스 수동 확인**(terraform 밖에서 생긴 것들):
  - [ ] ENI(네트워크 인터페이스) 남은 것
  - [ ] EBS 볼륨 / 스냅샷
  - [ ] Elastic IP(미연결 시 과금)
  - [ ] NAT Gateway
  - [ ] CloudWatch 로그 그룹(`/aws/eks/...`, `/aws/rds/...`)
  - [ ] (부트스트랩) tfstate 버킷 `hailcast-dev-tfstate-9dcb` 은 **일부러 남긴다**(Terraform 관리 밖). 완전 종료 시에만 수동 삭제.

## 3. app 정리 (각자 로컬 — 맨 마지막)

- [ ] `teardown_app.sh`로 로컬 도커 이미지·볼륨·빌드캐시 정리(다음 apply를 깨끗하게).
- [ ] 필요 시 각 팀원 서버에서 개별 실행(로컬이라 서버마다 따로).

## 4. 종료 후 — 비용 0 확인

- [ ] 30분~1시간 뒤 Cost Explorer에서 **EKS·NAT·RDS·노드 과금이 멈췄는지** 확인.
- [ ] 예상외 과금이 남으면 위 "잔여 리소스"를 다시 훑는다(대개 ENI·EIP·ALB).

---

### 파일 배치 (참고)
| 파일 | 위치 | 소유 |
|---|---|---|
| `teardown_manifest.sh` | manifests/scripts | 그룹 C |
| `teardown_infra.sh` | infra/scripts | 그룹 A |
| `teardown_app.sh` | app/scripts | 그룹 B |
| `teardown.sh`(지휘) | **ops**/scripts | 팀장 |
| `teardown_체크리스트.md` | **ops** | 팀장 |
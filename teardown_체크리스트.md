# teardown 체크리스트 (hailcast)

전체 자원을 내리기 전·후에 **사람이 눈으로 확인**하는 절차서. 실행 지휘는 `scripts/teardown.sh`가 하지만,
데이터 유실·과금 잔존·삭제 순서 사고는 이 체크리스트로 막는다.

> ⚠️ **[2026-07 변경]** `make destroy-all-yes` 는 이제 **실제로 전 자원을 삭제**한다.
> (이전엔 CONFIRM 미주입이라 미리보기만 됐지만, teardown_infra.sh + ops CONFIRM 주입 반영 후 진짜 destroy 가 돈다.)
> 자동 안전장치 2개가 걸리지만, **이 체크리스트를 먼저 훑는 것**이 우선이다.
> - **계정가드:** 현재 AWS 계정이 공용(tptp)이 아니면 시작 전에 스스로 중단.
> - **ALB 가드:** K8s 가 만든 ALB 가 살아있으면 infra destroy 가 멈춤(manifest 를 먼저 지우라는 뜻).

> 실행 순서 요약:  ① manifest(K8s·ALB) → ② infra(terraform destroy) → ③ app(로컬 청소)
> 지휘 명령:       `bash scripts/teardown.sh`  (단계별 y/N 확인)

---

## 실행 방법 (ops 지휘자 기준)

- 단계별 확인하며:   `make destroy-all`      또는  `bash scripts/teardown.sh`
- 확인 생략(주의):   `make destroy-all-yes`  또는  `bash scripts/teardown.sh --yes`
- 한 단계만:         `bash scripts/teardown.sh --only infra`

**안전 스위치 (스크립트 직접 실행 시)**
- `CONFIRM=yes` : 실제 destroy 를 돌린다. 없으면 infra 는 `plan -destroy` 미리보기만.
  - ops 의 `destroy-all` 은 infra 단계에 이걸 **자동 주입**한다(사람이 칠 필요 없음).
- `FORCE=yes`   : ALB 가 살아있어도 강행한다. **자동 주입 안 됨 — 사람이 직접 지정해야 함.**
  - 정상 흐름에선 쓸 일 없음. manifest 를 먼저 지우면 ALB 가 사라져 FORCE 가 불필요.
- `EXPECTED_ACCOUNT` : 공용(tptp) 계정 12자리 ID. 스크립트 상단 상수. 다른 계정이면 중단.

---

## 0. 시작 전 — 안전 확인 (데이터·비용)

- [ ] **정말 내려도 되는가?** 데모/발표 일정과 겹치지 않는지 팀 공유.
- [ ] **RDS 데이터 보존 필요?** `skip_final_snapshot=true`라 destroy 시 **사라진다.** 남길 거면 스냅샷 먼저:
      `aws rds create-db-snapshot --db-instance-identifier hailcast-dev-rds-postgres --db-snapshot-identifier hailcast-dev-final-YYYYMMDD --region ap-northeast-2`
- [ ] **S3 모델/예측 JSON 보존 필요?** `force_destroy=true`라 객체째 삭제됨. 남길 거면 로컬로 내려받기.
      ※ 현재 유현상님 S3 PR(#27)은 `force_destroy=false`라 destroy 가 `BucketNotEmpty`로 막힐 수 있음 → 그 PR에서 dev 기본값 true 로 정리 예정.
- [ ] **현재 비용 확인** — Budgets/Cost Explorer로 오늘까지 과금 스냅샷(사후 비교용).
- [ ] 형제 폴더 구조 정상(`~/project3-hailcast/` 아래 4개), `aws sts get-caller-identity` = **tptp 계정**, region=ap-northeast-2.
      ※ 계정가드가 자동 확인하지만, 사람도 눈으로 한 번 더 본다.

## 1. manifest 정리 (가장 먼저 — VPC destroy 막는 원인 제거)

- [ ] ArgoCD Application(또는 helm/kubectl)로 워크로드 삭제.
- [ ] **Ingress(ALB)·LoadBalancer 서비스가 사라졌는지 확인** — 이게 남으면 infra destroy가 VPC에서 몇 시간 막힌다.
      `kubectl get ingress -A` / `kubectl get svc -A | grep -i loadbalancer`  → **비어 있어야 정상.**
- [ ] AWS 콘솔 EC2 → Load Balancers 에서 `k8s-...` ALB 없음 확인.
      ※ 여기가 안 비면 infra 단계의 ALB 가드가 destroy 를 막는다(정상 동작).
      ※ ALB 조회 자체가 실패해도(자격·권한·리전) 안전상 중단한다.

## 2. infra 정리 (terraform destroy)

- [ ] (1번이 끝난 뒤) `teardown_infra.sh` 실행 → `terraform destroy`.
      ※ ops 의 `destroy-all` 로 돌리면 CONFIRM=yes 가 자동 주입돼 실제 destroy 가 돈다.
      ※ 단독 실행 시엔 `CONFIRM=yes bash scripts/teardown_infra.sh` (없으면 미리보기만).
- [ ] destroy 완료 로그에 error 없음. (`set -euo pipefail`이라 실패 시 즉시 중단된다.)
- [ ] **잔여 리소스 수동 확인**(terraform 밖에서 생긴 것들):
  - [ ] ENI(네트워크 인터페이스) 남은 것
  - [ ] EBS 볼륨 / 스냅샷
  - [ ] Elastic IP(미연결 시 과금)
  - [ ] NAT Gateway
  - [ ] CloudWatch 로그 그룹(`/aws/eks/...`, `/aws/rds/...`)
  - [ ] (부트스트랩) tfstate 버킷 **`hailcast-dev-tfstate-9dcd`** 은 **일부러 남긴다**(Terraform 관리 밖). 완전 종료 시에만 수동 삭제.

## 3. app 정리 (각자 로컬 — 맨 마지막)

- [ ] `teardown_app.sh`로 로컬 도커 이미지·볼륨·빌드캐시 정리(다음 apply를 깨끗하게).
- [ ] 필요 시 각 팀원 서버에서 개별 실행(로컬이라 서버마다 따로).
      ※ app 단계는 클라우드가 아니라 로컬 청소라, 계정가드 대상이 아니다(`--only app`은 계정검사 건너뜀).

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
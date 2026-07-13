# project3-hailcast-ops

이 Pod 저 Pod · **hailcast** 프로젝트의 **운영 도구 레포**입니다.
proj-mgmt(운영 콘솔) 환경 세팅과, 세 레포(infra·app·manifests)를 `make -C`로 위임 호출하는 **최상위 오케스트레이터**를 담습니다.

> 상세한 "왜 이 레포가 필요한가 / 기대효과" 문서는 별도 공유 예정(구현 안정화 후).

---

## 폴더 레이아웃 — 팀 공통 규칙 (반드시 통일)

위임(`make -C ../...`)과 스마트 cd 격리가 정확히 동작하려면, **모든 팀원이 아래 구조로 통일**해서 clone 해야 합니다. 바구니 폴더 이름(`project3-hailcast`)과 각 레포 이름을 그대로 지켜주세요.

```
~/project3-hailcast/                    ← 로컬 바구니 (git 아님 · git init 금지)
├── project3-hailcast-app               ← 그룹 B (앱·AI)
├── project3-hailcast-infra             ← 그룹 A (Terraform)
├── project3-hailcast-manifests         ← 그룹 C (K8s·GitOps)
└── project3-hailcast-ops         ★이 레포 (팀장 소유 · 운영 도구)
├── Makefile                        # 최상위 오케스트레이터 (make -C 위임)
├── README.md
├── teardown_체크리스트.md           # 전체 정리 절차(사람 확인용)
└── scripts/
├── setup.sh                    # proj-mgmt 도구 설치 + 자격 + kubeconfig
├── check.sh                    # 환경·EKS 연결 점검
└── teardown.sh                 # 전체 정리 지휘(manifest→infra→app)
```
> ⚠️ 이 규칙이 깨지면(예: 레포를 다른 위치·다른 이름으로 clone) `make infra-plan` 같은 위임 명령과
> Docker 계정 격리가 동작하지 않습니다. **`~/project3-hailcast/` 아래에 4개를 형제로** 두는 것으로 통일합니다.
> (개인 서버가 달라도 이 상대 구조만 같으면 됩니다.)

---

## 빠른 시작 (proj-mgmt · Rocky Linux 8)

```bash
# 0) ops 레포를 바구니 안에 clone
mkdir -p ~/project3-hailcast && cd ~/project3-hailcast
git clone https://github.com/ThisPod-ThatPod/project3-hailcast-ops.git
cd project3-hailcast-ops

# 1) 나머지 세 레포를 형제로 clone
make clone-all

# 2) 도구 설치 + 자격증명(공용 tptp) + Docker Hub(공용 hailscale) + kubeconfig
make setup

# 3) 환경 점검
make check
```

설치 도구: **AWS CLI v2 · Terraform · kubectl(1.35) · helm(3) · Docker(+Hub)**
(Tailscale·Ansible 없음 — AWS 단일·EKS·GitOps 아키텍처)

---

## 자격증명 원칙 (중요)

- **git·문서·대화에 키를 절대 두지 않습니다.** 값은 각자 서버 로컬에만 저장됩니다.
  - AWS: `aws configure` → `~/.aws` (팀 공용 계정 **tptp**)
  - Docker Hub: `.dockerhub_token`(chmod 600, git 밖) (팀 공용 계정 **hailscale**)
- `.gitignore`가 `.dockerhub_token` · `.docker_config/` · `*.csv` · `.terraform/` · `*.tfstate*`를 제외합니다.
- EKS 권한: 공용 tptp가 클러스터 생성자라 자동 admin(`bootstrap_cluster_creator_admin_permissions=true`). 개인 IAM 추가 필요 시 infra의 Access Entry로 등록.

### Docker Hub 계정 격리 (왜 / 되돌리는 법)

각 개인 서버(수업용 `mgmt` 등)에는 **이미 개인 Docker Hub 로그인**이 `~/.docker/config.json`에 있는 경우가 많습니다. 여기서 팀 공용(hailscale)으로 그냥 `docker login` 하면 **개인 로그인을 덮어씁니다.** 이를 막으려고 `setup.sh`가 `~/.bashrc`에 `cd()` 훅을 넣어, **이 ops 폴더 안에선 전용 금고(`.docker_config`)를, 폴더 밖에선 개인 계정을** 자동으로 쓰게 합니다.

- 적용: 새 터미널을 열거나 `source ~/.bashrc`
- **되돌리기:** `~/.bashrc`에서 `# hailcast-ops Docker Config 자동 격리 전환` 주석으로 시작하는 `cd() { ... }` 블록을 삭제하면 됩니다.

---

## 브랜치·머지 규칙 (초기: 팀장 단독)

ops 레포는 **배포 대상이 아니라 도구**이고 초기엔 팀장 단독 작업이라, 다른 세 레포와 달리 **셀프 머지**를 허용합니다.

- 브랜치: `main` 단일 (dev 없음).
- **PR 은 만들되(이력 목적) 승인 0으로 셀프 Squash 머지.**
  - GitHub → Settings → Branches → `main` ruleset: *Require a pull request = ON · Require approvals = 0*.
- 팀원 기여가 시작되면 → *Require approvals = 1* + "본인 승인 무효"로 올려 다른 레포와 동일 규칙으로 전환.

---

## 명령 (make help)

| 명령 | 설명 |
|---|---|
| `make setup` | proj-mgmt 도구 설치 + 자격 + kubeconfig |
| `make check` | 환경·자격·EKS 연결 점검 |
| `make clone-all` | 세 레포 형제 clone |
| `make kubeconfig` | EKS kubeconfig 갱신(apply 후) |
| `make infra-plan` / `infra-apply` / `infra-destroy` | infra 레포 위임 |
| `make app-build-push` | app 레포 위임(ECR push) |
| `make deploy` | manifests 레포 위임(helm/argocd) |
| `make destroy-all` | 전체 정리 지휘(manifest→infra→app · 단계별 확인) |
| `make destroy-all-yes` | ⚠️ 전체 정리(확인 생략) — **실제로 전부 삭제됨. 미리보기 아님.** |

> 위임(`infra-*`·`app-*`·`deploy`) 명령은 각 레포에 Makefile 이 있어야 동작합니다(각 레포 Makefile 추가 후 활성).

---

## 전체 정리 (teardown)

자원이 서로 엮여 있어 **삭제 순서가 중요**합니다(순서 틀리면 VPC destroy가 몇 시간 막힘). ops가 순서를 통제합니다.

```bash
make destroy-all          # ① manifest(K8s·ALB) → ② infra(terraform destroy) → ③ app(로컬 청소)
```

- **삭제 본체는 각 레포**가 소유합니다: `manifests|infra|app/scripts/teardown_*.sh` (그 레포에서 `make teardown`으로 단독 실행도 가능).
- **ops의 `teardown.sh`가 지휘**만 합니다 — 단계별 y/N 확인, 한 단계 실패 시 다음으로 자동 진행하지 않음.
- **시작 전 반드시 `teardown_체크리스트.md`** 를 확인하세요(RDS/S3 데이터는 destroy 시 사라짐 · 스냅샷 · Budgets · 사후 잔여 리소스 ENI·EIP·ALB).
- ⚠️ manifest를 먼저 안 지우면 살아있는 ALB·ENI가 VPC destroy를 막습니다 — 그래서 manifest가 1순위입니다.

### ⚠️ 실제 삭제로 동작이 바뀌었습니다

`make destroy-all-yes` 는 예전엔 CONFIRM 미주입이라 아무것도 안 지웠지만, 이제 **실제로 전 자원을 삭제**합니다. "예전에 돌려봤는데 아무 일 없던" 명령이 아닙니다. 두 가지 안전장치가 자동으로 걸립니다:

- **계정가드:** 시작 전 현재 AWS 계정이 공용(tptp)인지 확인 → 다른 계정이면 중단.
- **ALB 가드:** K8s 가 만든 ALB 가 살아있으면 infra destroy 가 멈춤 → manifest 를 먼저 정리하라는 뜻.

| 환경변수 | 뜻 | 자동 주입 |
|---|---|---|
| `CONFIRM=yes` | 실제 destroy 실행 (없으면 infra 는 미리보기) | ops `destroy-all` 이 infra 에 주입 |
| `FORCE=yes` | ALB 경고 무시하고 강행 | **안 함 (사람이 직접 지정)** |
| `EXPECTED_ACCOUNT` | 공용 계정 ID 검증 | 스크립트 상단 상수(기본값) |
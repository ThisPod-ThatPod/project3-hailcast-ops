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
│   └── docs/네이밍규약서.md              ★ 팀 전체의 계약 (원본 · SSOT)
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
  - AWS: `aws configure --profile hailcast` → `~/.aws` (팀 공용 계정 **tptp**)
  - Docker Hub: `.dockerhub_token`(chmod 600, git 밖) (팀 공용 계정 **hailscale**)
- `.gitignore`가 `.dockerhub_token` · `.docker_config/` · `*.csv` · `.terraform/` · `*.tfstate*`를 제외합니다.
- EKS 권한: 공용 tptp가 클러스터 생성자라 자동 admin(`bootstrap_cluster_creator_admin_permissions=true`). 개인 IAM 추가 필요 시 infra의 Access Entry로 등록.

### AWS 프로필 분리 + 계정 가드 (왜)

공용 키를 `[default]`에 두지 않고 **`hailcast` 프로필**에 담습니다. 이유가 둘입니다.

1. **공용 키가 default에 앉으면** 그 서버의 모든 `aws`·`terraform` 기본 계정이 공용 계정이 됩니다. 팀원이 강의 실습으로 만든 EC2·S3가 **공용 계정에 생기고**, Terraform이 만든 게 아니라 `ManagedBy=terraform` 태그가 없어 **비용 집계에서 누락된 채 과금**됩니다.
2. **개인 키가 default에 남아 있으면** 예전 `setup.sh`는 그냥 통과시켰습니다. 계정 ID를 **출력만** 하고 tptp인지 대조하지 않았기 때문입니다. 그래서 개인 계정에 앉은 채로 `setup`도 `check`도 **전부 초록불**이 떴습니다.

그래서 두 가지를 넣었습니다.

**① 프로필 분리** — `Makefile`이 `AWS_PROFILE=hailcast`를 export합니다. `make -C`로 위임되는 각 레포의 terraform도 이 프로필을 씁니다. **개인 `[default]`는 건드리지 않습니다.**

**② 계정 가드** — `sts get-caller-identity` 결과를 **tptp 계정 ID와 대조**합니다. 상수와 가드 함수는 `scripts/_lib.sh` **한 곳**에만 있습니다.

| 어디서 | 계정이 tptp가 아니면 |
|---|---|
| `make setup` | **즉시 중단** |
| `make check` | ❌ 빨간불 + 마지막에 **`exit 1`** (나머지 점검은 마저 보여줌) |
| `make infra-init` · `plan` · `apply` · `destroy` | **즉시 중단** (`guard-account` 선행) |
| `make kubeconfig` · `app-build-push` · `deploy` | **즉시 중단** (`guard-account` 선행) |
| `make destroy-all` | **즉시 중단** (`teardown.sh` 가드) |
| `make infra-fmt` | 가드 없음 — **자격증명이 아예 필요 없는 작업**이라 일부러 뺐습니다 |

**`make infra-apply`에 가드가 왜 필요한가.** `teardown.sh`가 destroy를 막아도 `make infra-destroy`는 그 스크립트를 거치지 않고 곧장 terraform으로 갑니다. 가드를 `setup`·`check`·`teardown`에만 두면 **정작 돈이 나가고 자원이 파괴되는 경로가 비어 있게 됩니다.**

### 터미널에서 직접 쓸 때

```bash
export AWS_PROFILE=hailcast
aws sts get-caller-identity     # 계정이 tptp 인지 눈으로 확인
```

⚠️ **환경변수 자격증명(`AWS_ACCESS_KEY_ID` 등)은 프로필보다 우선합니다.** 셸에 남아 있으면 프로필을 아무리 잘 잡아도 그 키가 쓰입니다. `setup.sh`가 감지해 경고하지만, 미리 지워두는 게 낫습니다.

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

### Docker Hub 계정 격리 (왜 / 되돌리는 법)

각 개인 서버(수업용 `mgmt` 등)에는 **이미 개인 Docker Hub 로그인**이 `~/.docker/config.json`에 있는 경우가 많습니다. 여기서 팀 공용(hailscale)으로 그냥 `docker login` 하면 **개인 로그인을 덮어씁니다.** 이를 막으려고 `setup.sh`가 `~/.bashrc`에 `cd()` 훅을 넣어, **이 ops 폴더 안에선 전용 금고(`.docker_config`)를, 폴더 밖에선 개인 계정을** 자동으로 쓰게 합니다.

- 적용: 새 터미널을 열거나 `source ~/.bashrc`
- **되돌리기:** `~/.bashrc`에서 `# hailcast-ops Docker Config 자동 격리 전환` 주석으로 시작하는 `cd() { ... }` 블록을 삭제하면 됩니다.

---

## 📖 네이밍 규약서 — 팀 전체의 계약 (원본은 infra)

**이름은 곧 계약입니다.** 리소스 이름·IRSA 역할명·SA 이름·예측 지표 키 같은 문자열을 앱·ML·배포팀이 **코드에 그대로 참조**합니다. 한 글자만 어긋나도 대개 **에러 없이 조용히** 죽습니다.

### 👉 [`docs/네이밍규약서.md`](../project3-hailcast-infra/docs/네이밍규약서.md) (infra 레포)

> [GitHub 에서 보기](https://github.com/ThisPod-ThatPod/project3-hailcast-infra/blob/dev/docs/네이밍규약서.md) · `make clone-all` 을 돌렸다면 **이미 로컬에 있습니다**(위 폴더 레이아웃 참조).

**원본은 infra 에 두고 여기엔 링크만 겁니다. 복사하지 않습니다.**

- **문서가 두 벌이 되면 반드시 갈라집니다.** 그리고 갈라진 걸 아무도 눈치채지 못합니다.
- 규약서 값의 대부분이 **인프라가 만드는 리소스 이름**이라, **문서와 코드가 같은 PR 에 담겨야** 어긋나지 않습니다. 레포를 가르면 "코드는 바뀌었는데 문서는 그대로"인 상태가 리뷰에서 안 보이게 됩니다.
- 파일은 이미 전원 로컬에 있습니다(`make clone-all` 이 infra 까지 받습니다). **문제는 위치가 아니라 가리키는 손가락이 없다는 것**이었습니다.

### 규약을 고쳐야 할 때

규약과 코드가 다르다고 **무조건 코드가 틀린 게 아닙니다.** 두 방향으로 나뉩니다.

| | 판정 | 누가 고치나 |
|---|---|---|
| **(가)** | 규약이 맞다 | **해당 팀이 코드를 고친다** |
| **(나)** | 코드가 더 낫다 (현실이 앞섰다) | **인프라가 규약을 고친다** (근거 첨부 PR) |

> 지도와 실제 길에 비유하면, 대개는 길을 지도대로 가지만 **길이 더 좋게 났으면 지도를 고칩니다.**

- **어긋남을 발견하면 조용히 두지 말고 신고해 주세요.** 잘못이 아니라 규약이 못 따라간 것일 수도 있습니다.
- (나) 로 판정되면 인프라가 **infra(문서·코드) + ops(검증기) 짝 PR** 로 올립니다. 레포가 달라 하나로 못 묶으니 서로 링크를 겁니다.
- 개정이 머지되면 팀장이 **"규약 §N 이 바뀌었습니다"** 를 팀에 공지합니다.

---

## 브랜치·머지 규칙

ops 는 **배포 대상이 아니라 운영 도구**이고 사실상 팀장 단독 작업이라, 다른 세 레포와 달리 **가볍게 갑니다.**

- 브랜치: `main` 단일 (dev 없음).
- **branch protection(ruleset)은 걸지 않습니다** (팀 결정). 실제로 `main` 은 `protected: false` 이고 ruleset 의 enforcement 가 비활성이라 **직접 push 가 됩니다**(2026-07-13 확인).
- PR 은 이력·리뷰 목적으로 자유롭게 씁니다. 승인 없이 셀프 Squash 머지.

### 🔔 CODEOWNERS — 게이트가 아니라 알림입니다

`.github/CODEOWNERS` 가 **teardown 계열 파일**에 리뷰어를 걸어 둡니다.

| | ruleset 없이 되나 |
|---|---|
| 해당 파일이 바뀐 **PR 이 열리면 자동으로 리뷰어 지정** | ✅ **됩니다** |
| 리뷰어 승인 없이는 **머지를 막는다** | ❌ ruleset 이 있어야 합니다 |

**즉 막지는 않고 놓치지 않게만 합니다.** `main` 에 직접 push 하면 당연히 안 걸립니다.

**함정 두 가지** (GitHub 공식 문서)

- **CODEOWNERS 는 PR 의 base 브랜치(`main`)에 있어야 동작합니다.** 이 파일을 추가하는 PR 자체에는 리뷰 요청이 안 뜹니다. **머지된 뒤부터** 유효합니다.
- **GitHub 은 PR 작성자 본인에게는 리뷰 요청을 보내지 않습니다.** 이미선이 직접 여는 PR 에는 안 뜹니다. **실효 대상은 팀장이 여는 teardown PR** 입니다.

> ⚠️ 한글 경로(`teardown_체크리스트.md`)는 문법 검증은 통과했지만 공식 문서가 non-ASCII 매칭을 보증하지 않습니다. **머지 후 한 번 실증**이 필요합니다.

**왜 teardown 만 거는가.** ops 는 팀원 전원 서버에서 실행되고 **AWS 를 통째로 지웁니다.** 실행 반경이 다른 레포보다 큽니다. 전체를 승인 필수로 만들면 속도가 죽으니 **삭제를 수행하는 파일에만** 리뷰를 겁니다.

**대상:** `scripts/teardown.sh` · `teardown_체크리스트.md` · `scripts/_lib.sh` · `scripts/guard_account.sh` (계정 가드)

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
| `make destroy-all` | ⚠️ 전체 정리 지휘(manifest→infra→app · 단계별 y/N 확인) — **y 누르면 실제 삭제됨** |
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
  ALB **조회 자체가 실패**해도(자격증명·권한·리전 어긋남) 안전을 위해 중단한다 → "ALB 없는데 왜 멈추지?" 가 아니라 조회 실패다.

| 환경변수 | 뜻 | 자동 주입 |
|---|---|---|
| `CONFIRM=yes` | 실제 destroy 실행 (없으면 infra 는 미리보기) | ops `destroy-all` 이 infra 에 주입 |
| `FORCE=yes` | ALB 경고 무시하고 강행 | **안 함 (사람이 직접 지정)** |
| `TPTP_ACCOUNT_ID` | 공용 계정 ID 검증 | `scripts/_lib.sh` 상수 (한 곳에만 둔다) |
| `AWS_PROFILE` | 공용 계정 프로필 | `Makefile` 이 `hailcast` 로 export |
# =============================================================
# 파일위치 : ~/project3-hailcast/project3-hailcast-ops/Makefile
# 이 Pod 저 Pod · hailcast — 최상위 오케스트레이터
# 각 레포(infra/app/manifests)의 Makefile 에 make -C 로 '위임'한다.
#   → 총괄(ops)은 각 레포 내부 스크립트를 몰라도 "target 이름"만 알면 된다.
# 사용법: 레포 루트(project3-hailcast-ops)에서  make [명령]   /  make help
# =============================================================

# 이 프로젝트 명령이 실행하는 모든 docker 명령은 공용 계정(hailscale) 격리 config 를 바라본다
export DOCKER_CONFIG := $(CURDIR)/.docker_config

# ── 형제 레포 경로 (모두 같은 상위 폴더에 clone 되어 있다고 가정) ──
INFRA_DIR     ?= ../project3-hailcast-infra
APP_DIR       ?= ../project3-hailcast-app
MANIFESTS_DIR ?= ../project3-hailcast-manifests

# ── AWS 자격증명 : 프로필을 강제하지 않는다 ──
# AWS 기본 자격증명 체인(환경변수 → AWS_PROFILE → [default])을 그대로 쓴다.
#
# 옛 버전은 AWS_PROFILE := hailcast 를 강제했다. 프로젝트 계정과 담당자 개인 계정이
# '달랐을 때' 공용 키가 개인 [default] 를 덮어쓰는 걸 막으려던 장치다.
# 2026-07-14 부터 프로젝트 계정 = 담당자 개인 계정이라 그 전제가 사라졌고,
# 강제를 남기면 [default] 를 쓰는 서버와 CI(OIDC 환경변수) 양쪽에서 죽는다.
#
# 안전망은 프로필 이름이 아니라 '어느 계정에 서 있는가' 다
#   → guard-account target (scripts/guard_account.sh · scripts/_lib.sh)

# ── EKS 접속 상수 ──
CLUSTER_NAME ?= hailcast-dev-eks
AWS_REGION   ?= ap-northeast-2

# ── GitHub org (clone-all 용) ──
ORG_URL := https://github.com/ThisPod-ThatPod

.PHONY: help setup check check-contract clone-all kubeconfig guard-account \
        infra-init infra-fmt infra-plan infra-apply infra-destroy \
        app-build-push deploy destroy-all destroy-all-yes

help: ## 명령 목록
	@echo ""
	@echo "====================================================="
	@echo "   이 Pod 저 Pod · hailcast — ops 명령어"
	@echo "====================================================="
	@echo ""
	@echo "  [ 초기 설정 ]"
	@echo "  make setup          proj-mgmt 도구 설치 + 자격증명 + kubeconfig"
	@echo "  make check          환경·자격증명·EKS 연결 점검"
	@echo "  make clone-all      infra/app/manifests 세 레포를 형제로 clone"
	@echo "  make kubeconfig     EKS kubeconfig 갱신 (apply 이후)"
	@echo ""
	@echo "  [ 계약 검증 ]"
	@echo "  make check-contract 규약서(이름 계약)와 실제 코드·실물이 어긋났는지 검사"
	@echo ""
	@echo "  [ 위임 — infra (그룹 A) ]"
	@echo "  make infra-init     terraform init"
	@echo "  make infra-fmt      terraform fmt"
	@echo "  make infra-plan     terraform plan"
	@echo "  make infra-apply    terraform apply   (비용 시작 — 팀 합의 후)"
	@echo "  make infra-destroy  terraform destroy"
	@echo ""
	@echo "  [ 위임 — app (그룹 B) / manifests (그룹 C) ]"
	@echo "  make app-build-push docker build·push (ECR)"
	@echo "  make deploy         manifests helm/argocd 배포"
	@echo ""
	@echo "  [ 정리 ]"
	@echo "  make destroy-all     manifest→infra→app 순 전체 정리(단계별 확인)"
	@echo "  make destroy-all-yes 전체 정리(확인 생략 — 주의)"
	@echo ""
	@echo "  ※ 위임 명령은 각 레포에 Makefile 이 있어야 동작한다(Phase 4에서 각 레포 Makefile 추가)."
	@echo ""

# ── 존재 확인 가드: 상대경로 레이아웃 가정을 강제한다 ──
define REQUIRE_DIR
	@if [ ! -d "$(1)" ]; then \
		echo "❌ $(1) 없음 → 'make clone-all' 로 형제 레포를 먼저 받으세요."; \
		exit 1; \
	fi
endef

# ── 초기 설정 ─────────────────────────────────────────────
setup: ## 도구 설치 + 자격 + kubeconfig
	@chmod +x scripts/setup.sh scripts/check.sh
	./scripts/setup.sh

check: ## 환경 점검
	@chmod +x scripts/check.sh
	./scripts/check.sh

# ── 이름 계약 검증 ────────────────────────────────────────
# 규약서(docs/네이밍규약서.md)가 단일 진실원천이다. 그 이름들을 앱·ML·배포팀이 코드에
# 그대로 참조하므로, 한 글자만 어긋나도 대개 '에러 없이 조용히' 죽는다.
# 이 검증기가 그걸 시연 직전이 아니라 매일 잡는다.
#
# ⚠️ guard-account 를 선행조건으로 걸지 않는다. 걸면 자격증명이 없을 때 시작조차 못 하는데,
#    정적 검사(terraform 소스 대조)는 자격증명 없이 돌아야 한다(비용관리.md §0).
#    계정 대조는 스크립트 안에서 하고, 아니면 런타임 검사만 건너뛴다.
check-contract: ## 규약서 이름 계약 검사 (정적: 항상 · 런타임: apply 이후)
	$(call REQUIRE_DIR,$(INFRA_DIR))
	@chmod +x scripts/check_contract.sh
	@INFRA_DIR="$(INFRA_DIR)" ./scripts/check_contract.sh

clone-all: ## 세 레포를 형제로 clone (이미 있으면 건너뜀)
	@for r in infra app manifests; do \
		d="../project3-hailcast-$$r"; \
		if [ -d "$$d" ]; then \
			echo "⏭  $$d 이미 있음 → 건너뜀"; \
		else \
			echo "⬇️  clone $$d"; \
			git clone -b dev "$(ORG_URL)/project3-hailcast-$$r.git" "$$d" || git clone "$(ORG_URL)/project3-hailcast-$$r.git" "$$d"; \
		fi; \
	done

# ── 계정 가드 : AWS 를 만지는 target 의 선행조건 ───────────
# 이게 없으면 make infra-apply 가 계정 대조 없이 곧장 terraform 을 돌린다.
# teardown.sh 가 destroy 를 막아도 make infra-destroy 는 그 스크립트를 안 거친다.
# fmt 만 예외다 — 자격증명이 아예 필요 없다(docs/비용관리.md §0).
guard-account: ## 지금 자격증명이 프로젝트 계정인지 대조 (아니면 중단)
	@bash scripts/guard_account.sh

kubeconfig: guard-account ## EKS kubeconfig 갱신
	aws eks update-kubeconfig --name $(CLUSTER_NAME) --region $(AWS_REGION)

# ── 위임 : infra (그룹 A) ─────────────────────────────────
infra-init:    guard-account ; $(call REQUIRE_DIR,$(INFRA_DIR)) ; make -C $(INFRA_DIR) init
infra-fmt:                   ; $(call REQUIRE_DIR,$(INFRA_DIR)) ; make -C $(INFRA_DIR) fmt
infra-plan:    guard-account ; $(call REQUIRE_DIR,$(INFRA_DIR)) ; make -C $(INFRA_DIR) plan
infra-apply:   guard-account ; $(call REQUIRE_DIR,$(INFRA_DIR)) ; make -C $(INFRA_DIR) apply
infra-destroy: guard-account ; $(call REQUIRE_DIR,$(INFRA_DIR)) ; make -C $(INFRA_DIR) destroy

# ── 위임 : app (그룹 B) / manifests (그룹 C) ──────────────
app-build-push: guard-account ; $(call REQUIRE_DIR,$(APP_DIR))       ; make -C $(APP_DIR) build-push
deploy:         guard-account ; $(call REQUIRE_DIR,$(MANIFESTS_DIR)) ; make -C $(MANIFESTS_DIR) deploy

# ── 정리 : teardown 지휘 스크립트에 위임 (manifest→infra→app 순서·안전 통제) ──
destroy-all: ## 전체 정리 (manifest→infra→app 순 · 단계별 확인)
	@chmod +x scripts/teardown.sh
	./scripts/teardown.sh

destroy-all-yes: ## 전체 정리 (확인 생략 — 주의)
	@chmod +x scripts/teardown.sh
	./scripts/teardown.sh --yes
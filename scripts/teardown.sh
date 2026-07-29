#!/bin/bash
# =============================================================
# 파일위치 : ~/project3-hailcast/project3-hailcast-ops/scripts/teardown.sh
# 이 Pod 저 Pod · hailcast — 전체 자원 정리 '지휘자'
# 역할    : 각 레포의 teardown 스크립트를 '올바른 순서'로 호출한다.
#           삭제 로직 자체는 각 레포가 소유(self-contained). 여기선 순서·안전·게이트값 전달만 통제.
# 순서    : ① manifest(K8s·ALB) → ② infra(terraform destroy) → ③ app(로컬 이미지·볼륨)
#           ※ manifest 를 먼저 안 지우면 살아있는 ALB·ENI 가 VPC destroy 를 막는다(몇 시간 삽질).
#           ※ app 은 클라우드가 아니라 '각자 로컬' 청소라 맨 뒤(실패해도 클라우드 무영향).
#
#   ⚠️ [미해결] app/scripts/teardown_infra.sh 는 이 오케스트레이터가 호출하지 않는다.
#      manifest 단계(ArgoCD)와 삭제 대상(hailcast 네임스페이스)이 겹치는 것으로 파악돼
#      팀 확인 전까지 의도적으로 제외했다. 필요하다고 결론나면 이 파일의
#      "APP_INFRA 단계(선택)" 섹션 주석을 풀고 순서를 정해 넣을 것.
#
# 실행    : bash scripts/teardown.sh                  (단계별 확인)
#           bash scripts/teardown.sh --yes             (확인 생략 — 주의)
#           bash scripts/teardown.sh --only infra       (한 단계만)
# 게이트값 : teardown_체크리스트.md 6장 팀 결정을 아래 환경변수로 하위 스크립트에 전달한다.
#           ARGOCD_DELETE_PATH=argocd|kubectl   (게이트② — manifest 단계가 읽음, 기본 kubectl)
#           CUR_HANDLING=keep|drop              (게이트① — infra 단계가 읽음, 기본 미설정=강제 중단)
#           예) ARGOCD_DELETE_PATH=argocd CUR_HANDLING=keep bash scripts/teardown.sh --yes
# 전제    : teardown_체크리스트.md 를 '먼저' 훑을 것(스냅샷·Budgets 등 5개 게이트 전부 확정).
# 안전    : infra 단계에 CONFIRM=yes 를 주입해 '실제 destroy' 를 돌린다.
#           FORCE 는 주입하지 않는다 → ALB·Karpenter 노드가 살아있으면 사람이 경고를 보고 판단해야 한다.
#           실행 전 '지금 이 계정이 프로젝트 계정인지' 를 먼저 검증한다(오계정 전체삭제 방지).
# =============================================================

set -u

# ── 공용 상수·계정 가드 (PROJECT_ACCOUNT_ID · verify_project_account) ──
# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

INFRA_DIR="${INFRA_DIR:-../project3-hailcast-infra}"
APP_DIR="${APP_DIR:-../project3-hailcast-app}"
MANIFESTS_DIR="${MANIFESTS_DIR:-../project3-hailcast-manifests}"

# ── 게이트값(팀 결정) — 하위 스크립트가 읽도록 export ─────────────────
export ARGOCD_DELETE_PATH="${ARGOCD_DELETE_PATH:-kubectl}"   # 게이트② 기본값
export CUR_HANDLING="${CUR_HANDLING:-}"                      # 게이트① 미설정이면 infra 단계가 강제 중단

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[TEARDOWN]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}       $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}     $1"; }
err()   { echo -e "${RED}[ERROR]${NC}    $1"; }

AUTO_YES=false
ONLY=""
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) AUTO_YES=true ;;
        # set -u 라서 인자를 빼먹으면 'unbound variable' 로 터진다 → 뭘 넣어야 하는지 알려준다
        --only)   ONLY="${2:?--only 뒤에 manifest | infra | app 중 하나가 필요합니다}"; shift ;;
        *) err "알 수 없는 옵션: $1"; exit 1 ;;
    esac
    shift
done

# 단계 실행 헬퍼: (레포 디렉토리, teardown 스크립트 상대경로, 사람이 읽을 이름)
run_stage() {
    local dir="$1" script="$2" label="$3"
    [ -n "$ONLY" ] && [ "$ONLY" != "$label" ] && return 0

    echo ""
    info "───────── [$label] $dir/$script ─────────"
    if [ ! -d "$dir" ]; then
        warn "$dir 없음 → 이 단계 건너뜀 (clone 안 됐거나 경로 규칙 확인)"
        return 0
    fi
    if [ ! -f "$dir/$script" ]; then
        warn "$dir/$script 없음 → 아직 그 레포에 teardown 스크립트가 없음. 건너뜀"
        return 0
    fi

    if [ "$AUTO_YES" = false ]; then
        read -rp "  [$label] 진행할까요? (y/N) " ans
        case "$ans" in y|Y) ;; *) warn "[$label] 건너뜀"; return 0 ;; esac
    fi

    # infra 단계에만 CONFIRM=yes 를 주입해 '실제 destroy' 를 돌린다.
    #   FORCE 는 주입하지 않는다 → ALB·Karpenter 노드가 살아있으면 infra 스크립트가 사람 판단을 요구하며 멈춘다.
    #   manifest·app 은 각자 스크립트의 기본 동작을 그대로 따른다(CONFIRM 주입 없음 — 각 스크립트가
    #   자기 기본값을 따르되, 위에서 export한 ARGOCD_DELETE_PATH/CUR_HANDLING은 세 단계 모두에 이미 전달됨).
    local rc=0
    if [ "$label" = "infra" ]; then
        CONFIRM=yes bash "$dir/$script" || rc=$?
    else
        bash "$dir/$script" || rc=$?
    fi

    if [ "$rc" -eq 0 ]; then
        ok "[$label] 완료"
    else
        err "[$label] 실패 → 로그 확인 후 수동 조치. (다음 단계로 자동 진행하지 않음)"
        exit 1
    fi
}

echo ""
echo "============================================="
echo "  hailcast 전체 teardown (지휘자)"
echo "  순서: manifest → infra → app"
echo "  게이트②(삭제경로)=${ARGOCD_DELETE_PATH}  게이트①(CUR)=${CUR_HANDLING:-<미설정>}"
echo "============================================="

if [ -z "$CUR_HANDLING" ] && [ "$ONLY" != "manifest" ] && [ "$ONLY" != "app" ]; then
    warn "CUR_HANDLING이 설정되지 않았습니다 — infra 단계에서 CUR 버킷에 객체가 남아있으면 그 자리서 중단됩니다."
    warn "  팀 게이트① 결정 후: CUR_HANDLING=keep 또는 CUR_HANDLING=drop 으로 다시 실행하세요."
fi

# ── ⭐ 계정 가드 : 지우기 전에 '어느 계정인지' 먼저 대조한다 ──────────────
# 여기가 이 레포에서 가장 위험한 경로다. 잘못된 계정으로 destroy 가 돌면
# 되돌릴 방법이 없다. 그래서 확인 프롬프트보다 '먼저' 계정을 막는다.
# (--only app 은 로컬 도커 청소라 AWS 를 안 건드린다 → 가드 제외)
if [ "$ONLY" != "app" ]; then
    rc=0; verify_project_account || rc=$?
    case "$rc" in
        0) info "계정 확인 : ${CURRENT_ACCOUNT} (프로젝트 계정)" ;;
        1) err "프로젝트 계정이 아닙니다 → 현재 ${CURRENT_ACCOUNT} / 기대 ${PROJECT_ACCOUNT_ID}"
           err "teardown 을 중단합니다. 다른 계정의 자원을 지울 뻔했습니다."
           exit 1 ;;
        2) err "AWS 자격증명 없음/만료 → bash scripts/setup.sh"
           err "teardown 을 중단합니다."
           exit 1 ;;
    esac
fi

warn "시작 전 'teardown_체크리스트.md' 6장 게이트 5개(CUR·삭제경로·RDS스냅샷·ArgoCD설치주체·실제/리허설)를 다 정하셨나요?"
if [ "$AUTO_YES" = false ]; then
    read -rp "  계속하려면 y 입력: " go
    case "$go" in y|Y) ;; *) echo "중단."; exit 0 ;; esac
fi

# ① K8s 워크로드·ALB (VPC destroy 를 막는 것부터)
run_stage "$MANIFESTS_DIR" "scripts/teardown_manifest.sh" "manifest"

# ② AWS 자원 (terraform destroy) — CONFIRM=yes 주입은 run_stage 안에서
run_stage "$INFRA_DIR"     "scripts/teardown_infra.sh"    "infra"

# ── APP_INFRA 단계(선택, 현재 비활성) ─────────────────────────────
# app/scripts/teardown_infra.sh 를 오케스트레이션에 넣을지는 미결.
# 넣기로 정해지면: manifest 직후(=ArgoCD selfHeal이 아직 살아있는 동안 kubectl로
# 직접 지우면 충돌하므로) 가 아니라, manifest 완료 '이후' + infra 시작 '이전'으로 넣는 게
# 원칙적으로 맞다(ArgoCD가 이미 정리한 뒤 잔여물만 훑는 용도라면).
# run_stage "$APP_DIR" "scripts/teardown_infra.sh" "app-infra"

# ③ 로컬 도커 이미지·볼륨·캐시 (각자 로컬 청소 · 맨 뒤)
run_stage "$APP_DIR"       "scripts/teardown_app.sh"      "app"

echo ""
echo "============================================="
ok "teardown 지휘 종료. 잔여 리소스는 체크리스트로 최종 확인하세요."
echo "  (특히: ALB·ENI·EBS·Elastic IP·NAT·CloudWatch 로그그룹)"
echo "============================================="

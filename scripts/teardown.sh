#!/bin/bash
# =============================================================
# 파일위치 : ~/project3-hailcast/project3-hailcast-ops/scripts/teardown.sh
# 이 Pod 저 Pod · hailcast — 전체 자원 정리 '지휘자'
# 역할    : 각 레포의 teardown 스크립트를 '올바른 순서'로 호출한다.
#           삭제 로직 자체는 각 레포가 소유(self-contained). 여기선 순서·안전만 통제.
# 순서    : ① manifest(K8s·ALB) → ② infra(terraform destroy) → ③ app(로컬 이미지·볼륨)
#           ※ manifest 를 먼저 안 지우면 살아있는 ALB·ENI 가 VPC destroy 를 막는다(몇 시간 삽질).
#           ※ app 은 클라우드가 아니라 '각자 로컬' 청소라 맨 뒤(실패해도 클라우드 무영향).
# 실행    : bash scripts/teardown.sh            (단계별 확인)
#           bash scripts/teardown.sh --yes      (확인 생략 — 주의)
#           bash scripts/teardown.sh --only infra   (한 단계만)
# 전제    : teardown_체크리스트.md 를 '먼저' 훑을 것(스냅샷·Budgets 등).
# 안전    : infra 단계에 CONFIRM=yes 를 주입해 '실제 destroy' 를 돌린다.
#           FORCE 는 주입하지 않는다 → ALB 가 살아있으면 사람이 경고를 보고 판단해야 한다.
#           실행 전 '지금 이 계정이 프로젝트 계정인지' 를 먼저 검증한다(오계정 전체삭제 방지).
# =============================================================

set -u

# ── 공용 상수·계정 가드 (PROJECT_ACCOUNT_ID · verify_project_account) ──
# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

INFRA_DIR="${INFRA_DIR:-../project3-hailcast-infra}"
APP_DIR="${APP_DIR:-../project3-hailcast-app}"
MANIFESTS_DIR="${MANIFESTS_DIR:-../project3-hailcast-manifests}"

# ※ 프로젝트 계정 ID(PROJECT_ACCOUNT_ID)와 검증 함수(verify_project_account)는 scripts/_lib.sh 에 있다.
#   setup·check·teardown·make 가드가 같은 상수를 봐야 해서 한 곳으로 모았다.
#   스크립트마다 따로 박으면 계정이 바뀔 때 하나만 고치고 나머지가 낡는다.

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
    #   FORCE 는 주입하지 않는다 → ALB 가 살아있으면 infra 스크립트가 사람 판단을 요구하며 멈춘다.
    #   manifest·app 은 각자 스크립트의 기본 동작을 그대로 따른다(주입 없음).
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
echo "============================================="

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

warn "시작 전 'teardown_체크리스트.md' 를 확인하셨나요? (스냅샷·Budgets·잔여 리소스)"
if [ "$AUTO_YES" = false ]; then
    read -rp "  계속하려면 y 입력: " go
    case "$go" in y|Y) ;; *) echo "중단."; exit 0 ;; esac
fi

# ① K8s 워크로드·ALB (VPC destroy 를 막는 것부터)
run_stage "$MANIFESTS_DIR" "scripts/teardown_manifest.sh" "manifest"

# ② AWS 자원 (terraform destroy) — CONFIRM=yes 주입은 run_stage 안에서
run_stage "$INFRA_DIR"     "scripts/teardown_infra.sh"    "infra"

# ③ 로컬 도커 이미지·볼륨·캐시 (각자 로컬 청소 · 맨 뒤)
run_stage "$APP_DIR"       "scripts/teardown_app.sh"      "app"

echo ""
echo "============================================="
ok "teardown 지휘 종료. 잔여 리소스는 체크리스트로 최종 확인하세요."
echo "  (특히: ALB·ENI·EBS·Elastic IP·NAT·CloudWatch 로그그룹)"
echo "============================================="
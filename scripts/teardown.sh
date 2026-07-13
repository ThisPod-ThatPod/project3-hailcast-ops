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
#           실행 전 '지금 이 계정이 공용(tptp)인지' 를 먼저 검증한다(오계정 전체삭제 방지).
# =============================================================

set -u

INFRA_DIR="${INFRA_DIR:-../project3-hailcast-infra}"
APP_DIR="${APP_DIR:-../project3-hailcast-app}"
MANIFESTS_DIR="${MANIFESTS_DIR:-../project3-hailcast-manifests}"

# ★ 공용 프로젝트 계정(tptp) 12자리 ID. 환경변수로 덮어쓸 수 있음.
#   계정 ID 는 시크릿(키·비번)이 아니라서 기본값으로 박아도 보안규약에 안 걸린다.
EXPECTED_ACCOUNT="${EXPECTED_ACCOUNT:-TODO_공용계정_12자리_ID}"

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
        --only)   ONLY="$2"; shift ;;
        *) err "알 수 없는 옵션: $1"; exit 1 ;;
    esac
    shift
done

# ── 계정 검증 가드 : 어떤 destroy 보다 먼저, '올바른 계정' 인지 확인한다 ──
#   AWS 를 실제로 건드리는 경우(manifest·infra 포함)에만 검사한다.
#   --only app 은 각자 로컬 도커 청소라 계정과 무관 → 건너뛴다.
if [ "$ONLY" != "app" ]; then
    ACTUAL_ACCOUNT=$(aws sts get-caller-identity --query Account --output text) || {
        err "AWS 자격증명 확인 실패 (자격·네트워크 확인). 중단."; exit 1; }
    if [ "$EXPECTED_ACCOUNT" = "TODO_공용계정_12자리_ID" ]; then
        err "EXPECTED_ACCOUNT 가 아직 설정되지 않았습니다. 스크립트 상단에 공용(tptp) 계정 ID 를 넣으세요."
        exit 1
    fi
    if [ "$ACTUAL_ACCOUNT" != "$EXPECTED_ACCOUNT" ]; then
        err "현재 계정($ACTUAL_ACCOUNT) 이 공용 계정($EXPECTED_ACCOUNT) 이 아닙니다. 중단."
        exit 1
    fi
    ok "계정 확인: $ACTUAL_ACCOUNT (공용 tptp)"
fi

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
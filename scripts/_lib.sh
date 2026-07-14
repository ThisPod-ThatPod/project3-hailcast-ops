#!/bin/bash
# =============================================================
# 파일위치 : project3-hailcast-ops/scripts/_lib.sh
# 이 Pod 저 Pod · hailcast — setup·check·teardown·guard 가 함께 쓰는 상수와 가드
# 역할    : 프로젝트 계정 상수 + '지금 내 자격증명이 그 계정이냐'를 대조하는 함수
# 사용    : source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
#
# ⚠️ 계정 ID·리전·클러스터명은 여기 한 곳에서만 고친다.
#    세 스크립트에 흩어 두면 하나만 고치고 나머지가 낡는다.
# =============================================================

# ── 프로젝트 계정 ──────────────────────────────────────────
# ⚠️ 계정 ID 를 이 파일에 적지 않는다. 이 레포는 PUBLIC 이다.
#    계정 ID + IAM 유저명 = 콘솔 로그인에 필요한 셋 중 둘이고, 유저명은
#    커밋 로그·CODEOWNERS 에서 추측할 수 있다 → 남는 방어선이 비밀번호 하나가 된다.
#    값은 .env(gitignore) 또는 환경변수로 주입한다. .env.example 참고.
#
# ⚠️ 반드시 '문자열'로 다룬다. 계정 ID 는 앞자리가 0 일 수 있는데
#    숫자로 비교하면 그 0 이 날아가 11자리가 되어 대조가 항상 실패한다.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ⚠️⚠️ .env 를 `source` 하지 않는다. PROJECT_ACCOUNT_ID '한 줄만' 파싱한다.
#
# source 하면 두 가지가 뚫린다(둘 다 실증함):
#
#  ① 가드가 검사하는 자격증명과, terraform 이 실제로 쓰는 자격증명이 갈린다.
#     `make infra-destroy` 는  guard-account  →  make -C ../infra destroy  인데
#     이 둘은 '서로 다른 셸'이다. .env 에 `export AWS_PROFILE=x` 한 줄만 있으면
#       guard    : AWS_PROFILE=x        로 계정을 확인하고 ✅ 를 준다
#       terraform: AWS_PROFILE=UNSET    → [default] 로 destroy 를 돌린다
#     → 가드가 A 계정을 보고 통과시키고, terraform 이 B 계정을 지운다.
#       이 가드가 막으려던 바로 그 사고를 가드가 스스로 만든다.
#
#  ② source 는 '임의 코드 실행'이다. .env 에 `aws() { echo <기대계정>; }` 두 줄이면
#     가짜 함수가 진짜 aws 를 가로채 가드를 통째로 속인다(통과 확인함).
#
# → 값'만' 읽는다. 대입문 한 줄을 뽑아 따옴표만 벗긴다. 코드가 실행될 여지를 없앤다.
# → 환경변수가 이미 있으면 파일을 아예 보지 않는다 (CI 의 GitHub Secret 이 항상 이긴다).
if [ -z "${PROJECT_ACCOUNT_ID:-}" ] && [ -f "$REPO_ROOT/.env" ]; then
    PROJECT_ACCOUNT_ID="$(
        grep -E '^[[:space:]]*PROJECT_ACCOUNT_ID[[:space:]]*=' "$REPO_ROOT/.env" \
        | tail -n 1 | cut -d= -f2- | tr -d "\"' \t\r"
    )"
fi
PROJECT_ACCOUNT_ID="${PROJECT_ACCOUNT_ID:-}"

if [ -z "$PROJECT_ACCOUNT_ID" ]; then
    echo "❌ PROJECT_ACCOUNT_ID 가 없습니다." >&2
    echo "   로컬 :  cp .env.example .env   → 계정 ID 를 채웁니다 (값은 팀 채널에서)." >&2
    echo "   CI   :  GitHub Secret 을 환경변수 PROJECT_ACCOUNT_ID 로 주입하십시오(.env 파일 불필요)." >&2
    # ⚠️ 조용히 통과시키면 안 된다 — 계정 대조 없이 도는 게 이 가드가 막으려던 사고다.
    #    다만 이 파일은 'source' 되므로 exit 은 호출자 셸을 죽인다.
    #    대화형 셸에서 source 하면 터미널이 통째로 닫힌다 → 대화형이면 return.
    if [[ $- == *i* ]]; then return 1; else exit 1; fi
fi

# ── AWS 자격증명 출처 : 강제하지 않는다 ────────────────────
# AWS 기본 자격증명 체인(환경변수 → AWS_PROFILE → [default])을 그대로 쓴다.
#
# 옛 설계는 AWS_PROFILE=hailcast 를 '강제'했다. 프로젝트 계정과 담당자 개인 계정이
# **달랐을 때**, 공용 키가 개인 [default] 를 덮어쓰는 사고를 막기 위해서였다.
# 2026-07-14 부터 프로젝트 계정 = 담당자 개인 계정이라 그 전제가 사라졌고,
# 그대로 강제하면 오히려 두 곳에서 죽는다:
#   - 담당자 서버 : [default] 를 쓴다 → 'hailcast' 프로필이 없어 전부 실패한다
#   - CI(GitHub Actions OIDC) : 환경변수로 자격증명을 준다 → 프로필이 없어
#     런타임 검사가 통째로 '조용히' 건너뛰어진다 (초록불인데 아무것도 검사하지 않음)
#
# 진짜 안전망은 '프로필 이름'이 아니라 '지금 어느 계정에 서 있는가'다.
#   → verify_project_account (아래)

# ── 프로젝트 상수 ──────────────────────────────────────────
AWS_REGION="${AWS_REGION:-ap-northeast-2}"          # 서울
CLUSTER_NAME="${CLUSTER_NAME:-hailcast-dev-eks}"

# ── 계정 가드 ──────────────────────────────────────────────
# 지금 자격증명이 프로젝트 계정인지 대조한다.
# 전에는 계정 ID 를 '출력만' 하고 대조하지 않아, 엉뚱한 계정에 앉은 채로
# setup 도 check 도 전부 초록불이 떴다.
#
# 반환값: 0 = 맞음 / 1 = 다른 계정 / 2 = 자격증명 없음·만료
# 부수효과: CURRENT_ACCOUNT 에 조회된 계정 ID 를 담는다 (호출자 메시지용)
verify_project_account() {
    CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
        CURRENT_ACCOUNT=""
        return 2
    }
    [ -n "$CURRENT_ACCOUNT" ] || return 2
    [ "$CURRENT_ACCOUNT" = "$PROJECT_ACCOUNT_ID" ]
}

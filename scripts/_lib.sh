#!/bin/bash
# =============================================================
# 파일위치 : project3-hailcast-ops/scripts/_lib.sh
# 이 Pod 저 Pod · hailcast — setup·check·teardown 이 함께 쓰는 상수와 가드
# 역할    : 공용 계정(tptp) 상수 + '지금 내 자격증명이 그 계정이냐'를 대조하는 함수
# 사용    : source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
#
# ⚠️ 계정 ID·프로필·리전·클러스터명은 여기 한 곳에서만 고친다.
#    세 스크립트에 흩어 두면 하나만 고치고 나머지가 낡는다.
# =============================================================

# ── 공용 프로젝트 계정 (tptp) ──────────────────────────────
# ⚠️ 앞자리가 0 이라 반드시 '문자열'로 다룬다.
#    숫자로 비교하면 0 이 날아가 11자리(13623161818)가 되어 대조가 항상 실패한다.
TPTP_ACCOUNT_ID="${TPTP_ACCOUNT_ID:-013623161818}"

# ── AWS 프로필 ─────────────────────────────────────────────
# 공용 키를 [default] 가 아니라 이름 있는 프로필에 둔다.
# 이유 1) 팀원 서버의 [default] 에는 개인 키가 들어 있는 경우가 많다.
#         공용 키가 default 를 차지하면, 팀원이 강의 실습으로 만든 EC2·S3 가
#         공용 계정에 생기고 ManagedBy=terraform 태그가 없어 비용 집계에서 샌다.
# 이유 2) 반대로 개인 키가 default 에 남아 있으면 전에는 그냥 통과했다.
#         프로필을 갈라 두면 개인 default 를 건드리지 않으면서 양쪽을 다 막는다.
#
# ⚠️ 이 이름은 '상속받지 않고' 강제한다. 상속하면 이 스크립트가 막으려던 사고를
#    스스로 저지른다 — 셸에 export AWS_PROFILE=default 가 있으면
#    setup.sh 의 `aws configure --profile "$AWS_PROFILE"` 이 곧
#    `aws configure --profile default` 가 되어 개인 [default] 를 공용 키로 덮어쓴다.
#    게다가 계정은 tptp 가 맞으므로 가드가 그 사고를 '통과'시킨다.
HAILCAST_PROFILE="hailcast"
if [ -n "${AWS_PROFILE:-}" ] && [ "${AWS_PROFILE}" != "$HAILCAST_PROFILE" ]; then
    echo "⚠️  셸의 AWS_PROFILE=${AWS_PROFILE} 을 무시하고 '${HAILCAST_PROFILE}' 로 강제합니다." >&2
fi
AWS_PROFILE="$HAILCAST_PROFILE"
export AWS_PROFILE

# ── 프로젝트 상수 ──────────────────────────────────────────
AWS_REGION="${AWS_REGION:-ap-northeast-2}"          # 서울
CLUSTER_NAME="${CLUSTER_NAME:-hailcast-dev-eks}"

# ── 계정 가드 ──────────────────────────────────────────────
# 지금 자격증명이 공용 계정(tptp)인지 대조한다.
# 전에는 계정 ID 를 '출력만' 하고 대조하지 않아, 개인 계정에 앉은 채로
# setup 도 check 도 전부 초록불이 떴다.
#
# 반환값: 0 = tptp 맞음 / 1 = 다른 계정 / 2 = 자격증명 없음·만료
# 부수효과: CURRENT_ACCOUNT 에 조회된 계정 ID 를 담는다 (호출자 메시지용)
verify_tptp_account() {
    CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
        CURRENT_ACCOUNT=""
        return 2
    }
    [ -n "$CURRENT_ACCOUNT" ] || return 2
    [ "$CURRENT_ACCOUNT" = "$TPTP_ACCOUNT_ID" ]
}

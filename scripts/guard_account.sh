#!/bin/bash
# =============================================================
# 파일위치 : project3-hailcast-ops/scripts/guard_account.sh
# 역할    : AWS 를 만지는 make target 앞에 세우는 계정 가드.
#           지금 자격증명이 프로젝트 계정인지 대조하고, 아니면 여기서 끊는다.
# 호출    : Makefile 의 guard-account target (infra-apply·infra-destroy·kubeconfig 등의 선행조건)
#
# 왜 필요한가:
#   가드를 setup·check·teardown 에만 두면, 정작 '돈이 나가고 자원이 파괴되는'
#   make infra-apply · make infra-destroy 는 대조 없이 곧장 terraform 을 돌린다.
#   teardown.sh 가 destroy 를 막아도 make infra-destroy 는 그 스크립트를 안 거친다.
#   → 가장 위험한 경로가 비어 있게 된다.
#
# 예외 : make fmt 계열은 자격증명이 아예 필요 없다(docs/비용관리.md §0) → 가드를 걸지 않는다.
# =============================================================
set -u

# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

rc=0; verify_project_account || rc=$?
case "$rc" in
    0)
        echo -e "${GREEN}✅ 프로젝트 계정 확인 : ${CURRENT_ACCOUNT}${NC}"
        ;;
    1)
        echo -e "${RED}❌ 프로젝트 계정이 아닙니다 → 현재 ${CURRENT_ACCOUNT} / 기대 ${PROJECT_ACCOUNT_ID}${NC}"
        echo   "   이대로 진행하면 엉뚱한 계정에 자원을 만들거나 지웁니다. 중단합니다."
        echo   "   지금 무엇이 잡혀 있는지 확인:  aws sts get-caller-identity"
        echo   "   ⚠️ 환경변수(AWS_ACCESS_KEY_ID)는 프로필보다 우선합니다 — 설정돼 있으면 unset 하십시오."
        exit 1
        ;;
    *)
        echo -e "${RED}❌ AWS 자격증명이 없거나 만료됐습니다${NC}"
        echo   "   중단합니다.  make setup  으로 먼저 등록하세요."
        exit 1
        ;;
esac

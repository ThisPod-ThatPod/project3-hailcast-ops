#!/bin/bash
# =============================================================
# 파일위치 : ~/project3-hailcast/project3-hailcast-ops/scripts/check.sh
# 환경·자격증명·EKS 연결 상태 확인 (이 Pod 저 Pod · hailcast)
# 실행 : bash check.sh   또는   make check
# =============================================================

# ── 공용 상수·계정 가드 (CLUSTER_NAME · AWS_REGION · PROJECT_ACCOUNT_ID) ──
# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

# 통과·실패는 따로 센다. 실패가 하나라도 있으면 exit 1 로 끝낸다.
# 예전엔 무엇이 어긋나도 항상 exit 0 이라, 화면은 빨간데 스크립트는 성공으로 끝났다.
PASS_N=0; FAIL_N=0
ok()   { echo -e "  ${GREEN}✅ $1${NC}"; PASS_N=$((PASS_N+1)); }
fail() { echo -e "  ${RED}❌ $1${NC}"; FAIL_N=$((FAIL_N+1)); }
warn() { echo -e "  ${YELLOW}⚠️  $1${NC}"; }   # 경고는 실패가 아니다 (apply 전 상태 등)

echo ""
echo "============================================="
echo "  이 Pod 저 Pod · hailcast 환경 상태 확인"
echo "============================================="
echo ""

# ── 1. 필수 도구 ───────────────────────────────────────────
echo "[ 1 ] 필수 도구 설치 확인"
command -v aws       &>/dev/null && ok "AWS CLI : $(aws --version 2>&1 | awk '{print $1}')"        || fail "AWS CLI 미설치 → bash setup.sh"
command -v terraform &>/dev/null && ok "Terraform : $(terraform -version | head -1)"                || fail "Terraform 미설치 → bash setup.sh"
command -v kubectl   &>/dev/null && ok "kubectl : $(kubectl version --client 2>/dev/null | head -1)" || fail "kubectl 미설치 → bash setup.sh"
command -v helm      &>/dev/null && ok "helm : $(helm version --short 2>/dev/null)"                  || fail "helm 미설치 → bash setup.sh"
command -v docker    &>/dev/null && ok "Docker : $(docker --version)"                               || fail "Docker 미설치 → bash setup.sh"
echo ""

# ── 2. Docker 데몬·권한·로그인 ─────────────────────────────
echo "[ 2 ] Docker 상태 확인"
if command -v docker &>/dev/null; then
    if systemctl is-active --quiet docker 2>/dev/null; then
        ok "docker 데몬 실행 중"
    else
        fail "docker 데몬 미실행 → sudo systemctl start docker"
    fi
    if docker info &>/dev/null; then
        ok "현재 사용자로 docker 사용 가능"
    else
        warn "docker 권한 없음 → newgrp docker 또는 재로그인 필요"
    fi
    DOCKER_USER=$(docker info 2>/dev/null | grep "Username:" | awk '{print $2}')
    if [ -n "$DOCKER_USER" ]; then
        ok "Docker Hub 로그인됨: $DOCKER_USER (공용 계정 hailscale 기대)"
    else
        warn "Docker Hub 미로그인 → .dockerhub_token 설정 후 bash setup.sh (또는 docker login)"
    fi
fi
echo ""

# ── 3. AWS 자격증명 (프로젝트 계정) ────────────────────────
# ⭐ 계정 ID 를 '출력'만 하지 않고 프로젝트 계정인지 '대조'한다.
#    예전엔 대조가 없어 엉뚱한 계정에 앉은 채로도 초록불이 떴다.
echo "[ 3 ] AWS 자격증명 확인 (프로젝트 계정)"
rc=0; verify_project_account || rc=$?
case "$rc" in
    0)
        ok "프로젝트 계정 확인 : $CURRENT_ACCOUNT"
        REGION=$(aws configure get region 2>/dev/null || true)
        [ "$REGION" = "$AWS_REGION" ] && ok "리전 정상 : $AWS_REGION" || warn "리전이 $AWS_REGION(서울)이 아님: ${REGION:-미설정}"
        ;;
    1)
        fail "프로젝트 계정이 아닙니다 → 현재 $CURRENT_ACCOUNT / 기대 $PROJECT_ACCOUNT_ID"
        echo "     이 상태로 terraform 을 돌리면 엉뚱한 계정을 봅니다."
        echo "     지금 무엇이 잡혀 있는지:  aws sts get-caller-identity"
        echo "     ⚠️ 환경변수(AWS_ACCESS_KEY_ID)는 프로필보다 우선합니다."
        ;;
    2)
        fail "AWS 자격증명 없음/만료 → bash scripts/setup.sh"
        ;;
esac
echo ""

# ── 4. EKS 연결 (kubectl → 클러스터) ───────────────────────
# 로컬 k8s 의 'Tailscale 상태' 대신, EKS 는 kubeconfig·API 도달·RBAC 3가지를 본다.
echo "[ 4 ] EKS 연결 상태 확인 ($CLUSTER_NAME)"
if command -v aws &>/dev/null && command -v kubectl &>/dev/null; then
    if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
        CL_STATUS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query 'cluster.status' --output text 2>/dev/null)
        ok "클러스터 존재: 상태=$CL_STATUS"
        # kubeconfig 로 실제 kubectl 도달 여부
        if kubectl cluster-info &>/dev/null; then
            ok "kubectl 연결됨"
            NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
            [ "$NODES" -gt 0 ] && ok "노드 조회 성공 : ${NODES}개" || warn "노드 0개(노드그룹 미생성/스케일 0 가능)"
        else
            warn "kubectl 미연결 → aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION"
        fi
    else
        warn "클러스터 아직 없음(apply 전) 또는 접근 권한 없음 → apply 후 재확인"
    fi
else
    fail "aws/kubectl 미설치 → bash setup.sh"
fi
echo ""

# ── 5. 비용 안내 ───────────────────────────────────────────
echo "[ 5 ] 비용 안내"
echo "  - EKS·NAT·RDS 는 켜두기만 해도 상시 과금. 안 쓸 땐 노드를 0 으로 줄이거나 destroy"
echo "  - apply(비용 시작) 시점은 Budgets 확인 후 팀 결정 (Context A-7)"
echo "  - RDS 는 destroy 로부터 보호 장치 아님 → 보존 필요 시 스냅샷 먼저"
echo ""

echo "============================================="
if [ "$FAIL_N" -gt 0 ]; then
    echo -e "  ${RED}확인 실패 : 통과 ${PASS_N} · 실패 ${FAIL_N}${NC}"
    echo "  위의 ❌ 를 먼저 해결하세요."
    echo "============================================="
    echo ""
    exit 1
fi
echo -e "  ${GREEN}확인 완료 : 통과 ${PASS_N} · 실패 0${NC}"
echo "============================================="
echo ""
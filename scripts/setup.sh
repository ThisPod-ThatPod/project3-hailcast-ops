#!/bin/bash
# =============================================================
# 파일위치 : ~/project3-hailcast/project3-hailcast-ops/scripts/setup.sh
# 팀 프로젝트 환경 설정 스크립트 (이 Pod 저 Pod · hailcast)
# 대상 OS : Rocky Linux 8.x   (proj-mgmt : 172.16.8.150)
# 목적    : proj-mgmt 를 '프로젝트 운영 콘솔'로 세팅
#           AWS CLI v2 · Terraform · kubectl · helm · Docker 설치·검증
#           + 공용 AWS 계정(tptp) · 공용 Docker Hub(hailscale) 로그인
#           + EKS kubeconfig 연결 (aws eks update-kubeconfig)
# 실행    : bash setup.sh   (또는 make setup)
# 비고    : 하이브리드(Tailscale/VXLAN) 없음 — AWS 단일·EKS 아키텍처.
#           Ansible 제외 — 인프라=Terraform, 배포=GitOps(ArgoCD)라 서버 구성 없음.
# =============================================================

set -e  # 오류 발생 시 즉시 중단

# ── 공용 상수·계정 가드 (CLUSTER_NAME · AWS_REGION · AWS_PROFILE · TPTP_ACCOUNT_ID) ──
# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

K8S_MINOR="1.35"                     # EKS 버전에 맞춘 kubectl 마이너(§ modules/eks cluster_version)

# OS 호환성 체크
if [ ! -f /etc/redhat-release ] && [ ! -f /etc/rocky-release ]; then
    echo "❌ 이 스크립트는 Rocky Linux 8 기반 환경만 지원합니다."
    echo "    다른 OS 환경에서는 아래 도구들을 수동으로 설치해 주세요:"
    echo "    - AWS CLI v2 / Terraform / kubectl / helm / Docker"
    exit 1
fi

# ── 색상 출력 함수 ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}    $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC}   $1"; exit 1; }

echo ""
echo "============================================="
echo "  이 Pod 저 Pod · hailcast 환경 설정 시작"
echo "  Rocky 8 | AWS CLI · Terraform · kubectl · helm · Docker"
echo "============================================="
echo ""

# ── STEP 1 : 기존 설치 확인 ────────────────────────────────
info "STEP 1/8 : 기존 설치 여부 확인 중..."
AWS_INSTALLED=false; TF_INSTALLED=false; KUBECTL_INSTALLED=false; HELM_INSTALLED=false; DOCKER_INSTALLED=false
command -v aws       &>/dev/null && { warning "AWS CLI 이미 설치됨 → 건너뜀";   AWS_INSTALLED=true; }
command -v terraform &>/dev/null && { warning "Terraform 이미 설치됨 → 건너뜀"; TF_INSTALLED=true; }
command -v kubectl   &>/dev/null && { warning "kubectl 이미 설치됨 → 건너뜀";   KUBECTL_INSTALLED=true; }
command -v helm      &>/dev/null && { warning "helm 이미 설치됨 → 건너뜀";      HELM_INSTALLED=true; }
command -v docker    &>/dev/null && { warning "Docker 이미 설치됨 → 건너뜀";    DOCKER_INSTALLED=true; }

# ── STEP 1.5 : make 설치 ───────────────────────────────────
info "STEP 1.5/8 : make 확인 중..."
if ! command -v make &>/dev/null; then
    sudo dnf install -y make -q || error "make 설치 실패"
    success "make 설치 완료"
else
    info "  make 이미 설치됨"
fi

# ── STEP 2 : AWS CLI v2 ────────────────────────────────────
if [ "$AWS_INSTALLED" = false ]; then
    info "STEP 2/8 : AWS CLI v2 설치 중..."
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT
    cd "$TMP_DIR"
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" || error "AWS CLI 다운로드 실패"
    sudo dnf install -y unzip -q
    unzip -q awscliv2.zip
    sudo ./aws/install
    cd ~
    rm -rf "$TMP_DIR"
    trap - EXIT
    command -v aws &>/dev/null && success "AWS CLI 설치 완료: $(aws --version 2>&1 | awk '{print $1}')" || error "AWS CLI 설치 실패"
else
    info "STEP 2/8 : AWS CLI 건너뜀"
fi

# ── STEP 2.5 : AWS 자격증명 확인/등록 (공용 계정 tptp · 전용 프로필) ──────────
# 동작:
#   - 공용 키는 [default] 가 아니라 '${AWS_PROFILE}' 프로필에 저장한다 → 개인 default 를 안 건드린다
#   - 키가 없으면 aws configure --profile 로 입력받는다
#   - ⭐ 키가 있어도 '누구 계정인지' 반드시 대조한다. 예전엔 이 대조가 없어 개인 계정도 초록불이었다
#   - 키 값은 스크립트·깃에 절대 두지 않는다. 로컬 ~/.aws 에만 저장.
info "STEP 2.5/8 : AWS 자격증명 확인 (공용 계정 tptp · 프로필 ${AWS_PROFILE})..."

# ⚠️ 환경변수 자격증명은 프로필보다 우선한다 → 프로필을 아무리 잘 잡아도 무시된다
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
    warning "환경변수 AWS_ACCESS_KEY_ID 가 설정돼 있습니다. 이건 프로필보다 우선합니다."
    echo    "    프로필을 제대로 잡아도 이 키가 쓰입니다. 아래를 먼저 실행하고 재시도하세요."
    echo    "    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN"
fi

AWS_AKID=$(aws configure get aws_access_key_id     --profile "$AWS_PROFILE" 2>/dev/null || true)
AWS_SAK=$(aws configure get aws_secret_access_key  --profile "$AWS_PROFILE" 2>/dev/null || true)

# ── 마이그레이션 : 예전 setup.sh 로 공용 키가 이미 [default] 에 들어간 서버 대응 ──
# 프로필 분리 이전에 setup.sh 를 돌린 사람은 tptp 키가 [default] 에 있다.
# 그대로 두면 (a) 키를 다시 물어보게 되고 (b) 무엇보다 공용 키가 default 에 앉은 채로 남아,
# 그 서버에서 만드는 모든 자원(강의 실습 포함)이 기본으로 공용 계정에 생긴다.
#
# ⚠️ 판정과 복사를 반드시 '같은 소스(파일의 [default] 키)' 로 한다.
#    판정을 sts 로 하면 환경변수 자격증명이 이겨서, 정작 복사는 파일의 '개인 키' 를
#    가져오는 사고가 난다(계정은 tptp 로 보이는데 키는 개인 것).
if [ -z "$AWS_AKID" ] || [ -z "$AWS_SAK" ]; then
    D_AKID=$(aws configure get aws_access_key_id     --profile default 2>/dev/null || true)
    D_SAK=$(aws configure get aws_secret_access_key  --profile default 2>/dev/null || true)
    if [ -n "$D_AKID" ] && [ -n "$D_SAK" ]; then
        # 파일의 [default] 키 '그 자체' 가 tptp 인지 본다 (환경변수를 배제하고 서명)
        D_ACCOUNT=$(AWS_ACCESS_KEY_ID="$D_AKID" AWS_SECRET_ACCESS_KEY="$D_SAK" AWS_SESSION_TOKEN="" \
                    aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
        if [ "$D_ACCOUNT" = "$TPTP_ACCOUNT_ID" ]; then
            warning "[default] 프로필에 공용 계정(tptp) 키가 들어 있습니다 → '${AWS_PROFILE}' 로 복사합니다."
            aws configure set aws_access_key_id     "$D_AKID" --profile "$AWS_PROFILE"
            aws configure set aws_secret_access_key "$D_SAK"  --profile "$AWS_PROFILE"
            aws configure set region "$AWS_REGION"            --profile "$AWS_PROFILE"
            aws configure set output json                     --profile "$AWS_PROFILE"
            AWS_AKID="$D_AKID"; AWS_SAK="$D_SAK"
            success "  '${AWS_PROFILE}' 프로필로 복사 완료 (키 재입력 불필요)"
            warning "  ⚠️ [default] 에 남은 공용 키는 자동으로 지우지 않습니다 — 개인 설정을 함부로 건드리지 않기 위함입니다."
            echo    "     하지만 남겨두면 이 서버에서 만드는 모든 자원이 기본으로 공용 계정에 생깁니다."
            echo    "     직접 치워 주세요:  ~/.aws/credentials 의 [default] 를 개인 키로 되돌리거나 비웁니다."
        fi
    fi
fi

if [ -z "$AWS_AKID" ] || [ -z "$AWS_SAK" ]; then
    warning "프로필 '${AWS_PROFILE}' 미설정 → 공용 계정(tptp) 키를 입력합니다."
    echo "    ⚠️ 개인 키가 아니라 '공용 계정(tptp)' 키입니다. 개인 [default] 프로필은 건드리지 않습니다."
    echo "    입력값: Access Key / Secret Key / region=${AWS_REGION} / output=json"
    aws configure --profile "$AWS_PROFILE"
    # region/output 이 비어 있으면 기본값 보정 (Enter 로 건너뛴 경우 대비)
    [ -z "$(aws configure get region --profile "$AWS_PROFILE" 2>/dev/null)" ] && aws configure set region "$AWS_REGION" --profile "$AWS_PROFILE"
    [ -z "$(aws configure get output --profile "$AWS_PROFILE" 2>/dev/null)" ] && aws configure set output json   --profile "$AWS_PROFILE"
fi

# ⭐ 계정 가드 — 키가 '유효한가'가 아니라 '누구 것인가'를 본다
rc=0; verify_tptp_account || rc=$?
if [ "$rc" = "2" ]; then
    # 키는 있는데 인증이 안 된다(만료·오타) → 한 번만 다시 입력받아 본다
    warning "프로필 '${AWS_PROFILE}' 인증 실패(키 만료·오타 가능) → 다시 입력합니다."
    aws configure --profile "$AWS_PROFILE"
    rc=0; verify_tptp_account || rc=$?
fi
case "$rc" in
    0) success "  공용 계정(tptp) 확인 : ${CURRENT_ACCOUNT} · 프로필 ${AWS_PROFILE}" ;;
    1) error "공용 계정(tptp)이 아닙니다. 현재 계정=${CURRENT_ACCOUNT} / 기대=${TPTP_ACCOUNT_ID}
            프로필 '${AWS_PROFILE}' 에 개인 키가 들어간 것으로 보입니다.
            지우고 다시 등록:  aws configure --profile ${AWS_PROFILE}" ;;
    *) error "프로필 '${AWS_PROFILE}' 인증에 계속 실패합니다. 키를 확인하세요.
            다시 등록:  aws configure --profile ${AWS_PROFILE}" ;;
esac

# region 이 서울이 아니면 경고
CUR_REGION=$(aws configure get region --profile "$AWS_PROFILE" 2>/dev/null || true)
[ -n "$CUR_REGION" ] && [ "$CUR_REGION" != "$AWS_REGION" ] && \
    warning "현재 region=$CUR_REGION (서울 ${AWS_REGION} 권장)"

# ── STEP 3 : Terraform ─────────────────────────────────────
if [ "$TF_INSTALLED" = false ]; then
    info "STEP 3/8 : Terraform 설치 중..."
    sudo dnf install -y yum-utils -q
    sudo yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo -q || true
    sudo dnf install -y terraform -q
    command -v terraform &>/dev/null && { success "Terraform 설치 완료: $(terraform -version | head -1)"; terraform -install-autocomplete 2>/dev/null || true; } || error "Terraform 설치 실패"
else
    info "STEP 3/8 : Terraform 건너뜀"
fi

# ── STEP 4 : kubectl (EKS 1.35 맞춤) ───────────────────────
# 구글 공식 저장소에서 EKS 클러스터와 같은 마이너(1.35)의 최신 패치를 받는다.
# (로컬 k8s 처럼 scp admin.conf 를 쓰지 않는다 — EKS 는 STEP 7 의 update-kubeconfig 로 붙는다)
if [ "$KUBECTL_INSTALLED" = false ]; then
    info "STEP 4/8 : kubectl(${K8S_MINOR}.x) 설치 중..."
    KVER=$(curl -fsSL "https://dl.k8s.io/release/stable-${K8S_MINOR}.txt" 2>/dev/null || true)
    [ -z "$KVER" ] && KVER="v${K8S_MINOR}.0"   # stable txt 미제공 시 fallback
    TMP_DIR=$(mktemp -d); trap 'rm -rf "$TMP_DIR"' EXIT; cd "$TMP_DIR"
    curl -fsSLO "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl" || error "kubectl 다운로드 실패"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/kubectl
    cd ~; rm -rf "$TMP_DIR"; trap - EXIT
    command -v kubectl &>/dev/null && success "kubectl 설치 완료: $(kubectl version --client 2>/dev/null | head -1)" || error "kubectl 설치 실패"
else
    info "STEP 4/8 : kubectl 건너뜀"
fi

# ── STEP 5 : helm (v3) ─────────────────────────────────────
if [ "$HELM_INSTALLED" = false ]; then
    info "STEP 5/8 : helm(v3) 설치 중..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get-helm-3.sh || error "helm 설치 스크립트 다운로드 실패"
    chmod +x /tmp/get-helm-3.sh
    /tmp/get-helm-3.sh || error "helm 설치 실패"
    rm -f /tmp/get-helm-3.sh
    command -v helm &>/dev/null && success "helm 설치 완료: $(helm version --short 2>/dev/null)" || error "helm 설치 실패"
else
    info "STEP 5/8 : helm 건너뜀"
fi

# ── STEP 6 : Docker ────────────────────────────────────────
if [ "$DOCKER_INSTALLED" = false ]; then
    info "STEP 6/8 : Docker 설치 중..."
    sudo dnf remove -y podman buildah runc 2>/dev/null || true   # Rocky8 충돌 방지(수업: podman buildah)
    sudo dnf install -y yum-utils -q
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo -q 2>/dev/null || true
    sudo dnf makecache -q 2>/dev/null || true
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -q || error "Docker 설치 실패"
    sudo systemctl enable --now docker
    sudo usermod -aG docker "${SUDO_USER:-$USER}"                # root 오등록 방지
    command -v docker &>/dev/null && success "Docker 설치 완료: $(docker --version)" || error "Docker 설치 실패"
    warning "docker 그룹 적용을 위해 재로그인 또는 'newgrp docker' 필요"
else
    info "STEP 6/8 : Docker 건너뜀"
fi

# ── STEP 6.5 : Docker Hub 로그인 (공용 계정 hailscale · 토큰 파일 자동 생성) ────
# 동작:
#   - .dockerhub_token 이 없거나 비어 있으면 → 입력받아 생성(chmod 600)
#   - 이미 값이 있으면 → 입력 건너뛰고 그대로 사용
#   - proj-mgmt 는 공유 서버 → '공용 계정 hailscale' 아이디/PAT 를 1회 등록(개인 계정 아님)
#   - 토큰 발급: hub.docker.com → Account settings → Personal access tokens
info "STEP 6.5/8 : Docker Hub 로그인 확인 (공용 계정 hailscale)..."

# 홈이 아닌 'project3-hailcast-ops 폴더' 내부에 저장(공용 계정 격리)
OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # scripts/ 의 상위 = 레포 루트
DOCKERHUB_TOKEN_FILE="${OPS_DIR}/.dockerhub_token"
PROJECT_DOCKER_CONFIG="${OPS_DIR}/.docker_config"

if [ -f "$DOCKERHUB_TOKEN_FILE" ]; then
    # shellcheck disable=SC1090
    source "$DOCKERHUB_TOKEN_FILE"
fi

if [ -z "${DOCKERHUB_USER:-}" ] || [ -z "${DOCKERHUB_TOKEN:-}" ]; then
    warning ".dockerhub_token 미설정 또는 비어 있음 → 공용 계정(hailscale) 토큰 입력"
    echo "    (토큰 발급: hub.docker.com → Account settings → Personal access tokens)"
    read -rp  "    DOCKERHUB_USER (공용 아이디 hailscale 입력 후 Enter): " DOCKERHUB_USER
    read -rsp "    DOCKERHUB_TOKEN (dckr_pat_... 붙여넣기 후 Enter [화면 미표시]): " DOCKERHUB_TOKEN
    echo ""
    if [ -z "$DOCKERHUB_USER" ] || [ -z "$DOCKERHUB_TOKEN" ]; then
        warning "입력값이 비어 Docker Hub 로그인을 건너뜁니다 (나중에 재실행 가능)"
    else
        declare -p DOCKERHUB_USER DOCKERHUB_TOKEN > "$DOCKERHUB_TOKEN_FILE"
        chmod 600 "$DOCKERHUB_TOKEN_FILE"
        success ".dockerhub_token 생성 완료 (chmod 600)"
    fi
else
    info "  .dockerhub_token 이미 설정됨 → 입력 건너뜀 ($DOCKERHUB_USER)"
fi

export DOCKERHUB_USER DOCKERHUB_TOKEN   # sg 서브셸 참조용
if [ -n "${DOCKERHUB_USER:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
    mkdir -p "$PROJECT_DOCKER_CONFIG"
    export DOCKER_CONFIG="$PROJECT_DOCKER_CONFIG"   # 공용 계정 격리 경로
    if docker info &>/dev/null; then
        echo "$DOCKERHUB_TOKEN" | docker login -u "$DOCKERHUB_USER" --password-stdin \
            && success "Docker Hub 로그인됨: $DOCKERHUB_USER" \
            || warning "Docker Hub 로그인 실패 → 토큰 확인"
    elif id -nG "${SUDO_USER:-$USER}" | grep -qw docker; then
        # 그룹은 추가됐으나 현재 셸 미반영 → sg 로 즉시 적용하여 로그인 (격리 경로 강제)
        sg docker -c "DOCKER_CONFIG='$PROJECT_DOCKER_CONFIG'; echo '$DOCKERHUB_TOKEN' | docker login -u '$DOCKERHUB_USER' --password-stdin" \
            && success "Docker Hub 로그인됨: $DOCKERHUB_USER" \
            || warning "Docker Hub 로그인 실패 → 재로그인 후 bash setup.sh 재실행"
    else
        warning "docker 권한 미반영 → newgrp docker 후 bash setup.sh 재실행"
    fi
fi

# ── STEP 7 : EKS kubeconfig 연결 ───────────────────────────
# EKS 는 로컬 k8s 처럼 admin.conf 를 scp 하지 않는다.
# 아래 한 줄이 ~/.kube/config 를 자동 생성한다. 클러스터가 아직 apply 전이면 경고만 남기고 넘어간다.
# (권한: 공용 계정 tptp 가 클러스터 생성자라 자동 admin — bootstrap_cluster_creator_admin_permissions=true)
info "STEP 7/8 : EKS kubeconfig 연결 (${CLUSTER_NAME})..."
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" \
        && success "kubeconfig 연결됨 → kubectl 사용 가능" \
        || warning "update-kubeconfig 실패 → 자격증명/권한 확인"
else
    warning "EKS 클러스터(${CLUSTER_NAME})가 아직 없음(apply 전이거나 권한 부족)."
    echo "    apply 후 재실행:  aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}"
fi

# ── STEP 8 : 최종 검증 ─────────────────────────────────────
info "STEP 8/8 : 설치 결과 최종 검증"
echo ""
echo "  ┌─────────────────────────────────────────┐"
command -v aws       &>/dev/null && echo "  │ ✅ AWS CLI   : $(aws --version 2>&1 | awk '{print $1}')"   || echo "  │ ❌ AWS CLI   : 실패"
command -v terraform &>/dev/null && echo "  │ ✅ Terraform : $(terraform -version | head -1)"          || echo "  │ ❌ Terraform : 실패"
command -v kubectl   &>/dev/null && echo "  │ ✅ kubectl   : $(kubectl version --client 2>/dev/null | head -1)" || echo "  │ ❌ kubectl   : 실패"
command -v helm      &>/dev/null && echo "  │ ✅ helm      : $(helm version --short 2>/dev/null)"      || echo "  │ ❌ helm      : 실패"
command -v docker    &>/dev/null && echo "  │ ✅ Docker    : $(docker --version)"                      || echo "  │ ❌ Docker    : 실패"
echo "  └─────────────────────────────────────────┘"
echo ""

echo "============================================="
success "환경 설치 완료!"
echo "============================================="
echo ""
echo "  다음 단계:"
echo "   1) docker 그룹 적용:   newgrp docker  (또는 재로그인)"
echo "   2) AWS 자격증명:       프로필 '${AWS_PROFILE}' 에 공용 계정(tptp) 키 저장됨 (개인 default 는 그대로)"
echo "                          → make 로 돌리면 AWS_PROFILE 이 자동 적용됩니다."
echo "                          → 터미널에서 직접 aws/terraform 을 쓸 땐:  export AWS_PROFILE=${AWS_PROFILE}"
echo "   3) Docker Hub :        setup.sh 중 입력한 공용(hailscale) 토큰으로 자동 로그인됨"
echo "   4) EKS 연결:           apply 후  aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION}"
echo "   5) 환경 점검:          make check"
echo ""

# ── 스마트 cd 자동 전환 (팀 전용 Docker Hub 계정 격리) ─────────────────────
# 왜 필요한가: 각 개인 서버(mgmt·proj-mgmt)에는 이미 '개인' Docker Hub 로그인이
#   ~/.docker/config.json 에 들어 있는 경우가 많다. 여기서 팀 공용(hailscale)으로 그냥
#   docker login 하면 개인 로그인을 덮어쓴다. 그래서 이 ops 폴더 '안'에서만 전용 금고
#   (.docker_config)를 바라보게 하고, 폴더를 '벗어나면' 개인 계정으로 복구한다.
# 매칭 기준: 폴더 구조 통일 규칙에 따른 '이 레포의 실제 절대경로(OPS_DIR)'와 그 하위만.
#   (문자열 '포함' 매칭이 아니라 정확한 경로 기준 → 우연한 이름 충돌 오작동 방지)
if [ -d "$PROJECT_DOCKER_CONFIG" ]; then
    if ! grep -qF "# hailcast-ops Docker Config 자동 격리 전환" ~/.bashrc; then
        # OPS_DIR 은 setup 시점의 절대경로로 확장해 박고, $@·$PWD 는 런타임 확장되도록 이스케이프
        cat >> ~/.bashrc << EOF

# hailcast-ops Docker Config 자동 격리 전환 (제거하려면 이 함수 블록 전체를 지우면 됨)
cd() {
    builtin cd "\$@" || return
    if [[ "\$PWD" == "${OPS_DIR}" || "\$PWD" == "${OPS_DIR}/"* ]]; then
        export DOCKER_CONFIG="${OPS_DIR}/.docker_config"
    else
        unset DOCKER_CONFIG
    fi
}
EOF
        success "스마트 cd 격리 기능 주입 완료 (.bashrc) — 대상: ${OPS_DIR}"
        info    "적용하려면 새 터미널을 열거나  source ~/.bashrc  실행"
    else
        info "이미 .bashrc 에 설정이 존재하여 건너뜁니다."
    fi
fi

# ── (맨 마지막) docker 그룹 즉시 적용 ──────────────────────
# ⚠️ newgrp 는 '새 셸 진입'이라 반드시 모든 작업의 맨 끝에 위치해야 한다.
if [ -t 0 ] && command -v docker &>/dev/null && ! docker info &>/dev/null \
   && id -nG "${SUDO_USER:-$USER}" | grep -qw docker; then
    info "docker 그룹을 즉시 적용합니다 (새 셸 진입). 종료하려면 'exit' 입력 후 Enter."
    exec newgrp docker
fi
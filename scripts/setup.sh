#!/bin/bash
# =============================================================
# 파일위치 : ~/project3-hailcast/project3-hailcast-ops/scripts/setup.sh
# 팀 프로젝트 환경 설정 스크립트 (이 Pod 저 Pod · hailcast)
# 대상 OS : Rocky Linux 8.x   (proj-mgmt : 172.16.8.150)
# 목적    : proj-mgmt 를 '프로젝트 운영 콘솔'로 세팅
#           AWS CLI v2 · Terraform · kubectl · helm · Docker 설치·검증
#           + 프로젝트 AWS 계정 · 공용 Docker Hub(hailscale) 로그인
#           + EKS kubeconfig 연결 (aws eks update-kubeconfig)
#           + 개인 [default] 보존 · 프로젝트 [hailcast] 프로필 자동 준비·전환 훅
# 실행    : bash setup.sh   (또는 make setup)
# 비고    : 하이브리드(Tailscale/VXLAN) 없음 — AWS 단일·EKS 아키텍처.
#           Ansible 제외 — 인프라=Terraform, 배포=GitOps(ArgoCD)라 서버 구성 없음.
# =============================================================

set -e  # 오류 발생 시 즉시 중단

# ── 공용 상수·계정 가드 (CLUSTER_NAME · AWS_REGION · PROJECT_ACCOUNT_ID) ──
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

# ── 자동 전환 훅 설치 (AWS_PROFILE + DOCKER_CONFIG 통합) ─────
# 부모 셸(~/.bashrc)에서 도는 유일한 장치. 스크립트의 export 는 자식 스코프라
# 부모 셸을 못 바꾸므로, '지속되는 자동 전환'은 반드시 여기(.bashrc)에서 한다.
#   · AWS_PROFILE : project3-hailcast 바구니(4레포) 안이면 [hailcast], 밖이면 개인 [default]
#     (단 [hailcast] 프로필이 있을 때만 — 없으면 default 가 이미 프로젝트 계정인 사람이라 그대로)
#   · DOCKER_CONFIG : ops 폴더 안에서만 공용 금고(.docker_config)
# 멱등 : 새 마커가 있으면 건너뛴다. 옛 'Docker 전용 cd 훅'이 있으면 제거 후 통합본으로 대체(이중 cd 방지).
install_hailcast_hook() {
    local OPS_DIR ROOT MARKER OLD_MARKER OLD_MARKER2
    OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # scripts/ 의 상위 = ops 레포 루트
    ROOT="$(cd "$OPS_DIR/.." && pwd)"                            # 그 상위 = project3-hailcast 바구니
    MARKER="# hailcast 자동 전환 (AWS_PROFILE + DOCKER_CONFIG)"
    OLD_MARKER="# hailcast-ops Docker Config 자동 격리 전환"
    OLD_MARKER2="# 특정 폴더 진입 시 Docker Config 자동 격리 전환"

    cp -f ~/.bashrc ~/.bashrc.hailcast.bak 2>/dev/null || true   # 안전 백업

    # 옛 docker 전용 훅 제거(마커 줄 ~ 첫 '}' 까지) → 이중 cd 정의 방지
    # 마커가 프로젝트별로 다른 변종(hailcast-ops / 특정 폴더 진입 시)이 있어 둘 다 제거한다.
    for _m in "$OLD_MARKER" "$OLD_MARKER2"; do
        if grep -qF "$_m" ~/.bashrc 2>/dev/null; then
            awk -v m="$_m" 'index($0,m){s=1} s&&/^}/{s=0;next} !s' ~/.bashrc > ~/.bashrc.tmp \
                && mv ~/.bashrc.tmp ~/.bashrc
            info "옛 cd 훅 제거 → 통합본으로 교체 ($_m)"
        fi
    done

    if grep -qF "$MARKER" ~/.bashrc 2>/dev/null; then
        info "자동 전환 훅 이미 설치됨 → 건너뜀"
        return
    fi

    cat >> ~/.bashrc << EOF

$MARKER
cd() {
    builtin cd "\$@" || return
    # AWS : project3-hailcast 바구니(4레포) 전체
    if [[ "\$PWD" == "$ROOT" || "\$PWD" == "$ROOT/"* ]]; then
        if grep -q '^\\[hailcast\\]' ~/.aws/credentials 2>/dev/null; then
            export AWS_PROFILE=hailcast
            [ -n "\${AWS_ACCESS_KEY_ID:-}" ] && echo "⚠️  환경변수 자격증명이 프로필을 덮어씁니다 → unset 필요"
        fi
    elif [ "\${AWS_PROFILE:-}" = "hailcast" ]; then
        unset AWS_PROFILE
    fi
    # Docker : ops 폴더 안에서만 공용 금고
    if [[ "\$PWD" == "$OPS_DIR" || "\$PWD" == "$OPS_DIR/"* ]]; then
        export DOCKER_CONFIG="$OPS_DIR/.docker_config"
    elif [ "\${DOCKER_CONFIG:-}" = "$OPS_DIR/.docker_config" ]; then
        unset DOCKER_CONFIG
    fi
}
# 새 셸이 이미 프로젝트 트리 안에서 열렸다면 즉시 적용(새 터미널 자동화)
if [[ "\$PWD" == "$ROOT" || "\$PWD" == "$ROOT/"* ]] && grep -q '^\\[hailcast\\]' ~/.aws/credentials 2>/dev/null; then
    export AWS_PROFILE=hailcast
fi
EOF
    success "자동 전환 훅 설치 완료 (.bashrc) — AWS: $ROOT · Docker: $OPS_DIR/.docker_config"
    info    "새 터미널을 열면 프로젝트 폴더에서 자동으로 [hailcast] 프로필이 잡힙니다."
}

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

# ── STEP 2.5 : AWS 자격증명 확인/등록 (프로젝트 계정) ────────────────────────
# 동작 요약:
#   rc=0  현재 자격증명이 이미 프로젝트 계정        → 통과
#   rc=2  자격증명 자체가 없음                       → aws configure 로 등록 후 재확인
#   rc=1  유효하지만 '다른 계정'(대개 개인 [default]) → 개인 것은 그대로 두고
#                                                     프로젝트 전용 [hailcast] 프로필을 준비·활성화
#   · 키 값은 스크립트·깃에 절대 두지 않는다. 로컬 ~/.aws 에만 저장.
#   · export AWS_PROFILE 는 '이 스크립트' 스코프용(STEP 3~8 을 프로젝트 계정으로).
#     부모 셸 자동 전환은 install_hailcast_hook(.bashrc) 가 담당한다.
info "STEP 2.5/8 : AWS 자격증명 확인 (프로젝트 계정)..."

rc=0; verify_project_account || rc=$?

# ── rc=2 : 자격증명 없음/만료/무효 → 개인 default 는 절대 안 건드리고 [hailcast] 로 통일 ──
if [ "$rc" = "2" ]; then
    [ -t 0 ] || error "비대화형 환경입니다(CI 등). 프로젝트 자격증명을 미리 주입하세요."
    warning "유효한 프로젝트 자격증명이 없습니다 → 프로젝트 전용 [hailcast] 프로필로 등록합니다."
    if ! aws configure list-profiles 2>/dev/null | grep -qx "hailcast"; then
        echo "    팀 발급 키를 입력하세요 (region=${AWS_REGION}·output=json 자동 보정)"
        aws configure --profile hailcast
        aws configure --profile hailcast set region "$AWS_REGION"
        aws configure --profile hailcast set output json
    fi
    export AWS_PROFILE=hailcast
    rc=0; verify_project_account || rc=$?
fi

# ── rc=1 : 유효하지만 '다른 계정' → [hailcast] 프로필 자동 준비·전환 ──
if [ "$rc" = "1" ]; then
    # (A) 환경변수 자격증명이 원인이면 스크립트가 '이 셸에서' 못 지운다(자식 스코프).
    #     게다가 env 는 프로필을 이겨서 프로필을 만들어도 무의미 → 하드 스톱.
    if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
        error "환경변수 자격증명(현재=${CURRENT_ACCOUNT})이 잡혀 있습니다 — 프로필보다 우선합니다.
            이 셸에서 직접 지운 뒤 재실행하세요(스크립트가 대신 못 지웁니다):
              unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
              make setup"
    fi

    # (B) 비대화형(CI 등)에서는 aws configure 가 입력 대기로 멈춘다 → 멈추고 안내.
    [ -t 0 ] || error "비대화형 환경입니다(CI 등). 프로젝트 자격증명을 미리 주입하세요(GitHub Secret)."

    warning "개인 계정(현재=${CURRENT_ACCOUNT})이 잡혀 있습니다 → 프로젝트 전용 [hailcast] 프로필을 준비합니다."

    # (C) [hailcast] 프로필이 없으면 지금 입력받아 생성 (개인 [default] 는 건드리지 않음)
    if ! aws configure list-profiles 2>/dev/null | grep -qx "hailcast"; then
        echo "    팀 발급 키를 입력하세요 (region=${AWS_REGION}·output=json 자동 보정)"
        aws configure --profile hailcast
        aws configure --profile hailcast set region "$AWS_REGION"
        aws configure --profile hailcast set output json
    else
        info "  기존 [hailcast] 프로필 사용"
    fi

    # (D) ⭐ 교차검증 : 프로필의 '실제 계정' == .env 의 '기대 계정' 인가
    #     → '.env 에 계정 ID 를 제대로 넣었나' 를 여기서 자동으로 잡는다.
    PROF_ACCT=$(aws sts get-caller-identity --profile hailcast --query Account --output text 2>/dev/null || true)
    if [ "$PROF_ACCT" != "$PROJECT_ACCOUNT_ID" ]; then
        error "[hailcast] 프로필 계정=${PROF_ACCT:-조회실패} 인데 .env 기대=${PROJECT_ACCOUNT_ID}.
            둘 중 하나가 틀렸습니다 — 발급받은 키, 또는 .env 의 PROJECT_ACCOUNT_ID 를 확인하세요."
    fi

    # (E) 이 '스크립트의 남은 STEP(3~8)' 이 프로젝트 계정으로 돌게 한다.
    #     부모 셸 자동 전환은 아래 install_hailcast_hook 가 담당(자식 export 는 부모에 안 남음).
    export AWS_PROFILE=hailcast
    rc=0; verify_project_account || rc=$?
fi

# ── 최종 판정 ─────────────────────────────────────────────
case "$rc" in
    0) success "  프로젝트 계정 확인 : ${CURRENT_ACCOUNT}${AWS_PROFILE:+ (프로필 $AWS_PROFILE)}" ;;
    *) error "AWS 계정 확인 실패. 현재=${CURRENT_ACCOUNT:-없음} / 기대=${PROJECT_ACCOUNT_ID}
            지금 무엇이 잡혀 있는지:  aws sts get-caller-identity" ;;
esac

# region 이 서울이 아니면 경고
CUR_REGION=$(aws configure get region 2>/dev/null || true)
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
if [ "$KUBECTL_INSTALLED" = false ]; then
    info "STEP 4/8 : kubectl(${K8S_MINOR}.x) 설치 중..."
    KVER=$(curl -fsSL "https://dl.k8s.io/release/stable-${K8S_MINOR}.txt" 2>/dev/null || true)
    [ -z "$KVER" ] && KVER="v${K8S_MINOR}.0"
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
    sudo dnf remove -y podman buildah runc 2>/dev/null || true
    sudo dnf install -y yum-utils -q
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo -q 2>/dev/null || true
    sudo dnf makecache -q 2>/dev/null || true
    sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -q || error "Docker 설치 실패"
    sudo systemctl enable --now docker
    sudo usermod -aG docker "${SUDO_USER:-$USER}"
    command -v docker &>/dev/null && success "Docker 설치 완료: $(docker --version)" || error "Docker 설치 실패"
    warning "docker 그룹 적용을 위해 재로그인 또는 'newgrp docker' 필요"
else
    info "STEP 6/8 : Docker 건너뜀"
fi

# ── STEP 6.5 : Docker Hub 로그인 (공용 계정 hailscale · 토큰 파일 자동 생성) ────
info "STEP 6.5/8 : Docker Hub 로그인 확인 (공용 계정 hailscale)..."

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

export DOCKERHUB_USER DOCKERHUB_TOKEN
if [ -n "${DOCKERHUB_USER:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
    mkdir -p "$PROJECT_DOCKER_CONFIG"
    export DOCKER_CONFIG="$PROJECT_DOCKER_CONFIG"
    if docker info &>/dev/null; then
        echo "$DOCKERHUB_TOKEN" | docker login -u "$DOCKERHUB_USER" --password-stdin \
            && success "Docker Hub 로그인됨: $DOCKERHUB_USER" \
            || warning "Docker Hub 로그인 실패 → 토큰 확인"
    elif id -nG "${SUDO_USER:-$USER}" | grep -qw docker; then
        sg docker -c "DOCKER_CONFIG='$PROJECT_DOCKER_CONFIG'; echo '$DOCKERHUB_TOKEN' | docker login -u '$DOCKERHUB_USER' --password-stdin" \
            && success "Docker Hub 로그인됨: $DOCKERHUB_USER" \
            || warning "Docker Hub 로그인 실패 → 재로그인 후 bash setup.sh 재실행"
    else
        warning "docker 권한 미반영 → newgrp docker 후 bash setup.sh 재실행"
    fi
fi

# ── STEP 7 : EKS kubeconfig 연결 ───────────────────────────
info "STEP 7/8 : EKS kubeconfig 연결 (${CLUSTER_NAME})..."
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
    aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" \
        && success "kubeconfig 연결됨 → kubectl 사용 가능" \
        || warning "update-kubeconfig 실패 → 자격증명/권한 확인"
else
    warning "EKS 클러스터(${CLUSTER_NAME})가 아직 없음(apply 전이거나 권한 부족)."
    echo "    apply 후 재실행:  make kubeconfig   (또는 aws eks update-kubeconfig --name ${CLUSTER_NAME} --region ${AWS_REGION})"
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

# ── 자동 전환 훅 설치 (AWS_PROFILE + DOCKER_CONFIG 통합) ────
# 계정 일치 여부와 무관하게 항상 설치한다(멱등). 개인 default 가 곧 프로젝트 계정인
# 사람([hailcast] 프로필 없음)에게는 훅이 AWS_PROFILE 을 건드리지 않는다(grep 로 존재 확인).
install_hailcast_hook

echo "============================================="
success "환경 설치 완료!"
echo "============================================="
echo ""
echo "  다음 단계:"
echo "   1) docker 그룹 적용:   newgrp docker  (또는 재로그인) — setup 끝에 자동 진입 가능"
echo "   2) AWS 자격증명:       프로젝트 계정(${CURRENT_ACCOUNT}) 확인됨"
echo "                          → 개인 [default] 는 보존, 프로젝트 작업은 [hailcast] 프로필."
echo "                          → project3-hailcast 폴더에 들어가면 자동으로 [hailcast] 로 전환됨."
echo "                          → make 는 매번 'guard-account' 로 계정을 대조합니다."
echo "   3) Docker Hub :        setup.sh 중 입력한 공용(hailscale) 토큰으로 자동 로그인됨"
echo "   4) EKS 연결:           apply 후  make kubeconfig"
echo "   5) 환경 점검:          make check"
echo ""

# ── (맨 마지막) docker 그룹 즉시 적용 ──────────────────────
# ⚠️ newgrp 는 '새 셸 진입'이라 반드시 모든 작업의 맨 끝에 위치해야 한다.
#    이 새 셸은 ~/.bashrc 를 다시 읽어 위 훅을 반영한다(현재 창에서도 자동 전환 체감).
if [ -t 0 ] && command -v docker &>/dev/null && ! docker info &>/dev/null \
   && id -nG "${SUDO_USER:-$USER}" | grep -qw docker; then
    info "docker 그룹을 즉시 적용합니다 (새 셸 진입). 종료하려면 'exit' 입력 후 Enter."
    exec newgrp docker
fi
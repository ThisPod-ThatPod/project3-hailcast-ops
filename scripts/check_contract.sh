#!/bin/bash
# =============================================================
# 파일위치 : project3-hailcast-ops/scripts/check_contract.sh
# 이름 계약 검증기 (이 Pod 저 Pod · hailcast)
# 실행 : bash scripts/check_contract.sh   또는   make check-contract
#
# 왜 필요한가.
#   이 프로젝트에서 제일 비싼 사고는 '에러 없이 조용히 죽는 것' 이다.
#   노드 SG 에 태그 하나가 빠지면 파드가 DB 에 못 붙는데 증상은 연결 타임아웃뿐이고,
#   IRSA 역할명이 한 글자 어긋나면 '권한 없음' 만 뜬다. 원인이 IAM 인지 SA 인지 안 보인다.
#   그걸 시연 직전이 아니라 '매일' 잡자는 게 이 스크립트다.
#
# 무엇과 대조하나.
#   단일 진실원천 = infra 레포의 docs/네이밍규약서.md.
#   기대값은 아래 '계약 상수' 에 박아 둔다. 이건 규약서의 두 번째 사본이라 갈라질 수 있다.
#   그래서 팀 규칙이 있다. 규약 개정은 infra(문서) + ops(검증기) 짝 PR 로 간다.
#   안 고치면 이 검증기가 빨간불을 켜서 갈라졌다는 사실 자체를 알려준다.
#
# ⭐ 설계 원칙 두 개. 이걸 어기면 검증기가 조용히 무력해진다.
#   1) '줄' 이 아니라 '블록' 을 본다.
#      태그가 파일 어딘가에 있다고 통과시키면, 그 태그가 '노드 SG 에' 붙었는지 알 수 없다.
#      엉뚱한 리소스(런치템플릿 등)에 붙어도 초록불이 뜬다. 그러면 검증기가 거짓 안심을 준다.
#      → 중괄호를 세어 리소스 블록을 꺼내고, 그 블록 안에서 찾는다.
#   2) '문자열' 이 아니라 '값' 을 본다.
#      두 태그가 서로 같은지만 보면, 둘 다 hailcast-prod 여도 통과한다.
#      local.name_prefix 를 hailcast-dev 라고 '가정' 하면, 그 local 정의가 바뀌어도 모른다.
#      → locals 를 실제로 읽어 값을 풀고, 규약서 계약값과 대조한다.
#
# 2단으로 나눈 이유.
#   인프라 검사는 원래 전부 런타임(AWS 조회)이다. 그런데 클러스터는 apply 전이라 아직 없다.
#   그대로 짜면 오늘부터 '전부 건너뜀' 만 뜨고 정작 필요할 때 처음 돌아간다.
#     - 정적  : 코드에 그렇게 써 있나  (자격증명 불필요 → 지금부터 돈다)
#     - 런타임: 실제로 그렇게 만들어졌나 (클러스터 없으면 건너뜀)
#
# 알려진 한계 (숨기지 않는다).
#   - 문자열 안에 # 나 중괄호가 들어간 HCL 은 오파싱될 수 있다. 우리 코드엔 없다.
#   - CI 에서는 PROJECT_ACCOUNT_ID 를 GitHub Secret 으로 주입해야 런타임 검사가 돈다.
#     안 주면 _lib.sh 가 즉시 중단시킨다(조용히 건너뛰지 않는다).
#     ※ 옛 _lib.sh 는 AWS_PROFILE=hailcast 를 강제해서, CI(OIDC 환경변수)에선
#       프로필을 못 찾아 런타임 검사가 '조용히' 통째로 건너뛰어졌다. 그 강제는 제거됐다.
# =============================================================

# ── 공용 상수·계정 가드 (CLUSTER_NAME · AWS_REGION · PROJECT_ACCOUNT_ID) ──
# shellcheck source=scripts/_lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

OPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="${INFRA_DIR:-$OPS_ROOT/../project3-hailcast-infra}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 통과·실패·건너뜀을 따로 센다. 실패가 하나라도 있으면 exit 1 로 끝낸다.
# check.sh 가 전에 무엇이 어긋나도 항상 exit 0 이라, 화면은 빨간데 스크립트는 성공으로 끝났다.
# 나중에 CI 에 붙이면 CI 가 그냥 통과해 버린다.
PASS_N=0; FAIL_N=0; SKIP_N=0
ok()   { echo -e "  ${GREEN}✅ $1${NC}"; PASS_N=$((PASS_N+1)); }
fail() { echo -e "  ${RED}❌ $1${NC}"; FAIL_N=$((FAIL_N+1)); }
warn() { echo -e "  ${YELLOW}⚠️  $1${NC}"; }   # 경고는 실패가 아니다 (종료코드에 영향 없음)
skip() { echo -e "  ${BLUE}⏭  $1${NC}"; SKIP_N=$((SKIP_N+1)); }

# =============================================================
# 계약 상수 - 규약서와 한 글자도 다르면 안 된다
# =============================================================
PROJECT_NAME="hailcast"                        # 규약서 §2
ENVIRONMENT="dev"                              # 규약서 §2
NAME_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"   # hailcast-dev

DISCOVERY_TAG_KEY="karpenter.sh/discovery"
DISCOVERY_TAG_VALUE="$NAME_PREFIX"             # 규약서 §6-1. 서브넷·노드 SG 둘 다 이 값이어야 한다

NODE_SG_NAME="${NAME_PREFIX}-sg-eks-node"      # 규약서 §5-5
RDS_SG_NAME="${NAME_PREFIX}-sg-rds"            # 규약서 §5-5

# ※ kubernetes.io/cluster/<클러스터> = shared 태그는 검사하지 않는다.
#   AWS 공식 문서 확인 결과 레거시다. EKS 는 1.19+ 부터 이 태그를 서브넷에 붙이지 않고,
#   이걸 요구하는 건 AWS Load Balancer Controller 2.1.1 '이하' 뿐이다. 그 위 버전은
#   태그를 지워도 서비스가 끊기지 않는다고 문서가 명시한다.
#   서브넷 발견은 kubernetes.io/role/elb · internal-elb 가 담당하고 그건 아래에서 검사한다.
#   → 규약서 §6-1 에서 이 항목을 빼는 개정을 함께 올린다(짝 PR).

# IRSA 7종 - '역할키|네임스페이스:SA이름' (규약서 §5-3)
# 역할명은 hailcast-dev-irsa-<역할키> 로 만들어진다.
# forecast 는 폐기됐다(2026-07-13 · 결정 1 = predict 내장). 8종이 아니라 7종이다.
IRSA_BASE_KEYS=(lbctrl monitoring)             # enable_app_irsa 와 무관하게 항상 만들어진다
IRSA_CONTRACT=(
  "lbctrl|kube-system:aws-load-balancer-controller"
  "monitoring|monitoring:monitoring-sa"
  "predict|hailcast:predict-sa"
  "call-api|hailcast:call-api-sa"
  "worker|hailcast:worker-sa"
  "keda|keda:keda-operator"
  "karpenter|kube-system:karpenter"
)

# 정당한 와일드카드의 sid 목록.
# ⚠️ '와일드카드 금지' 가 아니라 '검토되지 않은 와일드카드 금지' 다.
#    여기 없는 새 와일드카드가 생기면 빨간불이 뜬다. 예외를 추가할 땐 이유를 함께 적는다.
ALLOWED_WILDCARD_SIDS=(
  "EcrAuth"   # ecr:GetAuthorizationToken 은 리소스 지정이 불가능한 계정 단위 액션이다(AWS 사양)
)

# 액션 와일드카드 금지 목록. sqs:* 는 sqs:PurgeQueue 를 '포함' 한다.
# 글자 그대로의 PurgeQueue 만 찾으면 이 우회로가 그대로 뚫린다.
FORBIDDEN_ACTION_PATTERNS='(^|[",[:space:]])(\*|sqs:\*|s3:\*|dynamodb:\*|iam:\*)([",[:space:]]|$)'

# =============================================================
# HCL 파서 헬퍼 - 중괄호를 세어 '블록' 을 다룬다
# =============================================================

# 블록 하나를 꺼낸다.  hcl_block <type> <name> <file...>
# 들여쓰기와 무관하다(^resource 에 의존하지 않는다 → fmt 안 된 코드도 본다).
# "${...}" 보간의 중괄호는 한 줄 안에서 짝이 맞으므로 깊이 계산을 흔들지 않는다.
hcl_block() {
    local type="$1" name="$2"; shift 2
    awk -v type="$type" -v name="$name" '
        { line=$0; sub(/#.*$/, "", line) }
        !inb {
            if (line ~ "^[[:space:]]*(resource|data)[[:space:]]+\"" type "\"[[:space:]]+\"" name "\"") {
                inb=1; depth=0
            } else next
        }
        inb {
            print line
            depth += gsub(/{/, "{", line) - gsub(/}/, "}", line)
            if (depth <= 0) inb=0
        }
    ' "$@"
}

# 어떤 타입의 리소스 이름들을 나열한다.  hcl_names <type> <file...>
hcl_names() {
    local type="$1"; shift
    sed 's/#.*$//' "$@" 2>/dev/null \
        | grep -oE "resource[[:space:]]+\"$type\"[[:space:]]+\"[^\"]+\"" \
        | sed 's/.*"\([^"]*\)"$/\1/'
}

# locals 블록에서 키의 '정의식' 을 꺼낸다.  locals_value <key> <module_dir>
# ⚠️ locals 블록 안만 본다. nodegroup.tf 의 launch_template 에도 name_prefix 라는
#    '속성' 이 있어서, 파일 전체를 grep 하면 그걸 집는다.
locals_value() {
    local key="$1" dir="$2"
    awk -v key="$key" '
        { line=$0; sub(/#.*$/, "", line) }
        !inb { if (line ~ /^[[:space:]]*locals[[:space:]]*{/) { inb=1; depth=1 } ; next }
        inb {
            if (match(line, "^[[:space:]]*" key "[[:space:]]*=")) {
                v=line; sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", v); print v; exit
            }
            depth += gsub(/{/, "{", line) - gsub(/}/, "}", line)
            if (depth <= 0) inb=0
        }
    ' "$dir"/*.tf 2>/dev/null | head -1
}

# 식을 실제 '값' 으로 푼다.  resolve_expr <expr> <module_dir>
#   local.name_prefix → 그 모듈 locals 를 읽어 실제 정의를 푼다 ('가정' 하지 않는다)
#   ${var.project_name}-${var.environment} → hailcast-dev
resolve_expr() {
    local e="$1" dir="$2" np
    e="$(echo "$e" | sed 's/[[:space:]]*$//')"
    if [[ "$e" == *"local.name_prefix"* ]]; then
        np="$(locals_value name_prefix "$dir")"
        np="$(echo "$np" | sed 's/[[:space:]]*$//' | tr -d '"')"
        np="${np//\$\{var.project_name\}/$PROJECT_NAME}"
        np="${np//\$\{var.environment\}/$ENVIRONMENT}"
        # ⚠️ 보간 형태(${local.name_prefix})를 '먼저' 푼다. 감싼 중괄호까지 함께 걷어내야 한다.
        #    안 그러면 "${local.name_prefix}-sg-eks-node" 가 "${hailcast-dev}-sg-eks-node" 로 남아
        #    이름 대조가 항상 실패한다(리소스를 못 찾는다).
        e="${e//\$\{local.name_prefix\}/$np}"
        e="${e//local.name_prefix/$np}"
    fi
    e="${e//\$\{var.project_name\}/$PROJECT_NAME}"
    e="${e//\$\{var.environment\}/$ENVIRONMENT}"
    e="${e//var.project_name/$PROJECT_NAME}"
    e="${e//var.environment/$ENVIRONMENT}"
    e="$(echo "$e" | tr -d '"')"
    echo "$e"
}

# 블록(stdin) 안에서 어떤 속성/태그의 우변을 꺼낸다.  attr_of <키>
attr_of() {
    sed 's/#.*$//' | grep -m1 -E "^[[:space:]]*\"?$1\"?[[:space:]]*=" | sed 's/^[^=]*=[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

# IAM 정책의 statement 블록을 '한 줄로 접어' 출력한다.  iam_statements <file...>
#   출력: 파일:시작줄|<접힌 본문>
# ⭐ 멀티라인 리스트 때문에 접는다. terraform fmt 는 리스트가 길어지면
#      resources = [
#        "a",
#        "b",
#      ]
#    형태로 만든다. 한 줄만 보면 이걸 통째로 놓친다(우리 irsa.tf 가 이미 이 스타일이다).
iam_statements() {
    awk '
        { line=$0; sub(/#.*$/, "", line) }
        !inst {
            if (line ~ /statement[[:space:]]*{/) { inst=1; depth=1; body=line; start=FNR }
            next
        }
        inst {
            body = body " " line
            depth += gsub(/{/, "{", line) - gsub(/}/, "}", line)
            if (depth <= 0) { gsub(/[[:space:]]+/, " ", body); print FILENAME ":" start "|" body; inst=0 }
        }
    ' "$@" 2>/dev/null
}

echo ""
echo "============================================="
echo "  hailcast 이름 계약 검증기 (check-contract)"
echo "============================================="

# ── 검사 대상이 '어느 상태' 인지 먼저 밝힌다 ──────────────
# 이게 없으면 낡은 브랜치를 체크아웃해 둔 채 돌리고도 초록불을 보게 된다.
if [ ! -d "$INFRA_DIR" ]; then
    fail "infra 레포 없음: $INFRA_DIR → make clone-all"
    echo ""
    exit 1
fi
INFRA_REF=$(git -C "$INFRA_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
INFRA_SHA=$(git -C "$INFRA_DIR" log -1 --format=%h 2>/dev/null || echo "?")
INFRA_DIRTY=$(git -C "$INFRA_DIR" status --porcelain 2>/dev/null | head -1)
echo ""
echo "  검사 대상 : $INFRA_DIR"
echo "  브랜치    : $INFRA_REF ($INFRA_SHA)${INFRA_DIRTY:+  · 커밋 안 된 변경 있음}"
# dev 가 아니어도 막지 않는다. 자기가 방금 고친 브랜치를 검사하는 것도 정당한 용도다.
if [ "$INFRA_REF" != "dev" ]; then
    warn "dev 가 아니다. 통합 상태를 보려면: git -C $INFRA_DIR fetch && git -C $INFRA_DIR checkout dev"
fi

TF_FILES=$(find "$INFRA_DIR/modules" "$INFRA_DIR/envs" -name '*.tf' -not -path '*/.terraform/*' 2>/dev/null)

# =============================================================
# [ 1 ] 정적 검사 - terraform 소스와 규약서 대조 (자격증명 불필요)
# =============================================================
echo ""
echo "[ 1 ] 정적 검사 - terraform 소스와 규약서 대조"

# ── 1-1. 프라이빗 서브넷의 자동발견 태그 (§6-1) ──
# 태그가 '서브넷 블록 안에' 있고 값이 계약값이어야 한다.
# 파일 어딘가에 있는 것만으로는 안 된다. 라우팅테이블에 붙어 있어도 Karpenter 는 못 찾는다.
SUBNET_TAG_VAL=""
for rn in $(hcl_names aws_subnet "$INFRA_DIR"/modules/network/*.tf); do
    case "$rn" in *private*) ;; *) continue ;; esac
    v=$(hcl_block aws_subnet "$rn" "$INFRA_DIR"/modules/network/*.tf | attr_of "$DISCOVERY_TAG_KEY")
    [ -n "$v" ] && SUBNET_TAG_VAL=$(resolve_expr "$v" "$INFRA_DIR/modules/network") && break
done
if [ -z "$SUBNET_TAG_VAL" ]; then
    fail "프라이빗 서브넷 블록 안에 $DISCOVERY_TAG_KEY 태그가 없다. Karpenter 가 노드 띄울 서브넷을 못 찾는다(§6-1)"
elif [ "$SUBNET_TAG_VAL" != "$DISCOVERY_TAG_VALUE" ]; then
    fail "서브넷 태그 값이 계약과 다르다: '$SUBNET_TAG_VAL' (기대: '$DISCOVERY_TAG_VALUE') → Karpenter 가 서브넷을 못 찾는다(§6-1)"
else
    ok "프라이빗 서브넷에 $DISCOVERY_TAG_KEY = $SUBNET_TAG_VAL (§6-1)"
fi

# ── 1-2. 노드 SG 의 자동발견 태그 (§6-1) ──
# ⭐ 이게 빠지면 앱이 DB 에 못 붙는다. 그것도 에러 없이.
#    RDS 는 5432 를 '노드 SG 를 단 놈' 에게만 연다(§5-5). 그런데 DB 를 쓰는 파드는
#    Karpenter 가 띄운 노드에 산다. Karpenter 는 SG 를 '태그 검색' 해 붙이므로,
#    태그가 없으면 그 노드는 노드 SG 를 못 단다. 증상은 연결 타임아웃뿐이다.
#
# SG 를 '이름' 으로 특정한다. 규약서 §5-5 의 이름 계약(hailcast-dev-sg-eks-node)과
# 태그 계약(§6-1)을 한 번에 검사하는 셈이다.
NODE_SG_BLOCK=""
for rn in $(hcl_names aws_security_group "$INFRA_DIR"/modules/eks/*.tf); do
    blk=$(hcl_block aws_security_group "$rn" "$INFRA_DIR"/modules/eks/*.tf)
    nm=$(resolve_expr "$(echo "$blk" | attr_of name)" "$INFRA_DIR/modules/eks")
    if [ "$nm" = "$NODE_SG_NAME" ]; then NODE_SG_BLOCK="$blk"; break; fi
done
if [ -z "$NODE_SG_BLOCK" ]; then
    fail "이름이 '$NODE_SG_NAME' 인 보안그룹을 modules/eks 에서 못 찾았다(§5-5)"
else
    v=$(echo "$NODE_SG_BLOCK" | attr_of "$DISCOVERY_TAG_KEY")
    NODESG_TAG_VAL=$(resolve_expr "$v" "$INFRA_DIR/modules/eks")
    if [ -z "$v" ]; then
        fail "노드 SG($NODE_SG_NAME) 블록 안에 $DISCOVERY_TAG_KEY 태그가 없다. Karpenter 노드가 RDS 에 조용히 못 붙는다(§6-1)"
    elif [ "$NODESG_TAG_VAL" != "$DISCOVERY_TAG_VALUE" ]; then
        fail "노드 SG 태그 값이 계약과 다르다: '$NODESG_TAG_VAL' (기대: '$DISCOVERY_TAG_VALUE') (§6-1)"
    else
        ok "노드 SG($NODE_SG_NAME)에 $DISCOVERY_TAG_KEY = $NODESG_TAG_VAL (§6-1)"
    fi
fi

# ── 1-3. ALB Controller 의 서브넷 자동발견 태그 (§6-1) ──
# 이 두 태그가 '실제로' 서브넷 발견을 담당한다(AWS LB Controller 공식 문서).
# 빠지면 Ingress 를 만들어도 LB 를 놓을 서브넷을 못 찾아 ALB 생성이 실패한다.
grep -rq '"kubernetes.io/role/elb"' "$INFRA_DIR"/modules/network/*.tf 2>/dev/null \
    && ok "퍼블릭 서브넷에 kubernetes.io/role/elb 태그 있음 (§6-1)" \
    || fail "퍼블릭 서브넷에 kubernetes.io/role/elb 태그가 없다. 외부 ALB 생성이 실패한다(§6-1)"
grep -rq '"kubernetes.io/role/internal-elb"' "$INFRA_DIR"/modules/network/*.tf 2>/dev/null \
    && ok "프라이빗 서브넷에 kubernetes.io/role/internal-elb 태그 있음 (§6-1)" \
    || fail "프라이빗 서브넷에 kubernetes.io/role/internal-elb 태그가 없다(§6-1)"

# ── 1-4. RDS 5432 인바운드가 'SG 참조' 인가 (§5-5) ──
# CIDR 로 열면 그 대역의 아무나 DB 에 붙는다. 실무 정석은 다른 SG 를 지목하는 것이다.
#
# ⚠️ '파일' 이 아니라 '규칙 블록' 을 본다. 같은 파일에 정상 egress 규칙
#    (cidr_ipv4 = "0.0.0.0/0")이 함께 있어도 그건 5432 ingress 와 무관하다.
#    파일 전체를 보면 멀쩡한 구성을 "CIDR 로 열려 있다" 고 오신고한다.
RDS_RULE=""
for rn in $(hcl_names aws_vpc_security_group_ingress_rule "$INFRA_DIR"/modules/data/*.tf); do
    blk=$(hcl_block aws_vpc_security_group_ingress_rule "$rn" "$INFRA_DIR"/modules/data/*.tf)
    if echo "$blk" | grep -qE 'from_port[[:space:]]*=[[:space:]]*5432'; then RDS_RULE="$blk"; break; fi
done
if [ -z "$RDS_RULE" ]; then
    fail "RDS 5432 인바운드 규칙이 없다 (modules/data 에 from_port = 5432 인 ingress 규칙 없음 · §5-5)"
elif echo "$RDS_RULE" | grep -qE 'cidr_ipv4|cidr_ipv6|cidr_blocks'; then
    fail "RDS 5432 규칙이 CIDR 로 열려 있다. SG 참조로 바꿔라(§5-5)"
elif echo "$RDS_RULE" | grep -q 'referenced_security_group_id'; then
    ok "RDS 5432 인바운드가 노드 SG 참조다 (§5-5)"
else
    fail "RDS 5432 규칙이 SG 를 지목하지 않는다(§5-5)"
fi

# ── 1-5. IRSA 7종의 역할키 ↔ ServiceAccount 계약 (§5-3) ──
# 이 문자열이 manifests 의 serviceaccount.yaml 과 맺는 계약이다.
# IRSA 신뢰정책이 system:serviceaccount:<ns>:<sa> 로 못을 박으므로, 파드가 다른 SA 로 뜨면
# AssumeRole 이 거부돼 '권한 없음' 이 된다. 로그만 보면 IAM 정책 문제로 착각하게 된다.
#
# ⚠️ 역할명을 문자열로 grep 하면 안 된다. 이름이 "${local.name_prefix}-irsa-${each.key}" 로
#    보간돼 만들어져서 hailcast-dev-irsa-predict 라는 문자열은 코드 어디에도 없다.
IRSA_TF="$INFRA_DIR/modules/eks/irsa.tf"
if [ ! -f "$IRSA_TF" ]; then
    fail "modules/eks/irsa.tf 가 없다"
else
    IRSA_MISS=0
    for pair in "${IRSA_CONTRACT[@]}"; do
        key="${pair%%|*}"; sa="${pair#*|}"
        if ! sed 's/#.*$//' "$IRSA_TF" | grep -qE "^[[:space:]]*\"?${key}\"?[[:space:]]*=[[:space:]]*\"${sa}\""; then
            fail "IRSA 계약 어긋남: ${NAME_PREFIX}-irsa-${key} 의 SA '${sa}' 가 irsa.tf 에 없다(§5-3)"
            IRSA_MISS=$((IRSA_MISS+1))
        fi
    done
    [ "$IRSA_MISS" -eq 0 ] && ok "IRSA ${#IRSA_CONTRACT[@]}종의 역할키·SA 가 규약서 §5-3 과 일치한다"
fi

# ── 1-6·1-7. IAM 정책 statement 전수 검사 ──
# 손으로 쓴 정책만 본다. upstream 벤더링(modules/eks/policies/)은 제외한다.
# 원본에 * 가 정상적으로 들어 있어(ALB 컨트롤러 10건) 같이 세면 매일 거짓 경보가 뜬다.
# 거짓 경보가 뜨는 검증기는 아무도 안 본다. 그러면 진짜 문제도 같이 묻힌다.
PURGE_BAD=0; WILD_BAD=0
while IFS='|' read -r loc body; do
    [ -z "$body" ] && continue
    sid=$(echo "$body" | grep -oE 'sid[[:space:]]*=[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\(.*\)"/\1/')
    acts=$(echo "$body" | grep -oE 'actions[[:space:]]*=[[:space:]]*\[[^]]*\]' | head -1)
    ress=$(echo "$body" | grep -oE 'resources[[:space:]]*=[[:space:]]*\[[^]]*\]' | head -1)
    rel="${loc#"$INFRA_DIR"/}"

    # (1-6) PurgeQueue - 글자 그대로 + 와일드카드로 '포함' 되는 경우까지
    if echo "$acts" | grep -q 'PurgeQueue'; then
        fail "sqs:PurgeQueue 권한이 있다 ($rel · sid=${sid:-없음}). 시연 중 큐가 비어 스케일링이 무너진다"
        PURGE_BAD=$((PURGE_BAD+1))
    elif echo "$acts" | grep -qE '"(\*|sqs:\*)"'; then
        fail "액션 와일드카드가 sqs:PurgeQueue 를 포함한다 ($rel · sid=${sid:-없음}). 액션을 명시로 좁혀라"
        PURGE_BAD=$((PURGE_BAD+1))
    fi

    # (1-7) 과도 권한 - actions 전권 · resources 와일드카드
    if echo "$acts" | grep -qE "$FORBIDDEN_ACTION_PATTERNS"; then
        allowed=0
        for a in "${ALLOWED_WILDCARD_SIDS[@]}"; do [ "$sid" = "$a" ] && allowed=1; done
        if [ "$allowed" -eq 0 ]; then
            fail "액션이 너무 넓다 ($rel · sid=${sid:-없음}): $acts"
            WILD_BAD=$((WILD_BAD+1))
        fi
    fi
    if echo "$ress" | grep -qE '"\*"'; then
        allowed=0
        for a in "${ALLOWED_WILDCARD_SIDS[@]}"; do [ "$sid" = "$a" ] && allowed=1; done
        if [ "$allowed" -eq 0 ]; then
            fail "검토되지 않은 Resource=\"*\" ($rel · sid=${sid:-없음}). 리소스 단위로 좁혀라"
            WILD_BAD=$((WILD_BAD+1))
        fi
    fi
done < <(iam_statements $(echo "$TF_FILES" | grep -v '/policies/'))
[ "$PURGE_BAD" -eq 0 ] && ok "sqs:PurgeQueue 권한 없음 (와일드카드 포함 검사)"
[ "$WILD_BAD" -eq 0 ] && ok "손으로 쓴 IAM 정책에 검토되지 않은 와일드카드 없음"

# ── 1-8. SG·IAM 정책의 description 이 비었나 ──
# ⭐ description 은 나중에 못 고친다. 바꾸면 리소스가 '재생성' 된다.
#    SG 재생성은 그 SG 를 참조하는 RDS 규칙까지 흔든다. 처음부터 채우는 게 유일한 방법이다.
#    빈 문자열("")도 없는 것으로 친다. 재생성 위험은 똑같다.
#
# ⚠️ 값이 '따옴표 리터럴' 이 아닐 수도 있다. irsa.tf 의 정책은
#      description = local.irsa_app_policy_desc[each.key]
#    처럼 식으로 대입한다. 리터럴만 인정하면 멀쩡한 코드를 빨간불로 신고한다.
#    → '= 뒤에 뭐라도 있으면' 통과. 빈 문자열("")만 잡는다.
DESC_MISS=$(echo "$TF_FILES" | xargs awk '
  { line=$0; sub(/#.*$/, "", line) }
  !inb {
     if (line ~ /^[[:space:]]*resource[[:space:]]+"(aws_security_group|aws_iam_policy)"[[:space:]]+"[^"]+"/) {
        inb=1; depth=0; hdr=line; d=0; start=FNR
     } else next
  }
  inb {
     if (line ~ /description[[:space:]]*=[[:space:]]*""[[:space:]]*$/)      d=0   # 빈 문자열 = 없는 것과 같다
     else if (line ~ /description[[:space:]]*=[[:space:]]*[^[:space:]]/)    d=1   # 리터럴이든 식이든 채워져 있다
     depth += gsub(/{/, "{", line) - gsub(/}/, "}", line)
     if (depth <= 0) { if (!d) printf "%s:%d:%s\n", FILENAME, start, hdr; inb=0 }
  }
' 2>/dev/null)
if [ -n "$DESC_MISS" ]; then
    fail "description 이 비었거나 없는 SG·IAM 정책이 있다. 나중에 못 고친다(바꾸면 재생성된다)"
    echo "$DESC_MISS" | sed "s|$INFRA_DIR/|      |"
else
    ok "SG·IAM 정책에 description 이 모두 채워져 있다"
fi

# =============================================================
# [ 2 ] 런타임 검사 - AWS 실물과 규약서 대조 (apply 이후에만)
# =============================================================
echo ""
echo "[ 2 ] 런타임 검사 - AWS 실물과 규약서 대조"

# 엉뚱한 계정에 앉은 채로 조회하면 '리소스가 없다' 며 전부 빨간불이 뜬다.
# 계정부터 대조하고, 아니면 검사 자체를 하지 않는다(_lib.sh 의 가드를 그대로 쓴다).
#
# ⚠️ 함수 이름을 틀리면 command not found → rc=127 → 아래 '-ne 0' 에 걸려 skip 으로 빠지고,
#    skip 은 실패가 아니라 스크립트가 exit 0(초록불)로 끝난다. 검증기가 조용히 꺼진다.
#    _lib.sh 의 함수명이 바뀌면 여기도 반드시 같이 바꾼다.
rc=0; verify_project_account || rc=$?
if [ "$rc" -ne 0 ]; then
    skip "프로젝트 계정 자격증명 없음. 런타임 검사를 건너뛴다 (정적 검사만 수행)"
    echo "     rc=$rc (1=다른 계정 · 2=자격증명 없음/만료) · 현재 계정=${CURRENT_ACCOUNT:-없음}"
elif ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
    skip "클러스터 $CLUSTER_NAME 없음(apply 전). 런타임 검사를 건너뛴다"
else
    # ── 2-1. 서브넷 실물 태그 ──
    SUBNET_N=$(aws ec2 describe-subnets --region "$AWS_REGION" \
        --filters "Name=tag:${DISCOVERY_TAG_KEY},Values=${DISCOVERY_TAG_VALUE}" \
        --query 'length(Subnets)' --output text 2>/dev/null || echo 0)
    if [ "$SUBNET_N" -ge 2 ]; then
        ok "서브넷 ${SUBNET_N}개에 ${DISCOVERY_TAG_KEY}=${DISCOVERY_TAG_VALUE} 태그가 실제로 붙어 있다"
    else
        fail "태그된 서브넷이 ${SUBNET_N}개다 (프라이빗 2개 기대). Karpenter 가 노드를 못 띄운다"
    fi

    # ── 2-2. 노드 SG 실물 태그 ──
    SG_TAGGED=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
        --filters "Name=tag:${DISCOVERY_TAG_KEY},Values=${DISCOVERY_TAG_VALUE}" \
                  "Name=group-name,Values=${NODE_SG_NAME}" \
        --query 'length(SecurityGroups)' --output text 2>/dev/null || echo 0)
    if [ "$SG_TAGGED" -ge 1 ]; then
        ok "노드 SG(${NODE_SG_NAME})에 태그가 실제로 붙어 있다"
    else
        fail "노드 SG(${NODE_SG_NAME})에 ${DISCOVERY_TAG_KEY} 태그가 없다. Karpenter 노드가 RDS 에 못 붙는다"
    fi

    # ── 2-3. IRSA 역할이 실제로 생성됐나 ──
    # ⚠️ 기대 개수를 '스위치 상태' 에서 뽑는다.
    #    enable_app_irsa = false 는 고장이 아니라 '설계된 정상 상태' 다(ARN 배선 전).
    #    그걸 "2/7 개다" 라고 신고하면 정상 상태에 매일 빨간불이 뜬다.
    if grep -rqE 'enable_app_irsa[[:space:]]*=[[:space:]]*true' "$INFRA_DIR"/envs/dev/*.tf 2>/dev/null; then
        EXPECT_KEYS=(); for p in "${IRSA_CONTRACT[@]}"; do EXPECT_KEYS+=("${p%%|*}"); done
        SWITCH_STATE="켜짐"
    else
        EXPECT_KEYS=("${IRSA_BASE_KEYS[@]}")
        SWITCH_STATE="꺼짐(앱 5종은 아직 안 만들어지는 게 정상)"
    fi
    IRSA_MADE=0; IRSA_ABSENT=""
    for key in "${EXPECT_KEYS[@]}"; do
        if aws iam get-role --role-name "${NAME_PREFIX}-irsa-${key}" &>/dev/null; then
            IRSA_MADE=$((IRSA_MADE+1))
        else
            IRSA_ABSENT="${IRSA_ABSENT} ${key}"
        fi
    done
    if [ "$IRSA_MADE" -eq "${#EXPECT_KEYS[@]}" ]; then
        ok "IRSA 역할 ${IRSA_MADE}/${#EXPECT_KEYS[@]}종 생성됨 (enable_app_irsa=$SWITCH_STATE)"
    else
        fail "IRSA 역할이 ${IRSA_MADE}/${#EXPECT_KEYS[@]}개다. 없는 것:${IRSA_ABSENT} (enable_app_irsa=$SWITCH_STATE)"
    fi

    # ── 2-4. RDS SG 의 5432 규칙이 노드 SG 를 지목하나 ──
    RDS_SG_ID=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
        --filters "Name=group-name,Values=${RDS_SG_NAME}" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
    if [ -z "$RDS_SG_ID" ] || [ "$RDS_SG_ID" = "None" ]; then
        skip "RDS SG(${RDS_SG_NAME}) 없음. 5432 규칙 검사를 건너뛴다"
    else
        PAIRS=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$RDS_SG_ID" \
            --query 'SecurityGroups[0].IpPermissions[?FromPort==`5432`].UserIdGroupPairs[].GroupId' \
            --output text 2>/dev/null)
        CIDRS=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$RDS_SG_ID" \
            --query 'SecurityGroups[0].IpPermissions[?FromPort==`5432`].IpRanges[].CidrIp' \
            --output text 2>/dev/null)
        if [ -n "$CIDRS" ]; then
            fail "RDS 5432 가 CIDR($CIDRS)로 열려 있다. SG 참조로 바꿔라(§5-5)"
        elif [ -n "$PAIRS" ]; then
            ok "RDS 5432 인바운드가 SG($PAIRS)만 허용한다"
        else
            fail "RDS 5432 인바운드 규칙이 없다. 앱이 DB 에 못 붙는다"
        fi
    fi
fi

# =============================================================
echo ""
echo "============================================="
if [ "$FAIL_N" -gt 0 ]; then
    echo -e "  ${RED}계약 위반 : 통과 ${PASS_N} · 실패 ${FAIL_N} · 건너뜀 ${SKIP_N}${NC}"
    echo "  위의 ❌ 는 대개 '조용히' 죽는 것들이다. 배포 전에 해결하라."
    echo "============================================="
    echo ""
    exit 1
fi
echo -e "  ${GREEN}계약 준수 : 통과 ${PASS_N} · 실패 0 · 건너뜀 ${SKIP_N}${NC}"
[ "$SKIP_N" -gt 0 ] && echo "  ※ 건너뛴 검사는 apply 이후 다시 돌리면 실행된다."
echo "============================================="
echo ""

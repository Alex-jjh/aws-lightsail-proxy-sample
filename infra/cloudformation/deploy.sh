#!/bin/bash
# ============================================================
# Lightsail Proxy - CloudFormation 一键部署 / one-click deploy
# ============================================================
# Usage / 用法:
#   ./deploy.sh [env] [OPTIONS]
#
# Presets / 预设:
#   tokyo | singapore | frankfurt | custom
#   Default: tokyo / 默认 tokyo
#
# Options / 选项:
#   --region REGION         AWS region (e.g. ap-south-1)
#                           覆盖部署区域
#   --bundle BUNDLE_ID      Lightsail bundle (e.g. micro_3_0)
#                           覆盖套餐
#   --blueprint BP_ID       OS blueprint (e.g. ubuntu_24_04)
#                           覆盖操作系统镜像
#   --name NAME             Instance name / 实例名称
#   --az SUFFIX             AZ suffix (a/b/c/d)
#   --key-pair NAME         SSH key pair name / SSH 密钥对名称
#   --panel-port N          3x-ui panel port (default 18918)
#                           面板端口
#   --proxy-port N          Main proxy port (default 443)
#                           代理主端口
#   --ss-port N             Shadowsocks port (default 8388)
#                           SS 备用端口
#   --stack-name NAME       CFN stack name
#                           CloudFormation 栈名称
#   --auto-approve          Skip confirmation / 跳过确认
#   -h, --help              Show help / 显示帮助
#
# Precedence (high → low) / 参数优先级（高 → 低）:
#   1. CLI flags / 命令行参数
#   2. parameters/<env>.json / 预设参数文件
#   3. template defaults / 模板默认值
#
# Examples / 示例:
#   ./deploy.sh tokyo
#   ./deploy.sh tokyo --bundle micro_3_0
#   ./deploy.sh custom --region ap-south-1 --bundle small_3_0 \
#                      --name my-proxy --key-pair my-ssh-key
#   ./deploy.sh tokyo --proxy-port 8443 --auto-approve
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/template.yaml"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

usage() {
    sed -n '/^# Usage/,/^# ===/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

# ------------------------------------------------------------
# Default region per preset / 预设到默认区域的映射
# ------------------------------------------------------------
default_region_for() {
    case "$1" in
        tokyo)     echo "ap-northeast-1" ;;
        singapore) echo "ap-southeast-1" ;;
        frankfurt) echo "eu-central-1"  ;;
        custom)    echo "" ;;
        *)         echo "" ;;
    esac
}

RECOMMENDED_REGIONS=(
    ap-northeast-1 ap-northeast-2 ap-southeast-1 ap-southeast-2
    ap-south-1 eu-central-1 eu-west-1 eu-west-2 eu-west-3
    eu-north-1 sa-east-1 ca-central-1
)
US_REGIONS=(us-east-1 us-east-2 us-west-1 us-west-2)

is_in_list() {
    local needle="$1"; shift
    for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
    return 1
}

# ------------------------------------------------------------
# Parse args / 解析参数
# ------------------------------------------------------------
ENV="tokyo"
OVERRIDE_REGION=""
OVERRIDE_BUNDLE=""
OVERRIDE_BLUEPRINT=""
OVERRIDE_NAME=""
OVERRIDE_AZ=""
OVERRIDE_KEYPAIR=""
OVERRIDE_PANEL_PORT=""
OVERRIDE_PROXY_PORT=""
OVERRIDE_SS_PORT=""
STACK_NAME=""
AUTO_APPROVE=false

if [[ $# -gt 0 && "$1" != -* ]]; then
    ENV="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)       OVERRIDE_REGION="$2";      shift 2 ;;
        --bundle)       OVERRIDE_BUNDLE="$2";      shift 2 ;;
        --blueprint)    OVERRIDE_BLUEPRINT="$2";   shift 2 ;;
        --name)         OVERRIDE_NAME="$2";        shift 2 ;;
        --az)           OVERRIDE_AZ="$2";          shift 2 ;;
        --key-pair)     OVERRIDE_KEYPAIR="$2";     shift 2 ;;
        --panel-port)   OVERRIDE_PANEL_PORT="$2";  shift 2 ;;
        --proxy-port)   OVERRIDE_PROXY_PORT="$2";  shift 2 ;;
        --ss-port)      OVERRIDE_SS_PORT="$2";     shift 2 ;;
        --stack-name)   STACK_NAME="$2";           shift 2 ;;
        --auto-approve) AUTO_APPROVE=true;         shift ;;
        -h|--help)      usage ;;
        *) log_error "Unknown option: $1 (use -h for help)"; exit 1 ;;
    esac
done

# ------------------------------------------------------------
# Resolve region / 解析最终区域
# ------------------------------------------------------------
REGION=""
if [[ -n "$OVERRIDE_REGION" ]]; then
    REGION="$OVERRIDE_REGION"
else
    REGION=$(default_region_for "$ENV")
fi

if [[ -z "$REGION" ]]; then
    log_error "Region not determined. Use --region REGION with 'custom' env"
    log_error "无法确定区域，使用 custom 环境时必须通过 --region 指定"
    exit 1
fi

# Warn on risky regions
if is_in_list "$REGION" "${US_REGIONS[@]}"; then
    log_warn "⚠️  US region detected: $REGION"
    log_warn "⚠️  检测到美国区域: $REGION"
    log_warn "US IPs are often flagged by streaming services / 美国 IP 容易被风控"
elif ! is_in_list "$REGION" "${RECOMMENDED_REGIONS[@]}"; then
    log_warn "Region '$REGION' is not in the tested list"
    log_warn "区域 '$REGION' 不在已测试列表，请确认 Lightsail 支持"
fi

# ------------------------------------------------------------
# Resolve params file / 解析参数文件
# ------------------------------------------------------------
PARAMS_FILE=""
if [[ "$ENV" != "custom" ]]; then
    PARAMS_FILE="${SCRIPT_DIR}/parameters/${ENV}.json"
    if [[ ! -f "$PARAMS_FILE" ]]; then
        log_error "Params file not found: $PARAMS_FILE"
        log_error "Available envs: tokyo | singapore | frankfurt | custom"
        exit 1
    fi
fi

# ------------------------------------------------------------
# Resolve stack name / 解析栈名称
# ------------------------------------------------------------
if [[ -z "$STACK_NAME" ]]; then
    STACK_NAME="lightsail-proxy-${ENV}"
fi

echo -e "${GREEN}=== Lightsail Proxy CloudFormation Deploy ===${NC}"
echo "  Environment: ${YELLOW}${ENV}${NC}"
echo "  Region:      ${YELLOW}${REGION}${NC}"
echo "  Stack:       ${YELLOW}${STACK_NAME}${NC}"
echo ""

# ------------------------------------------------------------
# Pre-flight / 前置检查
# ------------------------------------------------------------
log_step "Pre-flight checks / 前置检查..."

command -v aws >/dev/null 2>&1 || {
    log_error "aws cli not installed / AWS CLI 未安装"
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    log_error "jq not installed / jq 未安装 (brew install jq)"
    exit 1
}

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS CLI not configured / AWS CLI 未配置"
    exit 1
fi

[[ -f "$TEMPLATE_FILE" ]] || { log_error "Template not found: $TEMPLATE_FILE"; exit 1; }

log_info "AWS identity: $(aws sts get-caller-identity --query Arn --output text)"

# ------------------------------------------------------------
# Build parameter overrides / 构建参数
# Strategy: start with preset JSON, then apply CLI overrides
# 策略：先加载预设 JSON，再用命令行参数覆盖
# ------------------------------------------------------------
declare -A PARAMS

# 1. Load preset params into associative array
if [[ -n "$PARAMS_FILE" ]]; then
    while IFS=$'\t' read -r k v; do
        PARAMS["$k"]="$v"
    done < <(jq -r '.[] | [.ParameterKey, .ParameterValue] | @tsv' "$PARAMS_FILE")
fi

# 2. Apply CLI overrides (higher priority)
[[ -n "$OVERRIDE_BUNDLE"      ]] && PARAMS["BundleId"]="$OVERRIDE_BUNDLE"
[[ -n "$OVERRIDE_BLUEPRINT"   ]] && PARAMS["BlueprintId"]="$OVERRIDE_BLUEPRINT"
[[ -n "$OVERRIDE_NAME"        ]] && PARAMS["InstanceName"]="$OVERRIDE_NAME"
[[ -n "$OVERRIDE_AZ"          ]] && PARAMS["AvailabilityZoneSuffix"]="$OVERRIDE_AZ"
[[ -n "$OVERRIDE_KEYPAIR"     ]] && PARAMS["KeyPairName"]="$OVERRIDE_KEYPAIR"
[[ -n "$OVERRIDE_PANEL_PORT"  ]] && PARAMS["PanelPort"]="$OVERRIDE_PANEL_PORT"
[[ -n "$OVERRIDE_PROXY_PORT"  ]] && PARAMS["ProxyPort"]="$OVERRIDE_PROXY_PORT"
[[ -n "$OVERRIDE_SS_PORT"     ]] && PARAMS["SSBackupPort"]="$OVERRIDE_SS_PORT"

# 3. Build --parameter-overrides string: "Key1=Val1 Key2=Val2 ..."
PARAM_PAIRS=()
for k in "${!PARAMS[@]}"; do
    PARAM_PAIRS+=("${k}=${PARAMS[$k]}")
done

# Show what will be used / 展示最终参数
log_info "Effective parameters / 最终参数:"
for pair in "${PARAM_PAIRS[@]}"; do
    echo "    $pair"
done
echo ""

# ------------------------------------------------------------
# 1. Validate template
# ------------------------------------------------------------
log_step "[1/4] Validating template / 校验模板..."
aws cloudformation validate-template \
    --template-body "file://${TEMPLATE_FILE}" \
    --region "$REGION" >/dev/null

# ------------------------------------------------------------
# 2. Detect create vs update
# ------------------------------------------------------------
if aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" >/dev/null 2>&1; then
    log_info "Stack exists → UPDATE / 栈已存在，将执行更新"
else
    log_info "Stack does not exist → CREATE / 栈不存在，将新建"
fi

# ------------------------------------------------------------
# 3. Confirm
# ------------------------------------------------------------
if [[ "$AUTO_APPROVE" != true ]]; then
    echo ""
    read -r -p "Proceed with deployment? / 确认部署? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_warn "Deployment cancelled. / 部署已取消"
        exit 0
    fi
fi

# ------------------------------------------------------------
# 4. Deploy
# ------------------------------------------------------------
log_step "[2/4] Deploying stack / 部署栈..."
aws cloudformation deploy \
    --template-file "$TEMPLATE_FILE" \
    --stack-name "$STACK_NAME" \
    --parameter-overrides "${PARAM_PAIRS[@]}" \
    --region "$REGION" \
    --no-fail-on-empty-changeset

log_step "[3/4] Fetching outputs / 获取输出..."
OUTPUTS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs' \
    --output json)

STATIC_IP=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="StaticIpAddress") | .OutputValue')
PANEL_URL=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="PanelURL") | .OutputValue')
SSH_CMD=$(echo "$OUTPUTS"   | jq -r '.[] | select(.OutputKey=="SSHCommand")     | .OutputValue')

log_step "[4/4] Done / 完成!"

cat <<EOF

${GREEN}============================================${NC}
${GREEN}Deployment complete! / 部署完成!${NC}
${GREEN}============================================${NC}

  Static IP:  ${YELLOW}${STATIC_IP}${NC}
  Panel URL:  ${YELLOW}${PANEL_URL}${NC}
  SSH:        ${SSH_CMD}

${YELLOW}Next steps / 下一步:${NC}

  1. Upload scripts / 上传脚本:
     scp -i <your-key.pem> -r ../../scripts ubuntu@${STATIC_IP}:/tmp/
     ssh -i <your-key.pem> ubuntu@${STATIC_IP} \\
       'sudo mkdir -p /opt/scripts && sudo mv /tmp/scripts/* /opt/scripts/ && sudo chmod +x /opt/scripts/*.sh'

  2. SSH & run setup / SSH 登录并运行配置:
     ssh -i <your-key.pem> ubuntu@${STATIC_IP}
     sudo bash /opt/scripts/setup.sh

  3. Access panel / 访问面板:
     ${PANEL_URL}

  ${YELLOW}⚠️  Corporate VPN blocks non-standard ports — use mobile for panel${NC}
  ${YELLOW}⚠️  公司 VPN 拦非标端口，面板请用手机流量访问${NC}

EOF

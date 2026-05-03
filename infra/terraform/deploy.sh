#!/bin/bash
# ============================================================
# Lightsail Proxy - Terraform 一键部署脚本 / one-click deploy
# ============================================================
# Usage / 用法:
#   ./deploy.sh [env] [OPTIONS]
#
# Presets / 预设环境 (optional / 可选):
#   tokyo | singapore | frankfurt | custom
#   Default: tokyo / 默认 tokyo
#
# Options / 选项:
#   --region REGION         AWS region (e.g. ap-south-1)
#                           覆盖区域，如 ap-south-1
#   --bundle BUNDLE_ID      Lightsail bundle (e.g. micro_3_0)
#                           覆盖套餐，如 micro_3_0
#   --name NAME             Instance name / 实例名称
#   --az SUFFIX             Availability zone suffix (a/b/c/d)
#                           可用区后缀 (a/b/c/d)
#   --key-pair NAME         SSH key pair name / SSH 密钥对名称
#   --panel-port N          3x-ui panel port (default: 18918)
#                           面板端口
#   --proxy-port N          Main proxy port (default: 443)
#                           代理主端口
#   --ss-port N             Shadowsocks port (default: 8388)
#                           SS 备用端口
#   --auto-approve          Skip confirmation prompt
#                           跳过确认提示
#   -h, --help              Show this help / 显示帮助
#
# Precedence (high → low) / 参数优先级（高 → 低）:
#   1. CLI flags / 命令行参数
#   2. terraform.tfvars (user file / 用户文件)
#   3. envs/<env>.tfvars (preset / 预设)
#   4. variables.tf defaults / 默认值
#
# Examples / 示例:
#   ./deploy.sh tokyo
#   ./deploy.sh tokyo --bundle micro_3_0
#   ./deploy.sh custom --region ap-south-1 --bundle small_3_0 --name my-proxy
#   ./deploy.sh tokyo --proxy-port 8443 --auto-approve
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------
# Colors / 颜色
# ------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

usage() {
    # Print header comment block as help
    sed -n '/^# Usage/,/^# ===/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

# ------------------------------------------------------------
# Known "safe" regions — used to warn, not to block
# 已知"安全"区域清单 —— 用于警告，不用于阻止
# ------------------------------------------------------------
RECOMMENDED_REGIONS=(
    ap-northeast-1 ap-northeast-2 ap-southeast-1 ap-southeast-2
    ap-south-1 eu-central-1 eu-west-1 eu-west-2 eu-west-3
    eu-north-1 sa-east-1 ca-central-1
)
US_REGIONS=(us-east-1 us-east-2 us-west-1 us-west-2)

is_in_list() {
    local needle="$1"; shift
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------
# Parse args / 解析参数
# ------------------------------------------------------------
ENV="tokyo"
OVERRIDE_REGION=""
OVERRIDE_BUNDLE=""
OVERRIDE_NAME=""
OVERRIDE_AZ=""
OVERRIDE_KEYPAIR=""
OVERRIDE_PANEL_PORT=""
OVERRIDE_PROXY_PORT=""
OVERRIDE_SS_PORT=""
AUTO_APPROVE=false

# First positional arg (if not a flag) is env
if [[ $# -gt 0 && "$1" != -* ]]; then
    ENV="$1"
    shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)       OVERRIDE_REGION="$2";      shift 2 ;;
        --bundle)       OVERRIDE_BUNDLE="$2";      shift 2 ;;
        --name)         OVERRIDE_NAME="$2";        shift 2 ;;
        --az)           OVERRIDE_AZ="$2";          shift 2 ;;
        --key-pair)     OVERRIDE_KEYPAIR="$2";     shift 2 ;;
        --panel-port)   OVERRIDE_PANEL_PORT="$2";  shift 2 ;;
        --proxy-port)   OVERRIDE_PROXY_PORT="$2";  shift 2 ;;
        --ss-port)      OVERRIDE_SS_PORT="$2";     shift 2 ;;
        --auto-approve) AUTO_APPROVE=true;         shift ;;
        -h|--help)      usage ;;
        *) log_error "Unknown option: $1 (use -h for help)"; exit 1 ;;
    esac
done

# ------------------------------------------------------------
# Resolve env → tfvars file
# ------------------------------------------------------------
TFVARS_ARG=""
if [[ "$ENV" == "custom" ]]; then
    log_info "Using 'custom' env — no preset tfvars applied"
    log_info "使用 custom 环境 —— 不加载任何预设 tfvars"
else
    TFVARS_FILE="${SCRIPT_DIR}/envs/${ENV}.tfvars"
    if [[ ! -f "$TFVARS_FILE" ]]; then
        log_error "Environment file not found: $TFVARS_FILE"
        log_error "Available: tokyo | singapore | frankfurt | custom"
        exit 1
    fi
    TFVARS_ARG="-var-file=${TFVARS_FILE}"
fi

echo -e "${GREEN}=== Lightsail Proxy Terraform Deploy ===${NC}"
echo "  Environment: ${YELLOW}${ENV}${NC}"
echo ""

# ------------------------------------------------------------
# Pre-flight / 前置检查
# ------------------------------------------------------------
log_step "Running pre-flight checks / 前置检查..."

command -v terraform >/dev/null 2>&1 || {
    log_error "terraform not installed / Terraform 未安装"
    echo "  Install: https://developer.hashicorp.com/terraform/install"
    exit 1
}

command -v aws >/dev/null 2>&1 || {
    log_error "aws cli not installed / AWS CLI 未安装"
    exit 1
}

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS CLI not configured / AWS CLI 未配置"
    echo "  Run: aws configure"
    exit 1
fi

log_info "AWS identity: $(aws sts get-caller-identity --query Arn --output text)"

# ------------------------------------------------------------
# Warn on risky regions / 对高风险区域给出警告
# ------------------------------------------------------------
if [[ -n "$OVERRIDE_REGION" ]]; then
    if is_in_list "$OVERRIDE_REGION" "${US_REGIONS[@]}"; then
        log_warn "⚠️  US region detected: $OVERRIDE_REGION"
        log_warn "⚠️  检测到美国区域: $OVERRIDE_REGION"
        log_warn "US IPs are often flagged by Netflix, ChatGPT, banks, etc."
        log_warn "美国 IP 段常被流媒体 / 金融等服务风控"
    elif ! is_in_list "$OVERRIDE_REGION" "${RECOMMENDED_REGIONS[@]}"; then
        log_warn "Region '$OVERRIDE_REGION' is not in the tested list"
        log_warn "区域 '$OVERRIDE_REGION' 不在已测试列表内，请确认 Lightsail 支持该区域"
    fi
fi

# ------------------------------------------------------------
# Build -var overrides / 构建命令行覆盖参数
# ------------------------------------------------------------
VAR_OVERRIDES=()
[[ -n "$OVERRIDE_REGION"      ]] && VAR_OVERRIDES+=(-var="aws_region=$OVERRIDE_REGION")
[[ -n "$OVERRIDE_BUNDLE"      ]] && VAR_OVERRIDES+=(-var="bundle_id=$OVERRIDE_BUNDLE")
[[ -n "$OVERRIDE_NAME"        ]] && VAR_OVERRIDES+=(-var="instance_name=$OVERRIDE_NAME")
[[ -n "$OVERRIDE_AZ"          ]] && VAR_OVERRIDES+=(-var="availability_zone=$OVERRIDE_AZ")
[[ -n "$OVERRIDE_KEYPAIR"     ]] && VAR_OVERRIDES+=(-var="key_pair_name=$OVERRIDE_KEYPAIR")
[[ -n "$OVERRIDE_PANEL_PORT"  ]] && VAR_OVERRIDES+=(-var="panel_port=$OVERRIDE_PANEL_PORT")
[[ -n "$OVERRIDE_PROXY_PORT"  ]] && VAR_OVERRIDES+=(-var="proxy_port=$OVERRIDE_PROXY_PORT")
[[ -n "$OVERRIDE_SS_PORT"     ]] && VAR_OVERRIDES+=(-var="ss_backup_port=$OVERRIDE_SS_PORT")

# ------------------------------------------------------------
# User overrides / 用户自定义覆盖
# ------------------------------------------------------------
USER_VARS_ARG=""
if [[ -f "${SCRIPT_DIR}/terraform.tfvars" ]]; then
    USER_VARS_ARG="-var-file=${SCRIPT_DIR}/terraform.tfvars"
    log_info "Using user overrides / 使用用户自定义: terraform.tfvars"
fi

cd "$SCRIPT_DIR"

# ------------------------------------------------------------
# 1. Init
# ------------------------------------------------------------
log_step "[1/4] terraform init..."
terraform init -upgrade

# ------------------------------------------------------------
# 2. Validate & format check
# ------------------------------------------------------------
log_step "[2/4] terraform fmt / validate..."
terraform fmt -check=true -recursive >/dev/null 2>&1 || {
    log_warn "Formatting issues detected. Running terraform fmt..."
    terraform fmt -recursive
}
terraform validate

# ------------------------------------------------------------
# 3. Plan
# ------------------------------------------------------------
log_step "[3/4] terraform plan..."
# shellcheck disable=SC2086
terraform plan \
    $TFVARS_ARG \
    $USER_VARS_ARG \
    "${VAR_OVERRIDES[@]}" \
    -out=tfplan

# ------------------------------------------------------------
# Confirm
# ------------------------------------------------------------
if [[ "$AUTO_APPROVE" != true ]]; then
    echo ""
    read -r -p "Proceed with deployment? / 确认部署? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_warn "Deployment cancelled. / 部署已取消"
        rm -f tfplan
        exit 0
    fi
fi

# ------------------------------------------------------------
# 4. Apply
# ------------------------------------------------------------
log_step "[4/4] terraform apply..."
terraform apply tfplan
rm -f tfplan

# ------------------------------------------------------------
# Output
# ------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}Deployment complete! / 部署完成!${NC}"
echo -e "${GREEN}============================================${NC}"
terraform output

STATIC_IP=$(terraform output -raw static_ip)
PANEL_PORT=$(terraform output -raw panel_port)

cat <<EOF

${YELLOW}Next steps / 下一步:${NC}

  1. Upload scripts / 上传脚本:
     scp -i <your-key.pem> -r ../../scripts ubuntu@${STATIC_IP}:/tmp/
     ssh -i <your-key.pem> ubuntu@${STATIC_IP} \\
       'sudo mkdir -p /opt/scripts && sudo mv /tmp/scripts/* /opt/scripts/ && sudo chmod +x /opt/scripts/*.sh'

  2. SSH and run setup / SSH 登录并运行配置:
     ssh -i <your-key.pem> ubuntu@${STATIC_IP}
     sudo bash /opt/scripts/setup.sh

  3. Access panel / 访问面板:
     http://${STATIC_IP}:${PANEL_PORT}/

  ${YELLOW}⚠️  Corporate VPN blocks non-standard ports — use mobile (cellular) for panel${NC}
  ${YELLOW}⚠️  公司 VPN 会拦非标端口，面板请用手机流量访问${NC}

EOF

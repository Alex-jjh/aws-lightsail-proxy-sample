#!/bin/bash
# ============================================================
# Lightsail Proxy - Terraform 一键部署脚本
# Usage: ./deploy.sh [env]
#   env: tokyo | singapore | frankfurt (default: tokyo)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV="${1:-tokyo}"
TFVARS_FILE="${SCRIPT_DIR}/envs/${ENV}.tfvars"

# ------------------------------------------------------------
# Color output
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

echo -e "${GREEN}=== Lightsail Proxy Terraform Deploy ===${NC}"
echo -e "Environment: ${YELLOW}${ENV}${NC}"
echo ""

# ------------------------------------------------------------
# Pre-flight checks / 前置检查
# ------------------------------------------------------------
log_step "Running pre-flight checks..."

command -v terraform >/dev/null 2>&1 || {
    log_error "terraform not installed / Terraform 未安装"
    echo "  Install: https://developer.hashicorp.com/terraform/install"
    exit 1
}

command -v aws >/dev/null 2>&1 || {
    log_error "aws cli not installed / AWS CLI 未安装"
    echo "  Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
}

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS CLI not configured / AWS CLI 未配置"
    echo "  Run: aws configure"
    exit 1
fi

if [ ! -f "$TFVARS_FILE" ]; then
    log_error "Environment file not found: $TFVARS_FILE"
    echo "  Available environments: tokyo, singapore, frankfurt"
    exit 1
fi

log_info "AWS identity: $(aws sts get-caller-identity --query Arn --output text)"

# Check for user overrides
USER_VARS=""
if [ -f "${SCRIPT_DIR}/terraform.tfvars" ]; then
    USER_VARS="-var-file=${SCRIPT_DIR}/terraform.tfvars"
    log_info "Using user overrides: terraform.tfvars"
fi

cd "$SCRIPT_DIR"

# ------------------------------------------------------------
# 1. Initialize
# ------------------------------------------------------------
log_step "[1/4] Initializing Terraform..."
terraform init -upgrade

# ------------------------------------------------------------
# 2. Validate & format check
# ------------------------------------------------------------
log_step "[2/4] Validating configuration..."
terraform fmt -check=true -recursive || {
    log_warn "Formatting issues detected. Running terraform fmt..."
    terraform fmt -recursive
}
terraform validate

# ------------------------------------------------------------
# 3. Plan
# ------------------------------------------------------------
log_step "[3/4] Planning deployment..."
# shellcheck disable=SC2086
terraform plan \
    -var-file="$TFVARS_FILE" \
    $USER_VARS \
    -out=tfplan

# ------------------------------------------------------------
# Confirm
# ------------------------------------------------------------
echo ""
read -r -p "Proceed with deployment? / 确认部署? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log_warn "Deployment cancelled. / 部署已取消"
    rm -f tfplan
    exit 0
fi

# ------------------------------------------------------------
# 4. Apply
# ------------------------------------------------------------
log_step "[4/4] Applying..."
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

# ------------------------------------------------------------
# Post-deploy instructions
# ------------------------------------------------------------
STATIC_IP=$(terraform output -raw static_ip)
PANEL_PORT=$(terraform output -raw panel_port)

cat <<EOF

${YELLOW}Next steps / 下一步操作:${NC}

  1. Upload scripts to the instance / 上传脚本到实例:
     scp -i <your-key.pem> -r ../../scripts ubuntu@${STATIC_IP}:/tmp/
     ssh -i <your-key.pem> ubuntu@${STATIC_IP} \\
       'sudo mkdir -p /opt/scripts && sudo mv /tmp/scripts/* /opt/scripts/ && sudo chmod +x /opt/scripts/*.sh'

  2. SSH and run setup / SSH 登录并运行配置脚本:
     ssh -i <your-key.pem> ubuntu@${STATIC_IP}
     sudo bash /opt/scripts/setup.sh

  3. Access panel / 访问面板 (URL + 凭证会在 setup.sh 输出末尾显示):
     http://${STATIC_IP}:${PANEL_PORT}/

  ${YELLOW}⚠️  If on corporate VPN, use mobile (cellular) to access the panel${NC}
  ${YELLOW}    公司 VPN 会拦截端口 ${PANEL_PORT}，请用手机流量访问${NC}

EOF

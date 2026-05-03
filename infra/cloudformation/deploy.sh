#!/bin/bash
# ============================================================
# Lightsail Proxy - CloudFormation 一键部署脚本
# Usage: ./deploy.sh [env] [stack-name]
#   env:        tokyo | singapore | frankfurt (default: tokyo)
#   stack-name: CloudFormation stack name (default: lightsail-proxy-<env>)
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV="${1:-tokyo}"
STACK_NAME="${2:-lightsail-proxy-${ENV}}"

TEMPLATE_FILE="${SCRIPT_DIR}/template.yaml"
PARAMS_FILE="${SCRIPT_DIR}/parameters/${ENV}.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

# ------------------------------------------------------------
# Region mapping / 环境到 AWS Region 的映射
# ------------------------------------------------------------
case "$ENV" in
    tokyo)     REGION="ap-northeast-1" ;;
    singapore) REGION="ap-southeast-1" ;;
    frankfurt) REGION="eu-central-1"  ;;
    *)
        log_error "Unknown environment: $ENV"
        echo "  Available: tokyo | singapore | frankfurt"
        exit 1
        ;;
esac

echo -e "${GREEN}=== Lightsail Proxy CloudFormation Deploy ===${NC}"
echo "  Environment: ${YELLOW}${ENV}${NC}"
echo "  Region:      ${YELLOW}${REGION}${NC}"
echo "  Stack:       ${YELLOW}${STACK_NAME}${NC}"
echo ""

# ------------------------------------------------------------
# Pre-flight checks
# ------------------------------------------------------------
log_step "Running pre-flight checks..."

command -v aws >/dev/null 2>&1 || {
    log_error "aws cli not installed / AWS CLI 未安装"
    exit 1
}

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    log_error "AWS CLI not configured / AWS CLI 未配置"
    echo "  Run: aws configure"
    exit 1
fi

[ -f "$TEMPLATE_FILE" ] || { log_error "Template not found: $TEMPLATE_FILE"; exit 1; }
[ -f "$PARAMS_FILE" ]   || { log_error "Params not found: $PARAMS_FILE";   exit 1; }

log_info "AWS identity: $(aws sts get-caller-identity --query Arn --output text)"

# ------------------------------------------------------------
# 1. Validate template
# ------------------------------------------------------------
log_step "[1/4] Validating template..."
aws cloudformation validate-template \
    --template-body "file://${TEMPLATE_FILE}" \
    --region "$REGION" >/dev/null

# ------------------------------------------------------------
# 2. Check if stack exists
# ------------------------------------------------------------
STACK_EXISTS=false
if aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" >/dev/null 2>&1; then
    STACK_EXISTS=true
    log_info "Stack exists. Will perform UPDATE."
else
    log_info "Stack does not exist. Will perform CREATE."
fi

# ------------------------------------------------------------
# 3. Confirm
# ------------------------------------------------------------
echo ""
read -r -p "Proceed with deployment? / 确认部署? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log_warn "Deployment cancelled. / 部署已取消"
    exit 0
fi

# ------------------------------------------------------------
# 4. Deploy
# ------------------------------------------------------------
log_step "[2/4] Deploying stack..."
aws cloudformation deploy \
    --template-file "$TEMPLATE_FILE" \
    --stack-name "$STACK_NAME" \
    --parameter-overrides "file://${PARAMS_FILE}" \
    --region "$REGION" \
    --no-fail-on-empty-changeset

log_step "[3/4] Fetching outputs..."
OUTPUTS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs' \
    --output json)

STATIC_IP=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="StaticIpAddress") | .OutputValue')
PANEL_URL=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="PanelURL") | .OutputValue')
SSH_CMD=$(echo "$OUTPUTS"   | jq -r '.[] | select(.OutputKey=="SSHCommand") | .OutputValue')

log_step "[4/4] Done!"

cat <<EOF

${GREEN}============================================${NC}
${GREEN}Deployment complete! / 部署完成!${NC}
${GREEN}============================================${NC}

  Static IP:  ${YELLOW}${STATIC_IP}${NC}
  Panel URL:  ${YELLOW}${PANEL_URL}${NC}
  SSH:        ${SSH_CMD}

${YELLOW}Next steps / 下一步:${NC}

  1. Upload scripts / 上传脚本到实例:
     scp -i <your-key.pem> -r ../../scripts ubuntu@${STATIC_IP}:/tmp/
     ssh -i <your-key.pem> ubuntu@${STATIC_IP} \\
       'sudo mkdir -p /opt/scripts && sudo mv /tmp/scripts/* /opt/scripts/ && sudo chmod +x /opt/scripts/*.sh'

  2. SSH & run setup / SSH 登录并运行配置脚本:
     ssh -i <your-key.pem> ubuntu@${STATIC_IP}
     sudo bash /opt/scripts/setup.sh

  3. Access panel / 访问面板:
     ${PANEL_URL}

  ${YELLOW}⚠️  If on corporate VPN, use mobile (cellular) to access the panel${NC}

EOF

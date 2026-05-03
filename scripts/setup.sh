#!/bin/bash
# ============================================================
# 3x-ui Proxy Setup - 主配置脚本
# ============================================================
# 作用：在 Lightsail 实例上一键完成所有配置
#   1. 安装 3x-ui
#   2. 配置 SSL
#   3. 安全加固（改账号密码 / 面板路径）
#   4. 添加代理协议（VLESS Reality + Shadowsocks）
#   5. 输出凭证到 /opt/proxy-credentials.json
#
# Usage:
#   sudo bash setup.sh
#   sudo bash setup.sh --panel-port 18918 --proxy-port 443 \
#                      --username admin --password 'XXX' --panel-path custom
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRED_FILE="/opt/proxy-credentials.json"
LOG_FILE="/var/log/proxy-setup.log"

# ------------------------------------------------------------
# Defaults (auto-generated if not provided)
# ------------------------------------------------------------
PANEL_PORT="${PANEL_PORT:-18918}"
PROXY_PORT="${PROXY_PORT:-443}"
SS_PORT="${SS_PORT:-8388}"
USERNAME=""
PASSWORD=""
PANEL_PATH=""

# ------------------------------------------------------------
# Color output
# ------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2; }
log_step()  { echo -e "\n${BLUE}===[ $* ]===${NC}\n" | tee -a "$LOG_FILE"; }

# ------------------------------------------------------------
# Root check / 必须 root 运行
# ------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    log_error "This script must be run as root. / 必须使用 root 运行"
    echo "  Usage: sudo bash $0"
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# ------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --panel-port)  PANEL_PORT="$2"; shift 2 ;;
        --proxy-port)  PROXY_PORT="$2"; shift 2 ;;
        --ss-port)     SS_PORT="$2"; shift 2 ;;
        --username)    USERNAME="$2"; shift 2 ;;
        --password)    PASSWORD="$2"; shift 2 ;;
        --panel-path)  PANEL_PATH="$2"; shift 2 ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | head -20
            exit 0
            ;;
        *)
            log_error "Unknown arg: $1"
            exit 1
            ;;
    esac
done

# Auto-generate secure defaults
[ -z "$USERNAME" ]   && USERNAME="admin_$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
[ -z "$PASSWORD" ]   && PASSWORD="$(tr -dc 'A-Za-z0-9!@#%^_' </dev/urandom | head -c 20)"
[ -z "$PANEL_PATH" ] && PANEL_PATH="$(tr -dc 'a-z0-9' </dev/urandom | head -c 10)"

# ------------------------------------------------------------
# Sub-script dispatcher
# ------------------------------------------------------------
run_substep() {
    local script="$1"
    shift
    local path="${SCRIPT_DIR}/${script}"
    if [ ! -f "$path" ]; then
        log_error "Missing script: $path"
        exit 1
    fi
    chmod +x "$path"
    log_info "Running ${script}..."
    "$path" "$@" 2>&1 | tee -a "$LOG_FILE"
}

# ------------------------------------------------------------
# Wait for bootstrap completion (if exists)
# ------------------------------------------------------------
if [ -f /opt/proxy-bootstrap-complete ]; then
    log_info "Bootstrap marker found / 检测到 bootstrap 标志文件"
    # shellcheck source=/dev/null
    source /opt/proxy-bootstrap-complete || true
fi

# Make sure sqlite3 is available (may be missing if no UserData ran)
if ! command -v sqlite3 >/dev/null 2>&1; then
    log_warn "sqlite3 not installed. Installing... / sqlite3 未安装，正在安装"
    apt-get update -y
    apt-get install -y sqlite3 curl jq
fi

# ------------------------------------------------------------
# Get public IP
# ------------------------------------------------------------
PUBLIC_IP=$(curl -s --max-time 10 https://api.ipify.org || \
            curl -s --max-time 10 https://ifconfig.me || \
            echo "")

if [ -z "$PUBLIC_IP" ]; then
    log_error "Cannot determine public IP / 无法获取公网 IP"
    exit 1
fi

log_info "Public IP: $PUBLIC_IP"

# ============================================================
# Step 1: Install 3x-ui
# ============================================================
log_step "Step 1/4: Install 3x-ui / 安装 3x-ui"
run_substep "install-3xui.sh" --panel-port "$PANEL_PORT"

# ============================================================
# Step 2: Configure SSL
# ============================================================
log_step "Step 2/4: Configure SSL / 配置 SSL"
run_substep "configure-ssl.sh" --ip "$PUBLIC_IP" || {
    log_warn "SSL setup had issues. Panel will run in HTTP mode."
    log_warn "SSL 配置失败，面板将以 HTTP 模式运行（功能正常）"
}

# ============================================================
# Step 3: Security hardening
# ============================================================
log_step "Step 3/4: Security hardening / 安全加固"
run_substep "security-hardening.sh" \
    --username "$USERNAME" \
    --password "$PASSWORD" \
    --panel-path "$PANEL_PATH"

# ============================================================
# Step 4: Configure proxy protocols
# ============================================================
log_step "Step 4/4: Configure protocols / 配置代理协议"
run_substep "configure-protocols.sh" \
    --proxy-port "$PROXY_PORT" \
    --ss-port "$SS_PORT" \
    --server-ip "$PUBLIC_IP"

# Reload everything
log_info "Restarting x-ui / 重启 x-ui 服务"
x-ui restart || systemctl restart x-ui || true
sleep 3

# ============================================================
# Output credentials
# ============================================================
log_step "Credentials summary / 凭证信息"

# Load extra values generated by configure-protocols.sh (if available)
VLESS_UUID=""
VLESS_PUBKEY=""
VLESS_SHORTID=""
SS_PASSWORD=""
if [ -f /opt/proxy-generated.env ]; then
    # shellcheck source=/dev/null
    source /opt/proxy-generated.env
fi

# Build credentials JSON
cat > "$CRED_FILE" <<EOF
{
  "server_ip": "${PUBLIC_IP}",
  "panel": {
    "url": "http://${PUBLIC_IP}:${PANEL_PORT}/${PANEL_PATH}/",
    "port": ${PANEL_PORT},
    "path": "${PANEL_PATH}",
    "username": "${USERNAME}",
    "password": "${PASSWORD}"
  },
  "vless_reality": {
    "port": ${PROXY_PORT},
    "uuid": "${VLESS_UUID}",
    "public_key": "${VLESS_PUBKEY}",
    "short_id": "${VLESS_SHORTID}",
    "sni": "www.microsoft.com",
    "flow": "",
    "fingerprint": "chrome"
  },
  "shadowsocks": {
    "port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "cipher": "2022-blake3-aes-256-gcm"
  },
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

chmod 600 "$CRED_FILE"

log_info "Credentials saved to: $CRED_FILE"
log_info "Run 'sudo cat $CRED_FILE | jq .' to view"

cat <<EOF

${GREEN}============================================${NC}
${GREEN}✅ Setup complete! / 配置完成!${NC}
${GREEN}============================================${NC}

${YELLOW}Panel Access / 面板访问:${NC}
  URL:      http://${PUBLIC_IP}:${PANEL_PORT}/${PANEL_PATH}/
  Username: ${USERNAME}
  Password: ${PASSWORD}

${YELLOW}VLESS Reality (Primary):${NC}
  Port: ${PROXY_PORT}
  SNI:  www.microsoft.com

${YELLOW}Shadowsocks (Backup):${NC}
  Port:   ${SS_PORT}
  Cipher: 2022-blake3-aes-256-gcm

${YELLOW}Diagnostics:${NC}
  sudo bash ${SCRIPT_DIR}/troubleshoot.sh

${YELLOW}Export client links:${NC}
  sudo bash ${SCRIPT_DIR}/../client/export-links.sh

${RED}⚠️  IMPORTANT / 重要提示:${NC}
  - Save the panel URL above. The random path is your first line of defense.
  - 面板路径（${PANEL_PATH}）是防护第一道，请保存好
  - If on corporate VPN, use mobile (cellular) for panel access
  - 公司 VPN 会拦非标端口，请用手机流量访问面板

EOF

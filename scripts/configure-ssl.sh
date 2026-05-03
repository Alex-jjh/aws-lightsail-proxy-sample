#!/bin/bash
# ============================================================
# Configure SSL for 3x-ui panel
# 配置 SSL 证书（Let's Encrypt via acme.sh）
# ============================================================
# 已知问题：
#   1. acme.sh 在 sudo 下运行时路径不一致，证书申请后 3x-ui 脚本报
#      "cert not found"，但 /root/.acme.sh/<IP>_ecc/ 里其实已有文件
#   2. Let's Encrypt 要求 80 端口可用（HTTP-01 挑战）
#
# 本脚本策略：
#   1. 尝试用 acme.sh 申请纯 IP 证书（ZeroSSL）
#   2. 成功：直接写入 sqlite3 配置
#   3. 失败：回退到 HTTP 模式（代理功能不受影响）
# ============================================================
set -euo pipefail

SERVER_IP=""
DB_FILE="/etc/x-ui/x-ui.db"
ACME_HOME="/root/.acme.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip) SERVER_IP="$2"; shift 2 ;;
        *) echo "[ERROR] Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$SERVER_IP" ]; then
    echo "[ERROR] --ip required" >&2
    exit 1
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[ssl]${NC}  $*"; }
warn() { echo -e "${YELLOW}[ssl]${NC}  $*"; }
err()  { echo -e "${RED}[ssl]${NC}  $*" >&2; }

# ------------------------------------------------------------
# Fallback: disable TLS in x-ui settings
# SSL 失败时回退到 HTTP 模式（代理流量自己会 TLS 加密，面板 HTTP 可接受）
# ------------------------------------------------------------
disable_tls() {
    warn "Falling back to HTTP mode / 回退到 HTTP 模式"
    if [ -f "$DB_FILE" ]; then
        sqlite3 "$DB_FILE" <<SQL
UPDATE settings SET value='' WHERE key='webCertFile';
UPDATE settings SET value='' WHERE key='webKeyFile';
SQL
        systemctl restart x-ui || x-ui restart || true
    fi
}

# ------------------------------------------------------------
# Install acme.sh if missing
# ------------------------------------------------------------
if [ ! -f "${ACME_HOME}/acme.sh" ]; then
    log "Installing acme.sh... / 安装 acme.sh"
    curl -Ls https://get.acme.sh -o /tmp/acme-install.sh
    bash /tmp/acme-install.sh --home "$ACME_HOME" --accountemail "noreply@example.com" || {
        warn "acme.sh install failed"
        disable_tls
        exit 0
    }
fi

# ------------------------------------------------------------
# Set default CA to ZeroSSL (supports pure IP certificates)
# Let's Encrypt does NOT issue IP certs. ZeroSSL does.
# ------------------------------------------------------------
"${ACME_HOME}/acme.sh" --set-default-ca --server zerossl >/dev/null 2>&1 || true

# Register account (idempotent)
"${ACME_HOME}/acme.sh" --register-account -m "noreply@example.com" >/dev/null 2>&1 || true

# ------------------------------------------------------------
# Stop any service on port 80 (needed for standalone mode)
# ------------------------------------------------------------
log "Freeing port 80 for ACME challenge..."
systemctl stop nginx 2>/dev/null || true
systemctl stop apache2 2>/dev/null || true
# Give kernel a moment
sleep 1

# ------------------------------------------------------------
# Attempt certificate issuance
# ------------------------------------------------------------
log "Requesting certificate for IP: ${SERVER_IP}"
CERT_DIR="${ACME_HOME}/${SERVER_IP}_ecc"
ISSUE_OK=false

if "${ACME_HOME}/acme.sh" --issue \
    --standalone \
    -d "$SERVER_IP" \
    --keylength ec-256 \
    --home "$ACME_HOME" \
    --force 2>&1 | tee /tmp/acme-issue.log; then
    ISSUE_OK=true
fi

# ------------------------------------------------------------
# KNOWN ISSUE: acme.sh sometimes reports failure but cert files exist.
# Check for files directly rather than trusting exit code.
# 已知问题：acme.sh 有时报错但证书文件实际已生成，直接检查文件更可靠
# ------------------------------------------------------------
if [ -f "${CERT_DIR}/fullchain.cer" ] && [ -f "${CERT_DIR}/${SERVER_IP}.key" ]; then
    log "Cert files found at ${CERT_DIR}"

    CERT_PATH="${CERT_DIR}/fullchain.cer"
    KEY_PATH="${CERT_DIR}/${SERVER_IP}.key"

    # Ensure x-ui can read them
    chmod 644 "$CERT_PATH" "$KEY_PATH" || true

    # Write into x-ui DB
    if [ -f "$DB_FILE" ]; then
        sqlite3 "$DB_FILE" <<SQL
UPDATE settings SET value='${CERT_PATH}' WHERE key='webCertFile';
UPDATE settings SET value='${KEY_PATH}' WHERE key='webKeyFile';
SQL
        log "Cert paths written to x-ui database / 证书路径已写入 x-ui 数据库"
    else
        warn "x-ui.db not found; cert paths not configured"
    fi

    # Setup renewal cron (acme.sh installs by default but force re-add)
    (crontab -l 2>/dev/null | grep -v acme.sh; \
     echo "0 3 * * * ${ACME_HOME}/acme.sh --cron --home ${ACME_HOME} > /dev/null") | crontab -

    systemctl restart x-ui || x-ui restart || true
    log "SSL configured ✅"
else
    err "Cert files not generated / 证书文件未生成"
    if [ "$ISSUE_OK" = false ]; then
        warn "acme.sh issuance failed. Check /tmp/acme-issue.log"
    fi
    disable_tls
fi

exit 0

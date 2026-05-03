#!/bin/bash
# ============================================================
# Security hardening for 3x-ui
# 安全加固：改账号密码 + 随机面板路径 + 自动更新
# ============================================================
set -euo pipefail

USERNAME=""
PASSWORD=""
PANEL_PATH=""
DB_FILE="/etc/x-ui/x-ui.db"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --username)   USERNAME="$2"; shift 2 ;;
        --password)   PASSWORD="$2"; shift 2 ;;
        --panel-path) PANEL_PATH="$2"; shift 2 ;;
        *) echo "[ERROR] Unknown arg: $1" >&2; exit 1 ;;
    esac
done

for v in USERNAME PASSWORD PANEL_PATH; do
    [ -z "${!v}" ] && { echo "[ERROR] --${v,,} required" >&2; exit 1; }
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[harden]${NC}  $*"; }
warn() { echo -e "${YELLOW}[harden]${NC}  $*"; }

# ------------------------------------------------------------
# 1. Update panel credentials via sqlite3
# 3x-ui stores the password as a raw string (not hashed) in settings.
# ------------------------------------------------------------
if [ ! -f "$DB_FILE" ]; then
    echo "[ERROR] x-ui.db not found at $DB_FILE" >&2
    exit 1
fi

log "Updating panel username / 更新面板用户名"
sqlite3 "$DB_FILE" <<SQL
UPDATE users SET username='${USERNAME}' WHERE id=1;
UPDATE users SET password='${PASSWORD}' WHERE id=1;
SQL

log "Setting random panel path: /${PANEL_PATH}/ / 随机面板路径"
sqlite3 "$DB_FILE" <<SQL
UPDATE settings SET value='/${PANEL_PATH}/' WHERE key='webBasePath';
SQL

# ------------------------------------------------------------
# 2. fail2ban (optional — enabled by default)
# ------------------------------------------------------------
if ! dpkg -l | grep -q "^ii  fail2ban"; then
    log "Installing fail2ban / 安装 fail2ban"
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban || warn "fail2ban install failed"
fi

if command -v fail2ban-client >/dev/null 2>&1; then
    cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port    = ssh
maxretry = 5
findtime = 600
bantime  = 3600
EOF
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban || true
fi

# ------------------------------------------------------------
# 3. Unattended security upgrades
# ------------------------------------------------------------
if ! dpkg -l | grep -q "^ii  unattended-upgrades"; then
    log "Enabling automatic security updates / 启用自动安全更新"
    DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades || warn "failed"
    dpkg-reconfigure -f noninteractive unattended-upgrades || true
fi

# ------------------------------------------------------------
# 4. Restart x-ui so settings take effect
# ------------------------------------------------------------
systemctl restart x-ui || x-ui restart || true
sleep 2

log "Hardening complete ✅"
exit 0

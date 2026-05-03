#!/bin/bash
# ============================================================
# Install 3x-ui (non-interactive)
# 安装 3x-ui 管理面板
# ============================================================
# CRITICAL: 不能用 `sudo bash <(curl ...)`
#   错误: /dev/fd/63: No such file or directory
#   原因: sudo 切换用户上下文，丢失父 shell 的 fd
#   修复: 先下载脚本到本地再执行
# ============================================================
set -euo pipefail

PANEL_PORT="18918"
INSTALL_SCRIPT="/tmp/install-3xui.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --panel-port) PANEL_PORT="$2"; shift 2 ;;
        *) echo "[ERROR] Unknown arg: $1" >&2; exit 1 ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${GREEN}[install-3xui]${NC} $*"; }
warn() { echo -e "${YELLOW}[install-3xui]${NC} $*"; }

# ------------------------------------------------------------
# Idempotency: skip if already installed
# ------------------------------------------------------------
if command -v x-ui >/dev/null 2>&1 && systemctl list-units --type=service | grep -q x-ui; then
    log "3x-ui already installed / 3x-ui 已安装，跳过"
    x-ui status || true
    # Still make sure panel port is set
    if [ -f /etc/x-ui/x-ui.db ]; then
        sqlite3 /etc/x-ui/x-ui.db \
            "UPDATE settings SET value='${PANEL_PORT}' WHERE key='webPort';" || true
        x-ui restart || systemctl restart x-ui || true
    fi
    exit 0
fi

# ------------------------------------------------------------
# Download install script (if not already)
# ⚠️ DO NOT use process substitution under sudo
# ------------------------------------------------------------
if [ ! -f "$INSTALL_SCRIPT" ]; then
    log "Downloading 3x-ui install script... / 下载安装脚本"
    curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh \
        -o "$INSTALL_SCRIPT"
    chmod +x "$INSTALL_SCRIPT"
fi

# ------------------------------------------------------------
# Run installer non-interactively
# 3x-ui 官方 install.sh 在 stdin 非交互时会使用默认值（跳过面板设置）
# 我们之后通过 sqlite3 手动配置，避免 install.sh 的交互卡住
# ------------------------------------------------------------
log "Running 3x-ui installer... / 运行安装脚本"

# Pipe 'n' to any y/n prompts that might appear, and redirect stdin from /dev/null
# to force non-interactive mode.
bash "$INSTALL_SCRIPT" </dev/null || {
    warn "Installer exited non-zero, but service may still be installed"
}

# ------------------------------------------------------------
# Verify installation
# ------------------------------------------------------------
if ! command -v x-ui >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} 3x-ui not installed / 3x-ui 安装失败" >&2
    exit 1
fi

# ------------------------------------------------------------
# Configure panel port via sqlite3 (robust, avoids interactive prompts)
# ------------------------------------------------------------
log "Configuring panel port: ${PANEL_PORT} / 配置面板端口"

# Wait briefly for DB to exist
for _ in {1..10}; do
    [ -f /etc/x-ui/x-ui.db ] && break
    sleep 1
done

if [ ! -f /etc/x-ui/x-ui.db ]; then
    warn "x-ui.db not found yet. Starting x-ui to initialize..."
    systemctl start x-ui || true
    sleep 3
fi

if [ -f /etc/x-ui/x-ui.db ]; then
    sqlite3 /etc/x-ui/x-ui.db <<SQL
UPDATE settings SET value='${PANEL_PORT}' WHERE key='webPort';
SQL
    log "Panel port set to ${PANEL_PORT}"
else
    warn "x-ui.db still not found. Panel port not updated."
fi

# Restart to apply
systemctl restart x-ui || x-ui restart || true
sleep 3

# ------------------------------------------------------------
# Final status check
# ------------------------------------------------------------
log "Installation complete / 安装完成"
x-ui status || true

exit 0

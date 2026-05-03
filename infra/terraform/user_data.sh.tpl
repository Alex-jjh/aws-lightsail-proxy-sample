#!/bin/bash
# ============================================================
# Lightsail Instance Bootstrap Script
# 系统初始化脚本（由 Terraform 通过 templatefile 注入）
# ============================================================
# 这个脚本在实例首次启动时运行一次，作用：
#   1. 更新系统
#   2. 安装必要工具（sqlite3 / curl / jq / git）
#   3. 下载 3x-ui 安装脚本到 /tmp（不直接执行，留给 setup.sh）
#   4. 创建 marker 文件标识 bootstrap 已完成
# ============================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/proxy-bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO] Bootstrap started"

# ------------------------------------------------------------
# 1. System update
# ------------------------------------------------------------
echo "[INFO] Updating system packages... / 更新系统包"
apt-get update -y
apt-get upgrade -y

# ------------------------------------------------------------
# 2. Install required utilities
# ------------------------------------------------------------
echo "[INFO] Installing utilities... / 安装依赖工具"
apt-get install -y \
    sqlite3 \
    curl \
    jq \
    git \
    ca-certificates \
    ufw

# ------------------------------------------------------------
# 3. Download 3x-ui install script
# ⚠️ CRITICAL: DO NOT use `sudo bash <(curl ...)` — fails with:
#    /dev/fd/63: No such file or directory
# Root cause: sudo switches user context, losing parent shell's fd
# Fix: Download first, then execute.
# ------------------------------------------------------------
echo "[INFO] Downloading 3x-ui install script... / 下载 3x-ui 安装脚本"
curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/install-3xui.sh
chmod +x /tmp/install-3xui.sh

# ------------------------------------------------------------
# 4. Prepare scripts directory
# ------------------------------------------------------------
mkdir -p /opt/scripts
mkdir -p /opt/client

# ------------------------------------------------------------
# 5. Marker file — 让后续 setup.sh 知道 bootstrap 已完成
# ------------------------------------------------------------
cat > /opt/proxy-bootstrap-complete <<EOF
PANEL_PORT=${panel_port}
BOOTSTRAP_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BOOTSTRAP_VERSION=1.0
EOF

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO] Bootstrap complete"
echo "[INFO] Next step: upload scripts/ to /opt/scripts/ and run setup.sh"

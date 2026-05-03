#!/bin/bash
# ============================================================
# 3x-ui Proxy Diagnostic Tool
# 3x-ui 代理一键排障工具
# ============================================================
# 快速检查服务状态、端口、防火墙、日志
# 出问题时先跑这个
# ============================================================
set +e  # 不要在检查失败时退出，要跑完所有检查

CRED_FILE="/opt/proxy-credentials.json"

PANEL_PORT="18918"
PROXY_PORT="443"
SS_PORT="8388"

# Try to load actual values from credentials file
if [ -f "$CRED_FILE" ] && command -v jq >/dev/null 2>&1; then
    PANEL_PORT=$(jq -r '.panel.port // 18918' "$CRED_FILE" 2>/dev/null || echo 18918)
    PROXY_PORT=$(jq -r '.vless_reality.port // 443' "$CRED_FILE" 2>/dev/null || echo 443)
    SS_PORT=$(jq -r '.shadowsocks.port // 8388' "$CRED_FILE" 2>/dev/null || echo 8388)
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

section() { echo -e "\n${BLUE}=== $* ===${NC}"; }
ok()      { echo -e "${GREEN}✓${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
err()     { echo -e "${RED}✗${NC}  $*"; }

echo -e "${GREEN}=== 3x-ui Proxy Diagnostic Tool ===${NC}"
echo "Panel port: $PANEL_PORT"
echo "Proxy port: $PROXY_PORT"
echo "SS port:    $SS_PORT"

# ------------------------------------------------------------
# [1/7] x-ui service status
# ------------------------------------------------------------
section "[1/7] x-ui service status / 服务状态"
if systemctl is-active --quiet x-ui; then
    ok "x-ui is running"
else
    err "x-ui is not running"
fi
x-ui status 2>&1 | head -20

# ------------------------------------------------------------
# [2/7] Port listeners
# ------------------------------------------------------------
section "[2/7] Port listeners / 端口监听"
LISTEN=$(ss -tlnp 2>/dev/null | grep -E ":($PANEL_PORT|$PROXY_PORT|$SS_PORT|80)\b" || true)
if [ -n "$LISTEN" ]; then
    echo "$LISTEN"
    for p in "$PANEL_PORT" "$PROXY_PORT" "$SS_PORT"; do
        if echo "$LISTEN" | grep -q ":${p} "; then
            ok "Port ${p} is listening"
        else
            err "Port ${p} NOT listening"
        fi
    done
else
    err "No expected ports listening. x-ui may be crashed."
fi

# ------------------------------------------------------------
# [3/7] Local HTTP test
# ------------------------------------------------------------
section "[3/7] Local HTTP test / 本地 HTTP 访问测试"
CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:${PANEL_PORT}/" 2>/dev/null || echo "000")
echo "HTTP status: $CODE"
if [[ "$CODE" =~ ^(200|302|301|404)$ ]]; then
    ok "Panel responding via HTTP"
elif [ "$CODE" = "000" ]; then
    err "Cannot connect to panel on HTTP"
else
    warn "Unexpected status code: $CODE"
fi

# ------------------------------------------------------------
# [4/7] Local HTTPS test
# ------------------------------------------------------------
section "[4/7] Local HTTPS test / 本地 HTTPS 访问测试"
CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "https://localhost:${PANEL_PORT}/" 2>/dev/null || echo "000")
echo "HTTPS status: $CODE"
if [[ "$CODE" =~ ^(200|302|301|404)$ ]]; then
    ok "Panel responding via HTTPS"
elif [ "$CODE" = "000" ]; then
    warn "HTTPS not responding (expected if running in HTTP-only mode)"
else
    warn "Unexpected HTTPS status: $CODE"
fi

# ------------------------------------------------------------
# [5/7] Xray process
# ------------------------------------------------------------
section "[5/7] Xray process / Xray 进程"
XRAY_PROC=$(pgrep -a xray 2>/dev/null || true)
if [ -n "$XRAY_PROC" ]; then
    ok "Xray is running"
    echo "$XRAY_PROC"
else
    err "Xray NOT running — common cause: listen field set to port number in DB"
    warn "Fix: Check /etc/x-ui/x-ui.db inbounds.listen — must be empty string ''"
fi

# ------------------------------------------------------------
# [6/7] Firewall status
# ------------------------------------------------------------
section "[6/7] Firewall / 防火墙"
if command -v ufw >/dev/null 2>&1; then
    UFW_STATUS=$(ufw status 2>/dev/null | head -1)
    echo "ufw: $UFW_STATUS"
    if echo "$UFW_STATUS" | grep -qi "inactive"; then
        ok "ufw inactive (Lightsail firewall handles ingress)"
    fi
fi
echo "--- iptables (first 15) ---"
iptables -L INPUT -n 2>/dev/null | head -15

# ------------------------------------------------------------
# [7/7] Recent errors
# ------------------------------------------------------------
section "[7/7] Recent error logs / 近期错误日志"
if command -v x-ui >/dev/null 2>&1; then
    ERRORS=$(x-ui log 2>&1 | grep -Ei "error|fail|panic" | tail -10 || true)
    if [ -n "$ERRORS" ]; then
        echo "$ERRORS"
    else
        ok "No recent errors in x-ui logs"
    fi
fi

# Also check journalctl
echo ""
echo "--- journalctl -u x-ui (last 10 error lines) ---"
journalctl -u x-ui --no-pager 2>/dev/null | grep -Ei "error|fail|panic" | tail -10 || true

# ------------------------------------------------------------
# Summary & hints
# ------------------------------------------------------------
section "Common fixes / 常见修复"
cat <<'EOF'
  1. x-ui not running:
       sudo systemctl restart x-ui
       sudo x-ui log    # view logs

  2. Xray crashes with "unable to listen on domain address":
       — listen 字段填错了（填成端口号），必须为空字符串
       sudo sqlite3 /etc/x-ui/x-ui.db "UPDATE inbounds SET listen='';"
       sudo systemctl restart x-ui

  3. Panel inaccessible from corporate network:
       — 公司 VPN 拦截了非标端口，用手机流量访问面板

  4. SSL cert not loading:
       ls /root/.acme.sh/<IP>_ecc/       # 检查证书是否存在
       sudo sqlite3 /etc/x-ui/x-ui.db "SELECT key,value FROM settings WHERE key LIKE 'web%';"

  5. SS client shows ping timeout:
       — 正常，代理协议走 TCP/UDP 不响应 ICMP，用 TCP latency test
EOF

echo ""
echo -e "${GREEN}=== Diagnostic complete ===${NC}"

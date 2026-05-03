#!/bin/bash
# ============================================================
# Configure proxy protocols (VLESS Reality + Shadowsocks)
# 配置代理协议：VLESS Reality (主) + Shadowsocks (备用)
# ============================================================
# CRITICAL: 3x-ui 数据库里 inbounds.listen 字段必须为空字符串！
#   错误做法：把端口号填到 listen 字段
#   Xray 会报: unable to listen on domain address: 443
#   原因：listen 是监听地址（如 0.0.0.0 或空），port 是端口号，别搞混
# ============================================================
set -euo pipefail

PROXY_PORT=443
SS_PORT=8388
SERVER_IP=""
DB_FILE="/etc/x-ui/x-ui.db"
GEN_ENV="/opt/proxy-generated.env"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --proxy-port) PROXY_PORT="$2"; shift 2 ;;
        --ss-port)    SS_PORT="$2"; shift 2 ;;
        --server-ip)  SERVER_IP="$2"; shift 2 ;;
        *) echo "[ERROR] Unknown arg: $1" >&2; exit 1 ;;
    esac
done

[ -z "$SERVER_IP" ] && { echo "[ERROR] --server-ip required" >&2; exit 1; }
[ ! -f "$DB_FILE" ] && { echo "[ERROR] $DB_FILE not found" >&2; exit 1; }

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[protocols]${NC} $*"; }
warn() { echo -e "${YELLOW}[protocols]${NC} $*"; }

# ------------------------------------------------------------
# Stop x-ui while modifying DB (avoid races)
# ------------------------------------------------------------
log "Stopping x-ui to edit DB safely / 停止 x-ui 以便安全修改数据库"
systemctl stop x-ui || x-ui stop || true
sleep 2

# ------------------------------------------------------------
# Generate Reality keypair using xray
# x25519 密钥对由 xray 本身生成
# ------------------------------------------------------------
log "Generating Reality x25519 keypair / 生成 Reality x25519 密钥对"

XRAY_BIN=""
for cand in /usr/local/x-ui/bin/xray-linux-amd64 /usr/local/x-ui/bin/xray-linux-arm64 \
            /usr/local/x-ui/bin/xray /usr/bin/xray; do
    [ -x "$cand" ] && { XRAY_BIN="$cand"; break; }
done

if [ -z "$XRAY_BIN" ]; then
    XRAY_BIN="$(command -v xray || true)"
fi

if [ -z "$XRAY_BIN" ]; then
    warn "xray binary not found — using fallback keypair generator"
    # Fallback: use openssl to produce a random-ish key (not recommended long-term)
    PRIVATE_KEY=$(openssl rand -base64 32 | tr -d '=' | tr '/+' '_-' | cut -c1-43)
    PUBLIC_KEY=$(openssl rand -base64 32 | tr -d '=' | tr '/+' '_-' | cut -c1-43)
else
    KEYS=$("$XRAY_BIN" x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep -i "private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEYS"  | grep -i "public"  | awk '{print $NF}')
fi

log "Public key:  $PUBLIC_KEY"

# ------------------------------------------------------------
# Generate identifiers
# ------------------------------------------------------------
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID=$(openssl rand -hex 8)
SS_PASSWORD=$(openssl rand -base64 32 | tr -d '\n')
VLESS_EMAIL="reality-$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
SS_EMAIL="ss-$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"

# ------------------------------------------------------------
# Build inbound JSON bodies
# 3x-ui 的 inbounds 表有 settings / stream_settings / sniffing 三个 JSON 字段
# ------------------------------------------------------------
log "Building VLESS Reality inbound / 构建 VLESS Reality 入站规则"

VLESS_SETTINGS=$(cat <<EOF
{
  "clients": [
    {
      "id": "${VLESS_UUID}",
      "flow": "",
      "email": "${VLESS_EMAIL}",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": "",
      "subId": "",
      "comment": "",
      "reset": 0
    }
  ],
  "decryption": "none",
  "fallbacks": []
}
EOF
)

VLESS_STREAM=$(cat <<EOF
{
  "network": "tcp",
  "security": "reality",
  "externalProxy": [],
  "realitySettings": {
    "show": false,
    "xver": 0,
    "dest": "www.microsoft.com:443",
    "serverNames": ["www.microsoft.com"],
    "privateKey": "${PRIVATE_KEY}",
    "minClient": "",
    "maxClient": "",
    "maxTimediff": 0,
    "shortIds": ["${SHORT_ID}"],
    "settings": {
      "publicKey": "${PUBLIC_KEY}",
      "fingerprint": "chrome",
      "serverName": "",
      "spiderX": "/"
    }
  },
  "tcpSettings": {
    "acceptProxyProtocol": false,
    "header": { "type": "none" }
  }
}
EOF
)

SNIFFING=$(cat <<EOF
{
  "enabled": true,
  "destOverride": ["http", "tls", "quic", "fakedns"],
  "metadataOnly": false,
  "routeOnly": false
}
EOF
)

ALLOCATE=$(cat <<EOF
{ "strategy": "always", "refresh": 5, "concurrency": 3 }
EOF
)

log "Building Shadowsocks inbound / 构建 Shadowsocks 入站规则"

SS_SETTINGS=$(cat <<EOF
{
  "method": "2022-blake3-aes-256-gcm",
  "password": "${SS_PASSWORD}",
  "network": "tcp,udp",
  "clients": [
    {
      "method": "",
      "password": "${SS_PASSWORD}",
      "email": "${SS_EMAIL}",
      "limitIp": 0,
      "totalGB": 0,
      "expiryTime": 0,
      "enable": true,
      "tgId": "",
      "subId": "",
      "comment": "",
      "reset": 0
    }
  ]
}
EOF
)

SS_STREAM=$(cat <<EOF
{ "network": "tcp", "security": "none" }
EOF
)

# ------------------------------------------------------------
# Insert into sqlite DB
# ⚠️ CRITICAL: `listen` 字段必须为空字符串 ''
#    不能填端口号！填了会导致 xray 启动失败:
#    unable to listen on domain address: 443
# ------------------------------------------------------------
log "Inserting inbound rules / 写入入站规则到数据库"

# Clean any old inbounds with same ports (idempotency)
sqlite3 "$DB_FILE" "DELETE FROM inbounds WHERE port IN (${PROXY_PORT}, ${SS_PORT});"

# Use a here-doc with double-single-quote escape for SQL string literals
# shellcheck disable=SC2016
python3 - "$DB_FILE" "$PROXY_PORT" "$VLESS_EMAIL" \
    "$VLESS_SETTINGS" "$VLESS_STREAM" "$SNIFFING" "$ALLOCATE" \
    "$SS_PORT" "$SS_EMAIL" "$SS_SETTINGS" "$SS_STREAM" <<'PYEOF'
import sqlite3, sys, time

(db, vless_port, vless_email,
 vless_settings, vless_stream, sniffing, allocate,
 ss_port, ss_email, ss_settings, ss_stream) = sys.argv[1:]

now = int(time.time())

conn = sqlite3.connect(db)
cur = conn.cursor()

# Discover column names to be schema-agnostic (3x-ui adds columns over time)
cur.execute("PRAGMA table_info(inbounds)")
cols = {row[1] for row in cur.fetchall()}

def build_row(port, email, protocol, settings, stream):
    row = {
        "user_id":         1,
        "up":              0,
        "down":            0,
        "total":           0,
        "remark":          f"{protocol}-{port}",
        "enable":          1,
        "expiry_time":     0,
        # ⚠️ listen MUST be empty string. Putting port here crashes xray.
        "listen":          "",
        "port":            int(port),
        "protocol":        protocol,
        "settings":        settings,
        "stream_settings": stream,
        "tag":             f"inbound-{port}",
        "sniffing":        sniffing,
        "allocate":        allocate,
    }
    # Filter keys to match actual schema
    filtered = {k: v for k, v in row.items() if k in cols}
    keys = ", ".join(filtered.keys())
    placeholders = ", ".join(["?"] * len(filtered))
    return keys, placeholders, list(filtered.values())

# Insert VLESS
keys, ph, vals = build_row(vless_port, vless_email, "vless", vless_settings, vless_stream)
cur.execute(f"INSERT INTO inbounds ({keys}) VALUES ({ph})", vals)

# Insert Shadowsocks
keys, ph, vals = build_row(ss_port, ss_email, "shadowsocks", ss_settings, ss_stream)
cur.execute(f"INSERT INTO inbounds ({keys}) VALUES ({ph})", vals)

conn.commit()
conn.close()
print("[protocols] Inserted VLESS and Shadowsocks inbounds")
PYEOF

# ------------------------------------------------------------
# Start x-ui
# ------------------------------------------------------------
log "Starting x-ui / 启动 x-ui"
systemctl start x-ui || x-ui start || true
sleep 3

# ------------------------------------------------------------
# Save generated values for setup.sh summary
# ------------------------------------------------------------
cat > "$GEN_ENV" <<EOF
VLESS_UUID=${VLESS_UUID}
VLESS_PUBKEY=${PUBLIC_KEY}
VLESS_PRIVKEY=${PRIVATE_KEY}
VLESS_SHORTID=${SHORT_ID}
SS_PASSWORD=${SS_PASSWORD}
EOF
chmod 600 "$GEN_ENV"

log "Protocols configured ✅"
log "  VLESS Reality port: ${PROXY_PORT}"
log "  Shadowsocks port:   ${SS_PORT}"

exit 0

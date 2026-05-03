#!/bin/bash
# ============================================================
# Export connection links from /opt/proxy-credentials.json
# 从凭证文件导出 vless:// 和 ss:// 链接
# ============================================================
set -euo pipefail

CRED_FILE="${1:-/opt/proxy-credentials.json}"

if [ ! -f "$CRED_FILE" ]; then
    echo "[ERROR] Credentials file not found: $CRED_FILE" >&2
    echo "  Run setup.sh first to generate it." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "[ERROR] jq required. Install: sudo apt install -y jq" >&2
    exit 1
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# ------------------------------------------------------------
# Read credentials
# ------------------------------------------------------------
IP=$(jq -r '.server_ip'              "$CRED_FILE")
UUID=$(jq -r '.vless_reality.uuid'   "$CRED_FILE")
PUBKEY=$(jq -r '.vless_reality.public_key' "$CRED_FILE")
SHORTID=$(jq -r '.vless_reality.short_id'  "$CRED_FILE")
SNI=$(jq -r '.vless_reality.sni'      "$CRED_FILE")
FP=$(jq -r '.vless_reality.fingerprint' "$CRED_FILE")
VLESS_PORT=$(jq -r '.vless_reality.port' "$CRED_FILE")

SS_PORT=$(jq -r '.shadowsocks.port'       "$CRED_FILE")
SS_PWD=$(jq -r '.shadowsocks.password'    "$CRED_FILE")
SS_CIPHER=$(jq -r '.shadowsocks.cipher'   "$CRED_FILE")

# ------------------------------------------------------------
# Build VLESS Reality URL
# vless://<uuid>@<host>:<port>?type=tcp&security=reality&sni=<sni>
#       &fp=<fp>&pbk=<pubkey>&sid=<shortid>#<name>
# ------------------------------------------------------------
VLESS_NAME="Lightsail-Reality"
VLESS_URL="vless://${UUID}@${IP}:${VLESS_PORT}?encryption=none&flow=&type=tcp&security=reality&sni=${SNI}&fp=${FP}&pbk=${PUBKEY}&sid=${SHORTID}#${VLESS_NAME}"

# ------------------------------------------------------------
# Build Shadowsocks URL (SIP002)
# ss://base64(<cipher>:<password>)@<host>:<port>#<name>
# ------------------------------------------------------------
SS_NAME="Lightsail-SS"
SS_USER_B64=$(printf '%s:%s' "$SS_CIPHER" "$SS_PWD" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
SS_URL="ss://${SS_USER_B64}@${IP}:${SS_PORT}#${SS_NAME}"

# ------------------------------------------------------------
# Print
# ------------------------------------------------------------
cat <<EOF

${GREEN}===========================================${NC}
${GREEN}Connection Links / 连接链接${NC}
${GREEN}===========================================${NC}

${YELLOW}VLESS Reality (Primary):${NC}
${VLESS_URL}

${YELLOW}Shadowsocks (Backup):${NC}
${SS_URL}

${GREEN}===========================================${NC}

${YELLOW}Usage / 使用方式:${NC}

  1. Copy the URL above / 复制上面的链接
  2. Import into client / 导入到客户端:
     - Shadowrocket / v2rayNG: 直接粘贴导入
     - Clash Verge Rev: 使用 client/clash-verge-template.yaml 模板

  3. Generate QR code / 生成二维码 (需要 qrencode):
     sudo apt install -y qrencode
     echo '${VLESS_URL}' | qrencode -t ANSIUTF8

EOF

# ------------------------------------------------------------
# If qrencode is available, show QR codes
# ------------------------------------------------------------
if command -v qrencode >/dev/null 2>&1; then
    echo -e "${YELLOW}VLESS QR:${NC}"
    echo "$VLESS_URL" | qrencode -t ANSIUTF8
    echo ""
    echo -e "${YELLOW}SS QR:${NC}"
    echo "$SS_URL" | qrencode -t ANSIUTF8
fi

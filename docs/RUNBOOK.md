# Lightsail Proxy 部署手册 (RUNBOOK)

基于真实部署踩坑记录整理的完整操作手册。按顺序执行即可。

---

## 前置条件

- AWS 账号（可用 Lightsail）
- AWS CLI 已配置（`aws configure`，且账号有 Lightsail 权限）
- 本地安装 Terraform ≥ 1.5（Terraform 路径）
- Lightsail 控制台已创建并下载 SSH key pair 的 `.pem` 文件
- 本地 `.pem` 权限：`chmod 400 ~/.ssh/lightsail.pem`

---

## 第一阶段：基础设施部署

### 方式 A：Terraform（推荐）

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars，填入 key_pair_name（Lightsail 控制台创建的 key 名字）
vim terraform.tfvars

./deploy.sh tokyo
```

脚本会依次：
1. `terraform init`
2. `terraform fmt` + `validate`
3. `terraform plan`，提示确认
4. `terraform apply`
5. 输出静态 IP、SSH 命令、面板 URL

### 方式 B：CloudFormation

```bash
cd infra/cloudformation
./deploy.sh tokyo
```

功能等价，选一个即可。

**输出示例：**

```
Static IP:  43.207.123.45
Panel URL:  http://43.207.123.45:18918/
SSH:        ssh -i <your-key.pem> ubuntu@43.207.123.45
```

---

## 第二阶段：上传脚本 & 运行配置

### 1. 上传 scripts 目录到实例

```bash
STATIC_IP=43.207.123.45  # 从 deploy.sh 输出拿到
KEY=~/.ssh/lightsail.pem

scp -i "$KEY" -r scripts ubuntu@${STATIC_IP}:/tmp/

ssh -i "$KEY" ubuntu@${STATIC_IP} <<'EOF'
  sudo mkdir -p /opt/scripts
  sudo mv /tmp/scripts/* /opt/scripts/
  sudo chmod +x /opt/scripts/*.sh
EOF
```

### 2. 等待 UserData 完成（首次启动约 2-3 分钟）

```bash
ssh -i "$KEY" ubuntu@${STATIC_IP} 'ls /opt/proxy-bootstrap-complete'
# 出现这个文件说明 bootstrap 完成
```

### 3. 运行主配置脚本

```bash
ssh -i "$KEY" ubuntu@${STATIC_IP}
sudo bash /opt/scripts/setup.sh
```

脚本会：
- 安装 3x-ui（非交互模式，避免卡住）
- 申请 SSL 证书（失败则回退 HTTP 模式，不影响代理功能）
- 修改面板用户名/密码/路径
- 写入 VLESS Reality + Shadowsocks inbound
- 生成 `/opt/proxy-credentials.json`

**脚本结束后，终端会打印凭证**，同时保存在 `/opt/proxy-credentials.json`。

### 4. 导出客户端链接

```bash
sudo bash /opt/client/export-links.sh
# 或
sudo bash /opt/scripts/../client/export-links.sh
```

得到 `vless://...` 和 `ss://...` 链接，粘贴到客户端即可。

---

## 第三阶段：客户端配置

### macOS / Windows (Clash Verge Rev)

1. 打开 `client/clash-verge-template.yaml`
2. 替换占位符：
   - `{{SERVER_IP}}` → 你的静态 IP
   - `{{UUID}}` → `jq -r .vless_reality.uuid /opt/proxy-credentials.json`
   - `{{PUBLIC_KEY}}` → `jq -r .vless_reality.public_key /opt/proxy-credentials.json`
   - `{{SHORT_ID}}` → `jq -r .vless_reality.short_id /opt/proxy-credentials.json`
   - `{{SS_PASSWORD}}` → `jq -r .shadowsocks.password /opt/proxy-credentials.json`
3. 保存为 `lightsail.yaml`
4. Clash Verge Rev → Profiles → Import from file

### iOS (Shadowrocket / Stash)

1. 在实例上运行 `export-links.sh` 得到 QR 码
2. 打开 Shadowrocket，点 `+` → 扫描二维码

### Android (v2rayNG / NekoBox)

同上，扫 QR 或直接粘贴 `vless://` / `ss://` 链接。

---

## 真实踩坑记录

以下是部署过程中遇到的真实问题和解决方案。本项目的脚本已经把这些坑全部规避，这里只做记录方便理解。

### 坑 1: `/dev/fd/63: No such file or directory`

**现象：**

```bash
sudo bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
# 报错: bash: /dev/fd/63: No such file or directory
```

**根因：** `sudo` 会切换到 root 用户上下文，而 `<(curl ...)` 创建的文件描述符属于原用户的 shell，sudo 切过去之后就访问不到了。

**修复：** 先下载脚本，再执行。

```bash
curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o /tmp/install.sh
chmod +x /tmp/install.sh
sudo bash /tmp/install.sh
```

脚本中位置：`scripts/install-3xui.sh`、`infra/terraform/user_data.sh.tpl`、CloudFormation `UserData`。

---

### 坑 2: SSL 证书"找不到"但其实文件存在

**现象：** `acme.sh` 在 sudo 下跑完，3x-ui 面板里报"证书文件不存在"，但 `/root/.acme.sh/<IP>_ecc/` 里明明有 `fullchain.cer` 和 `<IP>.key`。

**根因：** acme.sh 的路径解析在 sudo 环境下有问题；3x-ui 的"一键 SSL"功能也把路径写错了。

**修复：** 手动检查文件，然后直接写入 sqlite3：

```bash
ls /root/.acme.sh/43.207.123.45_ecc/
# fullchain.cer  43.207.123.45.cer  43.207.123.45.key  ca.cer  ...

sudo sqlite3 /etc/x-ui/x-ui.db \
  "UPDATE settings SET value='/root/.acme.sh/43.207.123.45_ecc/fullchain.cer' WHERE key='webCertFile';"
sudo sqlite3 /etc/x-ui/x-ui.db \
  "UPDATE settings SET value='/root/.acme.sh/43.207.123.45_ecc/43.207.123.45.key' WHERE key='webKeyFile';"
sudo systemctl restart x-ui
```

如果证书完全申请不到（纯 IP 证书需要 ZeroSSL CA，Let's Encrypt 不支持），直接回退 HTTP：

```bash
sudo sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='' WHERE key='webCertFile';"
sudo sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='' WHERE key='webKeyFile';"
sudo systemctl restart x-ui
```

面板走 HTTP 不影响代理流量本身的加密（VLESS Reality 和 SS 都是 TCP 上自己做加密）。

脚本中位置：`scripts/configure-ssl.sh`。

---

### 坑 3: `unable to listen on domain address: 443`

**现象：** Xray 启动失败，日志里：

```
Failed to start: unable to listen on domain address: 443
```

**根因：** 3x-ui 的 inbound 配置界面里有两个输入框：
- **Listen IP**（监听地址）—— 留空 或 `0.0.0.0`
- **Port**（端口）—— 443

很多人第一次用会把 `443` 填到 Listen IP 字段里（因为 UI 不直观），导致 Xray 尝试解析 `443` 为域名。

**修复：** Listen IP 字段必须为空（或 `0.0.0.0`），端口号只填在 Port 字段：

```bash
sudo sqlite3 /etc/x-ui/x-ui.db "UPDATE inbounds SET listen='';"
sudo systemctl restart x-ui
```

脚本中位置：`scripts/configure-protocols.sh`（通过 Python 直接写库，`listen` 字段强制为空字符串）。

---

### 坑 4: 公司 VPN 下面板端口访问不到

**现象：** 办公室电脑连了公司 VPN，访问 `http://<IP>:18918/` 超时。

**根因：** 公司 VPN / 企业防火墙通常只放行 80/443，非标端口被拦截。

**修复：** 用手机流量访问面板。代理服务本身走 443 端口，连公司 WiFi 也能用，只是管理面板需要手机流量。

---

### 坑 5: Shadowsocks 客户端显示 Ping Timeout 但能用

**现象：** 客户端里给 SS 节点做"Ping 测试"显示 timeout，但切换到这个节点上网完全正常。

**根因：** Ping 用的是 ICMP 协议，代理服务（VLESS/SS）只处理 TCP/UDP，不响应 ICMP。客户端的"Ping Test"是误导性功能。

**修复：** 用 **TCP 延迟测试**（大部分客户端有这个选项），或直接用这个节点访问网站验证。

---

### 坑 6: `sqlite3: command not found`

**现象：** Ubuntu 22.04 默认镜像没有 sqlite3 工具。

**修复：**

```bash
sudo apt update
sudo apt install -y sqlite3
```

脚本中位置：bootstrap（UserData）和 `setup.sh` 都会检查和安装。

---

## 运维常见操作

### 查看凭证

```bash
sudo cat /opt/proxy-credentials.json | jq .
```

### 重启服务

```bash
sudo systemctl restart x-ui
# 或
sudo x-ui restart
```

### 查看日志

```bash
sudo x-ui log
sudo journalctl -u x-ui -f
```

### 一键排障

```bash
sudo bash /opt/scripts/troubleshoot.sh
```

### 更新 3x-ui

```bash
sudo x-ui update
```

### 销毁环境

```bash
# Terraform
cd infra/terraform
terraform destroy -var-file=envs/tokyo.tfvars

# CloudFormation
aws cloudformation delete-stack --stack-name lightsail-proxy-tokyo --region ap-northeast-1
```

---

## 下一步

- 想加订阅链接功能：`sudo x-ui` → 菜单 → 订阅管理
- 想加流量统计：3x-ui 自带，访问面板查看
- 想加多用户：面板 → Inbounds → Add Client

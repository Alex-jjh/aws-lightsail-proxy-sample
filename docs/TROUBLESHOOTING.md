# 常见问题与解决方案 (TROUBLESHOOTING)

按症状分类。先跑 `sudo bash /opt/scripts/troubleshoot.sh` 拿到完整诊断信息。

---

## 部署阶段

### ❌ `terraform apply` 提示 key pair 不存在

**错误：**

```
Error: error waiting for Lightsail Instance to become ready:
KeyPair '<name>' does not exist
```

**原因：** `key_pair_name` 填的名字在 Lightsail 控制台不存在。

**修复：**

1. 登录 Lightsail 控制台 → Account → SSH Keys
2. 确认 key pair 名字（或创建一个新的）
3. 下载 `.pem` 到本地，`chmod 400`
4. 更新 `terraform.tfvars` 中的 `key_pair_name`

> 注意：Key pair 是**区域级**的，东京区的 key 在新加坡区看不到。

---

### ❌ CloudFormation stack 卡在 `CREATE_IN_PROGRESS` 很久

**原因：** Lightsail 实例创建慢（首次启动 + UserData 要运行），一般 3-5 分钟。

**修复：** 耐心等。如果超过 10 分钟还没动：

```bash
aws cloudformation describe-stack-events \
  --stack-name lightsail-proxy-tokyo \
  --region ap-northeast-1 \
  --max-items 20
```

看最近事件里有没有 `CREATE_FAILED`。

---

## SSH 阶段

### ❌ `Permission denied (publickey)`

**原因：**

- `.pem` 文件权限错了
- 用了错误的 key
- 用户名错了（Lightsail Ubuntu 镜像用 `ubuntu`，不是 `ec2-user`）

**修复：**

```bash
chmod 400 ~/.ssh/lightsail.pem
ssh -i ~/.ssh/lightsail.pem -v ubuntu@<IP>  # -v 看详细握手过程
```

---

### ❌ `Connection timed out`

**原因：** SSH 端口（22）没开放。

**修复：** 检查 Lightsail 防火墙：

```bash
aws lightsail get-instance-port-states \
  --instance-name proxy-tokyo \
  --region ap-northeast-1
```

如果没有 22 端口，说明 Terraform 的 `aws_lightsail_instance_public_ports` 没覆盖到。重跑 `terraform apply`。

---

## 3x-ui 服务

### ❌ 面板访问不到（连 HTTP 都打不开）

优先级从高到低检查：

**1. 服务挂了？**

```bash
sudo systemctl status x-ui
sudo x-ui log | tail -50
```

**2. 端口没在监听？**

```bash
sudo ss -tlnp | grep 18918
```

如果没输出：

```bash
sudo systemctl restart x-ui
sleep 3
sudo ss -tlnp | grep 18918
```

**3. 端口被防火墙拦？**

Lightsail 防火墙：

```bash
aws lightsail get-instance-port-states \
  --instance-name proxy-tokyo \
  --region ap-northeast-1 | grep -A2 18918
```

OS 防火墙（默认 ufw 是 inactive）：

```bash
sudo ufw status
```

**4. 公司 VPN 拦了？**

用手机流量试。非标端口（18918）在企业网络基本必挂。

---

### ❌ Xray 启动失败：`unable to listen on domain address: 443`

最经典的坑。详见 [RUNBOOK.md](RUNBOOK.md#坑-3) 坑 3。

**一行命令修复：**

```bash
sudo sqlite3 /etc/x-ui/x-ui.db "UPDATE inbounds SET listen='';"
sudo systemctl restart x-ui
```

---

### ❌ Xray 启动失败：`address already in use`

**原因：** 端口已被其他进程占用。

**修复：** 找出占用进程：

```bash
sudo ss -tlnp | grep :443
# 或
sudo lsof -i :443
```

通常是旧的 Xray 没退干净：

```bash
sudo pkill -9 xray
sudo systemctl restart x-ui
```

---

## SSL 证书

### ❌ `acme.sh` 申请证书失败

**可能原因：**

1. 80 端口被占用（acme.sh standalone 模式需要）
2. 用的是 Let's Encrypt CA（不支持纯 IP 证书）
3. ACME 速率限制

**修复：**

```bash
# 1. 停掉占用 80 的服务
sudo systemctl stop nginx 2>/dev/null
sudo systemctl stop apache2 2>/dev/null

# 2. 切到 ZeroSSL（支持 IP 证书）
/root/.acme.sh/acme.sh --set-default-ca --server zerossl
/root/.acme.sh/acme.sh --register-account -m your-email@example.com

# 3. 重试
/root/.acme.sh/acme.sh --issue --standalone -d <你的IP> --keylength ec-256
```

如果仍然失败，**直接回退 HTTP**（不影响代理）：

```bash
sudo sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='' WHERE key='webCertFile';"
sudo sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='' WHERE key='webKeyFile';"
sudo systemctl restart x-ui
```

---

## 客户端

### ❌ 客户端连不上（timeout）

**排查顺序：**

1. **服务端是否健康？** 先在服务器上 `curl http://localhost:<proxy-port>` 看有没有响应（对 VLESS 来说会返回非 HTTP 错误，但至少说明端口有监听）
2. **从外网能连 TCP 吗？** 本地：`nc -zv <IP> 443`
3. **UUID / public key / short id 填对了吗？** 重新导出：`sudo bash /opt/client/export-links.sh`
4. **SNI 是否匹配？** VLESS Reality 的 `servername` 必须和服务端的 `realitySettings.serverNames` 一致（默认 `www.microsoft.com`）

---

### ❌ 客户端连上了但打不开网站

**排查：**

1. 客户端的**规则**对不对？默认国内 IP 直连，国外走代理。如果目标网站被识别为国内 IP（如某些 CDN），会走直连反而失败
2. 切换到 **Global / 全局** 模式试试
3. 检查 DNS 是否被污染：客户端里改用 DoH（DNS over HTTPS）

---

### ❌ Shadowsocks 显示 Ping Timeout

**不是 bug，是正常现象。** SS 只处理 TCP/UDP 流量，不响应 ICMP ping。用客户端的"TCP 延迟测试"功能代替。

---

## 性能问题

### ⚠️ 速度慢

**可能原因：**

1. **Lightsail 套餐太小：** `nano_3_0` 只有 512MB 内存，高并发会卡。升级到 `nano_3_2`（$5/月，1GB）或 `micro_3_0`（$10/月，2GB）
2. **流量超了：** Lightsail 超过月配额后限速。查看当月使用量：

   ```bash
   aws lightsail get-instance-metric-data \
     --instance-name proxy-tokyo \
     --metric-name NetworkOut \
     --period 2592000 --unit Bytes \
     --statistics Sum \
     --start-time "$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
     --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --region ap-northeast-1
   ```

3. **线路问题：** 东京区对国内优化，新加坡对东南亚友好，法兰克福访问欧美更快

---

## 销毁 / 清理

### 完全删除所有资源

**Terraform：**

```bash
cd infra/terraform
terraform destroy -var-file=envs/tokyo.tfvars
```

**CloudFormation：**

```bash
aws cloudformation delete-stack \
  --stack-name lightsail-proxy-tokyo \
  --region ap-northeast-1

aws cloudformation wait stack-delete-complete \
  --stack-name lightsail-proxy-tokyo \
  --region ap-northeast-1
```

**注意：** 删除 stack 会释放 Static IP。如果 IP 已经分发给很多客户端，考虑先**解绑**再删除（但解绑后的 Static IP 开始按小时计费）。

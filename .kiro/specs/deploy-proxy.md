# Spec: Deploy Lightsail Proxy

端到端部署 3x-ui 代理服务的标准工作流。每个 task 都有明确的成功标准和验证步骤。

---

## Task 1: Deploy infrastructure

**目标：** 在 AWS Lightsail 上创建实例 + 静态 IP + 防火墙规则。

**先决条件：**

- [ ] AWS CLI 已配置 (`aws sts get-caller-identity` 能返回身份)
- [ ] Lightsail 控制台已创建 SSH key pair，本地有 `.pem` 文件
- [ ] 选好 region (tokyo / singapore / frankfurt)

**执行（二选一）：**

### 选项 A: Terraform

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars 填入 key_pair_name
./deploy.sh tokyo
```

### 选项 B: CloudFormation

```bash
cd infra/cloudformation
./deploy.sh tokyo
```

**验证：**

- [ ] 部署脚本输出 Static IP
- [ ] `aws lightsail get-instance --instance-name proxy-tokyo --region ap-northeast-1` 返回实例信息
- [ ] `ssh -i <key.pem> ubuntu@<STATIC_IP> 'echo ok'` 能连上
- [ ] 实例上存在 `/opt/proxy-bootstrap-complete` 文件（UserData 运行完成）

---

## Task 2: Run post-deployment setup

**目标：** SSH 进入实例，安装 3x-ui、配置 SSL、写入代理协议。

**执行：**

```bash
STATIC_IP=$(cd infra/terraform && terraform output -raw static_ip)
# 或 CloudFormation:
# STATIC_IP=$(aws cloudformation describe-stacks --stack-name lightsail-proxy-tokyo \
#             --query 'Stacks[0].Outputs[?OutputKey==`StaticIpAddress`].OutputValue' \
#             --output text --region ap-northeast-1)

KEY=~/.ssh/lightsail.pem

# 上传脚本到实例
scp -i "$KEY" -r scripts ubuntu@${STATIC_IP}:/tmp/
scp -i "$KEY" -r client  ubuntu@${STATIC_IP}:/tmp/

ssh -i "$KEY" ubuntu@${STATIC_IP} <<'EOF'
  sudo mkdir -p /opt/scripts /opt/client
  sudo mv /tmp/scripts/* /opt/scripts/
  sudo mv /tmp/client/*  /opt/client/
  sudo chmod +x /opt/scripts/*.sh /opt/client/*.sh
  sudo bash /opt/scripts/setup.sh
EOF
```

**验证：**

- [ ] `setup.sh` 最后一段打印了凭证（用户名/密码/面板路径）
- [ ] `sudo cat /opt/proxy-credentials.json | jq .` 返回完整 JSON
- [ ] `systemctl is-active x-ui` 返回 `active`
- [ ] `pgrep xray` 返回 PID（Xray 进程在运行）

---

## Task 3: Verify deployment

**目标：** 运行诊断脚本确认所有服务健康。

**执行：**

```bash
ssh -i "$KEY" ubuntu@${STATIC_IP} 'sudo bash /opt/scripts/troubleshoot.sh'
```

**验证（全部应该通过）：**

- [ ] x-ui service: active
- [ ] Panel port (18918): listening
- [ ] Proxy port (443): listening
- [ ] SS port (8388): listening
- [ ] HTTP status on panel: 200/302/404（不是 000）
- [ ] Xray process: running
- [ ] No errors in recent logs

**如果失败：** 看 [docs/TROUBLESHOOTING.md](../../docs/TROUBLESHOOTING.md)

---

## Task 4: Export client configuration

**目标：** 生成 `vless://` 和 `ss://` 链接给客户端用。

**执行：**

```bash
# 在服务器上导出
ssh -i "$KEY" ubuntu@${STATIC_IP} 'sudo bash /opt/client/export-links.sh'

# 或拉到本地再看
ssh -i "$KEY" ubuntu@${STATIC_IP} 'sudo cat /opt/proxy-credentials.json' > credentials.json
```

**验证：**

- [ ] 得到 `vless://...` 链接（包含 UUID、pubkey、shortid、SNI）
- [ ] 得到 `ss://...` 链接
- [ ] 客户端导入链接后能连上（用浏览器访问 `https://ipinfo.io` 确认 IP 已变）

**客户端配置参考：** [README.md#客户端配置](../../README.md#-客户端配置)

---

## Task 5: Tear down

**目标：** 完全清理所有 AWS 资源，停止计费。

**执行：**

### Terraform

```bash
cd infra/terraform
terraform destroy -var-file=envs/tokyo.tfvars
```

### CloudFormation

```bash
aws cloudformation delete-stack \
  --stack-name lightsail-proxy-tokyo \
  --region ap-northeast-1

aws cloudformation wait stack-delete-complete \
  --stack-name lightsail-proxy-tokyo \
  --region ap-northeast-1
```

**验证：**

- [ ] `aws lightsail get-instances --region ap-northeast-1` 不再包含 `proxy-tokyo`
- [ ] `aws lightsail get-static-ips --region ap-northeast-1` 不再包含 `proxy-tokyo-static-ip`
- [ ] 本地可以删除 `.pem` 文件（如果这个 key pair 不再需要）

**注意事项：**

- 删除 stack 会**立即释放** Static IP。如果客户端分发了这个 IP，会全部失效
- 如果只是临时停用，可以考虑 **停实例**（但 Static IP 解绑后开始按小时计费，不建议长期停用）

---

## Rollback

如果 Task 2 的 setup.sh 失败，可以重跑（脚本是幂等的）：

```bash
ssh -i "$KEY" ubuntu@${STATIC_IP} 'sudo bash /opt/scripts/setup.sh'
```

如果 3x-ui 安装坏掉需要全清重来：

```bash
ssh -i "$KEY" ubuntu@${STATIC_IP} <<'EOF'
  sudo systemctl stop x-ui
  sudo x-ui uninstall </dev/null || true
  sudo rm -rf /etc/x-ui /usr/local/x-ui
  sudo bash /opt/scripts/setup.sh
EOF
```

如果整个实例坏掉，`terraform taint` 实例后重新 apply：

```bash
terraform taint aws_lightsail_instance.proxy
terraform apply -var-file=envs/tokyo.tfvars
```

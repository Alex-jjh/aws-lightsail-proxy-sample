# Lightsail Proxy Infra

在 AWS Lightsail 上一键部署 **3x-ui 代理服务** 的完整 IaC 项目，支持 **CloudFormation** 和 **Terraform** 两种部署方式。

基于真实部署踩坑经验整理，包含常见问题的自动化修复。

---

## 📐 架构图

```
┌─────────────────────────────────────────────────────────────┐
│                    Client (你的电脑/手机)                    │
│            Clash Verge Rev / Shadowrocket                   │
└────────────────────────┬────────────────────────────────────┘
                         │
             ┌───────────┴───────────┐
             │                       │
        VLESS Reality          Shadowsocks
         (443/TCP)              (8388/TCP)
             │                       │
             ▼                       ▼
┌─────────────────────────────────────────────────────────────┐
│              AWS Lightsail Instance (Ubuntu 22.04)           │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  3x-ui Panel  (18918)  →  sqlite3 /etc/x-ui/x-ui.db  │   │
│  │  Xray-core   (443, 8388)                             │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│         Static IP (免费，绑定实例，防止重启换 IP)              │
└─────────────────────────────────────────────────────────────┘
                         │
                         ▼
                    Internet
```

---

## ✨ 特性

- **两套 IaC**：CloudFormation + Terraform 任选其一
- **多区域支持**：Tokyo / Singapore / Frankfurt（避开美国区，IP 更干净）
- **静态 IP**：免费绑定，实例重启不换 IP
- **自动化脚本**：安装 / SSL / 协议配置 / 安全加固 / 故障诊断
- **踩坑修复**：`/dev/fd/63` 报错、acme.sh SSL 路径问题、Listen IP 误填等 6 个真实问题全部自动规避
- **客户端模板**：开箱即用的 Clash Verge Rev 配置

---

## 🚀 Quick Start

### 前置条件

- AWS 账号（Lightsail 前 3 个月免费）
- AWS CLI 已配置（`aws configure`）
- 一个 Lightsail SSH key pair（控制台创建）
- 可选：Terraform ≥ 1.5（Terraform 路径需要）

### 部署方式 A：CloudFormation

```bash
cd infra/cloudformation
./deploy.sh tokyo           # 或 singapore / frankfurt
```

### 部署方式 B：Terraform

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars 填入 key_pair_name 等
./deploy.sh tokyo
```

### 部署后配置

```bash
# SSH 登录实例（IP 从 deploy.sh 输出获取）
ssh -i ~/.ssh/your-key.pem ubuntu@<STATIC_IP>

# 运行主配置脚本（自动安装 3x-ui + 配置 SSL + 添加协议）
sudo bash /opt/scripts/setup.sh

# 输出的凭证保存在 /opt/proxy-credentials.json
sudo cat /opt/proxy-credentials.json
```

---

## 🆚 CloudFormation vs Terraform

| 特性 | CloudFormation | Terraform |
|---|---|---|
| 供应商 | AWS 官方 | HashiCorp（社区） |
| 状态文件 | AWS 托管 | 本地 / S3 远程 |
| 语法 | YAML（声明式） | HCL（声明式 + 函数） |
| 多云 | ❌ 仅 AWS | ✅ 多云 |
| 本场景学习曲线 | 低（内置支持 Lightsail） | 中 |
| 变量复用 | 参数文件 | `.tfvars` + `locals` |
| 推荐场景 | 纯 AWS 项目、熟悉 CFN | 跨云、需要复杂逻辑 |

**本项目两种方式功能等价**，选你喜欢的即可。

---

## 📱 客户端配置

| 平台 | 推荐客户端 | VLESS Reality | Shadowsocks |
|---|---|---|---|
| macOS / Windows | Clash Verge Rev | ✅ | ✅ |
| iOS | Shadowrocket / Stash | ✅ | ✅ |
| Android | v2rayNG / NekoBox | ✅ | ✅ |

### 导出连接信息

```bash
ssh ubuntu@<STATIC_IP>
sudo bash /opt/scripts/../client/export-links.sh
```

生成 `vless://` / `ss://` 链接，粘贴到客户端即可。

或使用 `client/clash-verge-template.yaml` 填入服务器信息后导入。

---

## 💰 成本

| 项目 | 费用 |
|---|---|
| Lightsail `nano_3_2` 实例 | **$5/月**（1 GB RAM, 1 vCPU, 2 TB 流量） |
| Static IP（绑定实例时） | **免费** |
| 数据传输（2TB 内） | **免费** |
| **总计** | **$5/月** |

> 超出 2TB 后按区域计费（Tokyo 约 $0.09/GB），个人使用一般用不完。

---

## 🗂 仓库结构

```
lightsail-proxy-infra/
├── infra/
│   ├── cloudformation/       # CloudFormation 部署
│   └── terraform/            # Terraform 部署
├── scripts/                  # 实例上运行的配置脚本
├── client/                   # 客户端配置模板
├── docs/                     # 详细文档
└── .kiro/specs/              # Kiro spec 工作流
```

---

## 📚 文档

- [RUNBOOK.md](docs/RUNBOOK.md) —— 完整操作手册（含真实踩坑记录）
- [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) —— 常见问题和解决方案
- [ARCHITECTURE.md](docs/ARCHITECTURE.md) —— 架构说明和设计决策

---

## ❓ FAQ

**Q: 为什么避开美国区域？**
A: 美国 Lightsail IP 段被很多服务（Netflix、ChatGPT）识别为数据中心 IP，容易被风控。东京、新加坡、法兰克福的 IP 相对干净。

**Q: 为什么代理端口用 443？**
A: 公司防火墙 / 咖啡厅 WiFi 通常只放行 80/443，非标端口会被拦截。

**Q: 面板端口 18918 公司网络访问不了？**
A: 正常现象，公司 VPN 会拦非标端口。用手机流量访问面板即可，代理服务本身走 443 不受影响。

**Q: 可以不用 Static IP 吗？**
A: 不建议。实例一停就换 IP，客户端全部失效。Lightsail 的 Static IP 绑定实例时免费。

---

## 📄 License

MIT

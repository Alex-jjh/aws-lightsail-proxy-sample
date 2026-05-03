# 架构与设计决策 (ARCHITECTURE)

## 架构图

```
                                           ┌─── mobile (cellular) ──┐
                                           │  管理用，避免公司 VPN    │
                                           ▼
                                  ┌──────────────────┐
                                  │  3x-ui Panel     │  :18918
                                  │  (sqlite3 DB)    │
                                  └────────┬─────────┘
                                           │
                          ┌────────────────┼────────────────┐
                          ▼                ▼                ▼
                    VLESS Reality    Shadowsocks       HTTP :80
                       :443            :8388          (ACME cert)
                          ▲                ▲
                          │                │
  ┌──────────────────────┴────────────────┴──────────────────────┐
  │                                                                │
  │    Client (Clash Verge / Shadowrocket / v2rayNG)              │
  │    — Auto-select by latency                                    │
  │    — GEOIP,CN,DIRECT;  MATCH,Proxy                            │
  │                                                                │
  └────────────────────────────────────────────────────────────────┘


  AWS Lightsail (Ubuntu 22.04)
  ├── Static IP (免费绑定)
  ├── Ports: 22 / 80 / 443 / 18918 / 8388
  └── UserData bootstrap
      ├── apt update/upgrade
      ├── install: sqlite3, curl, jq, ufw
      └── download /tmp/install-3xui.sh
```

## 协议选择理由

### VLESS Reality 作为主协议

- **抗封锁能力强：** Reality 借用真实网站（`www.microsoft.com`）做 TLS handshake，GFW 的 SNI 探测和主动探测都难以识别
- **性能好：** 无多余加密开销（传输层的 TLS 就够了）
- **支持广泛：** 主流客户端都支持

### Shadowsocks 作为备用

- **协议简单：** Reality 失效时可以快速切换
- **2022 版加密：** `2022-blake3-aes-256-gcm` 有更强的重放保护

### 为什么不用 Trojan

Trojan 需要真实域名 + 合法证书，对纯 IP 部署不友好。Reality 不需要域名，更适合一次性部署。

## 端口选择

| 端口 | 用途 | 为什么这样选 |
|---|---|---|
| 22 | SSH | 标准 |
| 80 | ACME HTTP-01 challenge | 证书续期需要 |
| 443 | VLESS Reality | 穿透企业防火墙必备 |
| 8388 | Shadowsocks | SS 默认端口，客户端预期 |
| 18918 | 3x-ui 面板 | 非标端口降低扫描风险 |

## 为什么选 Lightsail 而不是 EC2

| 维度 | Lightsail | EC2 |
|---|---|---|
| 价格 | $5/月固定 | 按实际用量，易超预算 |
| 流量 | 2TB/月包含 | 按 GB 计费 |
| 网络 | 简单（自带防火墙） | VPC + Security Group 复杂 |
| 静态 IP | 绑定实例免费 | EIP 释放后收费 |
| 学习曲线 | 低 | 高 |

对个人代理场景，Lightsail 是更好的选择。

## IaC 设计决策

### 为什么同时提供 CloudFormation 和 Terraform

- **CloudFormation：** AWS 原生，无需安装额外工具，账单透明
- **Terraform：** 跨云可复用，`plan` 输出直观，社区生态更好

两者在本项目**功能完全等价**，用户可根据团队偏好选择。

### 为什么 UserData 只做 bootstrap，不直接装 3x-ui

**分离关注点：**

1. UserData 只运行一次（实例首次启动），无法参数化二次调用
2. 如果 UserData 失败，调试困难（要重建实例）
3. 3x-ui 的配置（面板路径、用户名密码、证书）需要参数化，更适合独立脚本

**方案：** UserData 负责系统更新 + 下载安装脚本；`setup.sh` 负责所有可重复执行的配置。

### 为什么直接写 sqlite3 而不是调用 3x-ui API

**三个原因：**

1. **避免交互式安装脚本卡住：** 3x-ui 的 `install.sh` 会问端口、账号密码，非交互模式下默认值随机生成不可控
2. **避免 HTTP API 的先有鸡还是先有蛋问题：** API 需要先登录，登录需要已知账号密码
3. **事务性更强：** 一个 `.sql` 文件搞定所有配置，失败了好回滚

**权衡：** 3x-ui 升级时如果 schema 变了（加列/改字段），脚本可能需要调整。我们用 `PRAGMA table_info` 动态探测列名来缓解这个风险。

### Static IP 为什么独立成资源

Terraform 里把 `aws_lightsail_static_ip` 和 `aws_lightsail_static_ip_attachment` 分开写是因为：

- 如果以后要换实例但保留 IP（客户端不用改配置），只需删除 `_attachment` + 重建 instance
- 绑定实例时 Static IP 免费，不绑定时按小时计费，独立管理生命周期更清晰

### Terraform `aws_lightsail_instance_public_ports` 是 singleton

**踩坑：** 这个资源**替换**实例上所有端口规则，不是追加。第一次写的时候如果漏了 SSH(22)，apply 之后就进不去实例了。

所有需要的端口必须在**同一个资源块**里列全。本项目的 `main.tf` 一次性列出 22/80/443/18918/8388。

### CloudFormation 直接用 `Networking.Ports`

CloudFormation 的 `AWS::Lightsail::Instance` 资源在 `Networking.Ports` 属性里直接定义端口规则，没有单独的 port resource。也是替换而非追加，同样的注意事项。

## 安全考量

### 做了什么

- 面板路径随机化（首次访问需要 URL，爆破成本高）
- 面板账号密码随机生成（20 字符强密码）
- `fail2ban` 保护 SSH
- `unattended-upgrades` 自动装安全补丁
- 面板端口非标（18918）降低扫描暴露面

### 没做什么（可选增强）

- **没有启用 MFA** —— 3x-ui 不支持，只有账号密码
- **没有配置 SSH 端口改非标** —— Lightsail 默认端口扫描压力已经被 AWS 层吸收
- **没有 DDoS 保护** —— Lightsail 自带基础 DDoS 防护，个人场景够用
- **没有审计日志** —— 3x-ui 自带简单日志，需要长期审计可以接 CloudWatch Logs

## 成本分析

### 一台实例的月度成本（东京区）

| 项目 | 费用 |
|---|---|
| `nano_3_2` 实例 | $5.00 |
| Static IP（绑定时） | $0.00 |
| 数据传输（首 2TB） | $0.00 |
| **合计** | **$5.00** |

### 触发额外费用的情况

- **月流量超 2TB：** 约 $0.09/GB（东京）
- **Static IP 未绑定：** $0.005/小时 ≈ $3.60/月
- **快照备份：** $0.05/GB/月

### 省钱建议

1. 不用的实例直接 `terraform destroy`，别停机省电（停机不省钱，反而 IP 占用费开始算）
2. 不做自动快照（小时级计费累加快）

## 可扩展性

当前架构支持 1 台服务器 ≈ 几十个客户端并发。如果需要更多：

- **纵向扩展：** 升级 bundle 到 `small_3_0`（$20/月，2GB RAM，4TB 流量）
- **横向扩展：** 多开几台（东京 + 新加坡），客户端用 load-balance 规则
- **换架构：** 流量需求 >10TB/月，Lightsail 不再划算，考虑 EC2 + CloudFront 或自建 VPS

## 未来可以做

- [ ] 订阅链接自动生成
- [ ] 流量告警（接 CloudWatch）
- [ ] Cloudflare Warp 前置做混淆
- [ ] 多后端负载均衡
- [ ] Docker 化 3x-ui 方便迁移

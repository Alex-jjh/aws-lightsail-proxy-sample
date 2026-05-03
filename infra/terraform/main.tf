# ============================================================
# AWS Lightsail Proxy Server
# 代理服务器主资源定义
# ============================================================

# ------------------------------------------------------------
# Lightsail Instance
# 主实例：Ubuntu 22.04 + 自动 bootstrap 脚本
# ------------------------------------------------------------
resource "aws_lightsail_instance" "proxy" {
  name              = var.instance_name
  availability_zone = "${var.aws_region}${var.availability_zone}"
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id
  key_pair_name     = var.key_pair_name != "" ? var.key_pair_name : null

  # UserData 在实例首次启动时运行一次
  # 作用：更新系统、安装依赖、下载 3x-ui 安装脚本
  # 注意：这里不直接安装 3x-ui，留给 setup.sh 处理（可重复运行 + 参数化）
  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    panel_port = var.panel_port
  })

  tags = var.tags
}

# ------------------------------------------------------------
# Static IP
# 静态 IP：绑定实例时免费，防止实例重启后 IP 变化
# ⚠️ 必须有 —— 没有它，每次 stop/start 都会换 IP，客户端全部失效
# ------------------------------------------------------------
resource "aws_lightsail_static_ip" "proxy" {
  name = "${var.instance_name}-static-ip"
}

resource "aws_lightsail_static_ip_attachment" "proxy" {
  static_ip_name = aws_lightsail_static_ip.proxy.name
  instance_name  = aws_lightsail_instance.proxy.name
}

# ------------------------------------------------------------
# Firewall / Public Ports
# 防火墙规则（Lightsail 公网端口）
#
# ⚠️ CRITICAL: aws_lightsail_instance_public_ports 是 singleton 资源
#    会替换实例上 ALL 的端口规则。必须在此处一次性列出所有需要的端口。
#    如果漏掉 SSH(22)，会导致无法登录实例。
# ------------------------------------------------------------
resource "aws_lightsail_instance_public_ports" "proxy" {
  instance_name = aws_lightsail_instance.proxy.name

  # SSH —— 保留，否则无法登录
  port_info {
    protocol  = "tcp"
    from_port = 22
    to_port   = 22
  }

  # HTTP —— Let's Encrypt ACME 验证 + 证书续期需要
  port_info {
    protocol  = "tcp"
    from_port = 80
    to_port   = 80
  }

  # HTTPS / 主代理端口（VLESS Reality）
  # 使用 443 是为了穿透公司防火墙和咖啡厅 WiFi（非标端口会被拦）
  port_info {
    protocol  = "tcp"
    from_port = var.proxy_port
    to_port   = var.proxy_port
  }

  # 3x-ui 面板端口（非标端口，仅管理用）
  port_info {
    protocol  = "tcp"
    from_port = var.panel_port
    to_port   = var.panel_port
  }

  # Shadowsocks 备用端口（VLESS Reality 被墙时的 fallback）
  port_info {
    protocol  = "tcp"
    from_port = var.ss_backup_port
    to_port   = var.ss_backup_port
  }

  # 确保静态 IP 先绑定再配置端口
  depends_on = [aws_lightsail_static_ip_attachment.proxy]
}

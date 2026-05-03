# ============================================================
# Outputs
# 输出值：部署后显示的连接信息和下一步操作
# ============================================================

locals {
  static_ip       = aws_lightsail_static_ip.proxy.ip_address
  panel_url_http  = "http://${local.static_ip}:${var.panel_port}/"
  panel_url_https = "https://${local.static_ip}:${var.panel_port}/"
  ssh_command     = "ssh -i <your-key.pem> ubuntu@${local.static_ip}"
}

output "instance_name" {
  description = "Lightsail instance name"
  value       = aws_lightsail_instance.proxy.name
}

output "static_ip" {
  description = "Static public IP address"
  value       = local.static_ip
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = local.ssh_command
}

output "panel_url_http" {
  description = "3x-ui panel URL (HTTP). Use this if SSL is not configured."
  value       = local.panel_url_http
}

output "panel_url_https" {
  description = "3x-ui panel URL (HTTPS). Use this after SSL is configured."
  value       = local.panel_url_https
}

output "panel_port" {
  description = "3x-ui panel port"
  value       = var.panel_port
}

output "proxy_port" {
  description = "Main proxy port (VLESS Reality)"
  value       = var.proxy_port
}

output "ss_port" {
  description = "Shadowsocks backup port"
  value       = var.ss_backup_port
}

output "region" {
  description = "Deployed AWS region"
  value       = var.aws_region
}

output "next_steps" {
  description = "Post-deployment instructions"
  value       = <<-EOT

    ====================================
    ✅ Infrastructure deployed!
       基础设施部署完成！
    ====================================

    Next steps / 下一步:

    1. SSH into the instance / SSH 登录实例:
       ${local.ssh_command}

    2. Upload scripts / 上传配置脚本:
       scp -i <your-key.pem> -r scripts/ ubuntu@${local.static_ip}:/tmp/
       ssh ubuntu@${local.static_ip} 'sudo mv /tmp/scripts/* /opt/scripts/'

    3. Run the setup script / 运行配置脚本:
       sudo bash /opt/scripts/setup.sh

    4. Access the panel / 访问面板:
       ${local.panel_url_http}

    5. Configure VLESS Reality on port ${var.proxy_port}
       配置 VLESS Reality 在端口 ${var.proxy_port}
       ⚠️ Listen IP must be EMPTY! / Listen IP 必须留空!

    6. If on corporate VPN, access panel from mobile (cellular data)
       公司 VPN 会拦截非标端口 ${var.panel_port}，请用手机流量访问面板
       代理服务本身走 ${var.proxy_port} 端口，不受影响。

    ====================================
  EOT
}

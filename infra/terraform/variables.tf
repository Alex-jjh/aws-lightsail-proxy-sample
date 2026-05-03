# ============================================================
# Input Variables
# 输入变量定义
# ============================================================

variable "aws_region" {
  description = <<-EOT
    AWS region to deploy Lightsail instance.
    部署 Lightsail 实例的 AWS 区域。

    Recommended (clean IP ranges, lower latency for target users):
    推荐区域（IP 段干净、目标用户延迟低）:
      - ap-northeast-1 (Tokyo)
      - ap-southeast-1 (Singapore)
      - eu-central-1   (Frankfurt)
      - ap-south-1     (Mumbai)

    Avoid US regions — IPs get flagged by streaming services.
    避开美国区 —— IP 容易被流媒体服务风控。

    Any region that supports Lightsail is accepted; non-recommended
    regions only trigger a warning, not a hard error.
    接受任何支持 Lightsail 的区域；非推荐区仅警告，不阻止。
  EOT
  type        = string
  default     = "ap-northeast-1"

  validation {
    # Basic format check: e.g. "ap-northeast-1". Keeps obvious typos out
    # but does not restrict to a hardcoded list.
    # 基础格式校验，防低级拼写错误，不限制到固定列表。
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must be a valid AWS region ID, e.g. ap-northeast-1."
  }
}

variable "instance_name" {
  description = "Name for the Lightsail instance"
  type        = string
  default     = "proxy-server"
}

variable "blueprint_id" {
  description = "Lightsail OS blueprint. Ubuntu 22.04 LTS recommended for 3x-ui."
  type        = string
  default     = "ubuntu_22_04"
}

variable "bundle_id" {
  description = <<-EOT
    Lightsail plan / 套餐.

    Common options / 常用选项:
      - nano_3_0   : $3.50/mo, 512MB RAM, 1 vCPU, 1TB transfer
      - nano_3_2   : $5/mo,    1GB RAM,   1 vCPU, 2TB transfer  (recommended / 推荐)
      - micro_3_0  : $10/mo,   2GB RAM,   2 vCPU, 3TB transfer
      - small_3_0  : $20/mo,   2GB RAM,   2 vCPU, 4TB transfer
      - medium_3_0 : $40/mo,   4GB RAM,   2 vCPU, 5TB transfer

    Full list / 完整列表:
      aws lightsail get-bundles --region <region>

    Any valid Lightsail bundle_id is accepted.
    接受任何有效的 Lightsail bundle_id。
  EOT
  type        = string
  default     = "nano_3_2"

  validation {
    # Lightsail bundle IDs follow pattern like nano_3_2, micro_3_0, etc.
    # Lightsail bundle ID 的命名规律。
    condition     = can(regex("^[a-z]+_[0-9]+_[0-9]+$", var.bundle_id))
    error_message = "bundle_id must match Lightsail bundle format, e.g. nano_3_2, micro_3_0."
  }
}

variable "availability_zone" {
  description = "Availability zone suffix (a, b, c, d). Full AZ = region + suffix."
  type        = string
  default     = "a"

  validation {
    condition     = contains(["a", "b", "c", "d"], var.availability_zone)
    error_message = "Availability zone suffix must be one of: a, b, c, d."
  }
}

variable "key_pair_name" {
  description = "Name of existing Lightsail key pair for SSH access. Leave empty to use default."
  type        = string
  default     = ""
}

variable "panel_port" {
  description = "3x-ui web panel port. Use non-standard port for security."
  type        = number
  default     = 18918

  validation {
    condition     = var.panel_port >= 1024 && var.panel_port <= 65535
    error_message = "Panel port must be between 1024 and 65535."
  }
}

variable "proxy_port" {
  description = "Main proxy listening port. 443 recommended to bypass corporate firewalls."
  type        = number
  default     = 443
}

variable "ss_backup_port" {
  description = "Shadowsocks backup proxy port."
  type        = number
  default     = 8388
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Project   = "lightsail-proxy"
    ManagedBy = "terraform"
  }
}

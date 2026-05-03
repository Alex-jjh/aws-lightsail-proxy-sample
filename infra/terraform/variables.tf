# ============================================================
# Input Variables
# 输入变量定义
# ============================================================

variable "aws_region" {
  description = "AWS region to deploy Lightsail instance. Avoid US regions - IPs get flagged easily."
  type        = string
  default     = "ap-northeast-1"

  validation {
    condition = contains([
      "ap-northeast-1", # Tokyo
      "ap-southeast-1", # Singapore
      "eu-central-1",   # Frankfurt
      "ap-south-1",     # Mumbai
      "sa-east-1",      # São Paulo
      "eu-west-1",      # Ireland
    ], var.aws_region)
    error_message = "Choose a recommended region. Avoid US regions (us-east-1, us-west-2, etc.)."
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
  description = "Lightsail plan. nano_3_2 = $5/month (1GB RAM, 1vCPU, 2TB transfer)"
  type        = string
  default     = "nano_3_2"

  validation {
    condition     = contains(["nano_3_0", "nano_3_2", "micro_3_0", "small_3_0"], var.bundle_id)
    error_message = "Choose a valid Lightsail bundle. nano_3_2 ($5/mo) recommended."
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

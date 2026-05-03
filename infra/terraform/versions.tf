terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Optional: S3 backend for remote state
  # Uncomment and fill in to share state across a team.
  # ------------------------------------------------------------
  # backend "s3" {
  #   bucket         = "my-terraform-state"
  #   key            = "lightsail-proxy/terraform.tfstate"
  #   region         = "ap-northeast-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-lock"
  # }
}

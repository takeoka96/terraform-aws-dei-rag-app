terraform {
  # 1.11 以上: Gemini API キーを tfstate に残さない「write-only 属性」を使うため
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # 第 2 段階: AWS から BigQuery に接続するための GCP 側の部品を作る
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# 認証は gcloud auth application-default login で行う
provider "google" {
  project = var.gcp_project_id
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

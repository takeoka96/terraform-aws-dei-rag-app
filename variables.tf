variable "project" {
  description = "リソース名の接頭辞"
  type        = string
  default     = "dei-rag"
}

variable "region" {
  description = "AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "azs" {
  description = "ALB を置くアベイラビリティゾーン（ALB は 2 つ以上必要）"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

variable "vpc_cidr" {
  description = "VPC の CIDR"
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "パブリックサブネット（ALB と ECS タスク）"
  type        = list(string)
  default     = ["10.1.0.0/24", "10.1.1.0/24"]
}

# Cloud Run 版（2 vCPU / 4 GiB）と同じサイズ
variable "task_cpu" {
  description = "ECS タスクの CPU（1024 = 1 vCPU）"
  type        = number
  default     = 2048
}

variable "task_memory" {
  description = "ECS タスクのメモリ（MiB）。埋め込みモデル e5-large の読み込みに約 4GB 必要"
  type        = number
  default     = 4096
}

variable "image_tag" {
  description = "ECR に push したイメージのタグ"
  type        = string
  default     = "latest"
}

# ---------------------------------------------------------------
# Gemini API キー
# ephemeral = true のため、tfstate にもプランにも保存されない。
# ファイルには書かず、環境変数で渡す:
#   export TF_VAR_gemini_api_key="..."
# ---------------------------------------------------------------
variable "gemini_api_key" {
  description = "Gemini API キー（環境変数 TF_VAR_gemini_api_key で渡す）"
  type        = string
  sensitive   = true
  ephemeral   = true
}

variable "gemini_api_key_version" {
  description = "API キーを差し替えるときに 1 ずつ増やす（write-only 属性の更新トリガー）"
  type        = number
  default     = 1
}

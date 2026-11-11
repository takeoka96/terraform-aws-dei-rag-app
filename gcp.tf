# =====================================================================
# 第 2 段階: AWS（ECS タスク）から GCP の BigQuery へ、キーなしで書き込む
#
# 仕組み（Workload Identity 連携）:
#   1. ECS タスクが AWS の一時的な認証情報で「dei-rag-ecs-task-role である」と証明
#   2. GCP の Workload Identity プールが、AWS アカウントとロール名を確認して GCP のトークンと交換
#   3. そのトークンでサービスアカウントになりすまし、BigQuery に書き込む
#
# quest_2 で手作業で構築した既存の GCP 環境（Cloud Run、BigQuery のデータセットとテーブル等）は
# 名前で参照するだけで、作成・変更・削除はしない。
# Terraform で管理するのは、このファイルで新しく作る「接続のための部品」だけ。
# =====================================================================

data "aws_caller_identity" "current" {}

locals {
  aws_account_id = data.aws_caller_identity.current.account_id

  # ECS タスクが AWS 上で名乗る ARN（末尾のタスク ID を除いた形）
  aws_task_role_arn = "arn:aws:sts::${local.aws_account_id}:assumed-role/${aws_iam_role.task.name}"
}

# ---------------------------------------------------------------
# 必要な API を有効化
# disable_on_destroy = false: destroy しても API は無効化しない
# （quest_2 の既存環境が使っている可能性があるため）
# ---------------------------------------------------------------
resource "google_project_service" "required" {
  for_each = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------
# Workload Identity プールと AWS プロバイダ
# プールは削除後 30 日間同じ ID を使えないため、apply / destroy を繰り返せるよう末尾にランダムな文字列を付ける
# ---------------------------------------------------------------
resource "random_id" "pool_suffix" {
  byte_length = 2
}

resource "google_iam_workload_identity_pool" "aws" {
  workload_identity_pool_id = "aws-dei-rag-${random_id.pool_suffix.hex}"
  display_name              = "AWS dei-rag-app"
  description               = "terraform-aws-dei-rag-app の ECS タスクからのアクセス用"

  depends_on = [google_project_service.required]
}

resource "google_iam_workload_identity_pool_provider" "aws" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.aws.workload_identity_pool_id
  workload_identity_pool_provider_id = "aws-account"
  display_name                       = "AWS account"

  aws {
    account_id = local.aws_account_id
  }

  # AWS の ARN から「どのロールか」を取り出す（GCP 公式の推奨マッピング）
  attribute_mapping = {
    "google.subject"     = "assertion.arn"
    "attribute.aws_role" = "assertion.arn.contains('assumed-role') ? assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_name}/') : assertion.arn"
  }

  # この AWS アカウントの中でも、ECS のタスクロールからのアクセスだけを受け付ける
  attribute_condition = "attribute.aws_role == '${local.aws_task_role_arn}'"
}

# ---------------------------------------------------------------
# BigQuery に書き込むためのサービスアカウント
# ---------------------------------------------------------------
resource "google_service_account" "aws_writer" {
  account_id   = "dei-rag-aws-writer"
  display_name = "dei-rag-app on AWS (BigQuery writer)"
  description  = "AWS の ECS タスクが Workload Identity 連携でなりすまし、BigQuery に書き込む"
}

# AWS のタスクロールに、このサービスアカウントへのなりすましを許可する
resource "google_service_account_iam_member" "aws_task_impersonation" {
  service_account_id = google_service_account.aws_writer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.aws.name}/attribute.aws_role/${local.aws_task_role_arn}"
}

# ---------------------------------------------------------------
# BigQuery の権限（最小権限: データセット全体ではなく、書き込むテーブルだけ）
# 既存のテーブルに「メンバーを1人追加する」だけで、既存の権限は変更しない
# ---------------------------------------------------------------
resource "google_bigquery_table_iam_member" "query_logs_writer" {
  project    = var.gcp_project_id
  dataset_id = var.bq_dataset_id
  table_id   = "query_logs"
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.aws_writer.email}"
}

# ---------------------------------------------------------------
# user_voices テーブル（「あなたの声」の保存先）への書き込み権限
# ---------------------------------------------------------------

resource "google_bigquery_table_iam_member" "user_voices_writer" {
  project    = var.gcp_project_id
  dataset_id = var.bq_dataset_id
  table_id   = "user_voices"
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.aws_writer.email}"
}


# ---------------------------------------------------------------
# ECS タスクに渡す接続設定（秘密情報は含まない）
# google-auth ライブラリの "external_account" 形式
# ---------------------------------------------------------------
locals {
  gcp_credential_config = {
    type                              = "external_account"
    universe_domain                   = "googleapis.com"
    audience                          = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.aws.name}"
    subject_token_type                = "urn:ietf:params:aws:token-type:aws4_request"
    token_url                         = "https://sts.googleapis.com/v1/token"
    service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${google_service_account.aws_writer.email}:generateAccessToken"
    credential_source = {
      environment_id                 = "aws1"
      region_url                     = "http://169.254.169.254/latest/meta-data/placement/availability-zone"
      url                            = "http://169.254.169.254/latest/meta-data/iam/security-credentials"
      regional_cred_verification_url = "https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15"
    }
  }
}

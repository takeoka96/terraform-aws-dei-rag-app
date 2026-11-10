# Gemini API キーを Secrets Manager に保存し、ECS タスクに環境変数として渡す。
# secret_string_wo（write-only）を使うため、キーの値は tfstate に保存されない。

resource "aws_secretsmanager_secret" "gemini" {
  name = "${var.project}/gemini-api-key"

  # 学習用: destroy 後すぐに同じ名前で作り直せるよう、削除待機期間を 0 にする
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "gemini" {
  secret_id                = aws_secretsmanager_secret.gemini.id
  secret_string_wo         = var.gemini_api_key
  secret_string_wo_version = var.gemini_api_key_version
}

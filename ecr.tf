# アプリのコンテナイメージ置き場（Cloud Run 版の Artifact Registry に相当）
resource "aws_ecr_repository" "app" {
  name                 = "${var.project}-app"
  image_tag_mutability = "MUTABLE"

  # 学習用: destroy 時にイメージごと削除する
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

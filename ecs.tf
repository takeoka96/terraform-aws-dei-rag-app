# Cloud Run 版の dei-voice-map-app を、ECS Fargate で同じ 2 vCPU / 4 GiB で動かす。
# ChromaDB は別サービスにせず、イメージ内の data/ から起動時に読み込む
# （CHROMA_HOST を設定しないと app.py がローカル読み込みに切り替わる）。

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project}-app"
  retention_in_days = 3
}

# ---------------------------------------------------------------
# IAM
# 実行ロール: ECS がイメージ取得・ログ送信・シークレット取得に使う
# タスクロール: アプリ自身が使う（第 2 段階で GCP の Workload Identity 連携に使う）
# ---------------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.project}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# このアプリのシークレット 1 つだけ読める
resource "aws_iam_role_policy" "execution_secret" {
  name = "read-gemini-secret"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.gemini.arn
    }]
  })
}

resource "aws_iam_role" "task" {
  name               = "${var.project}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# ---------------------------------------------------------------
# タスク定義
# ---------------------------------------------------------------
resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  # M チップの Mac でビルドしたイメージをそのまま動かす。Graviton は x86 より安い
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    secrets = [{
      name      = "GEMINI_API_KEY"
      valueFrom = aws_secretsmanager_secret.gemini.arn
    }]

    # 第 2 段階: BigQuery への接続設定（gcp.tf）。キーは含まない
    environment = [
      { name = "GCP_CREDENTIAL_CONFIG", value = jsonencode(local.gcp_credential_config) },
      { name = "GOOGLE_CLOUD_PROJECT", value = var.gcp_project_id },
      { name = "AWS_REGION", value = var.region },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "app"
      }
    }
  }])

  depends_on = [aws_secretsmanager_secret_version.gemini]
}

# ---------------------------------------------------------------
# サービス（常時 1 タスク）
# ---------------------------------------------------------------
resource "aws_ecs_service" "app" {
  name            = "${var.project}-app"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = true # NAT なしで ECR・Hugging Face・Gemini に接続するため
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = 8080
  }

  # イメージの取得（約 2GB）と起動を待つ
  health_check_grace_period_seconds = 180

  # 起動に失敗し続けたら、前の正常なタスク定義に戻す
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http]
}

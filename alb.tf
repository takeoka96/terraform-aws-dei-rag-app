resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]

  # Streamlit は WebSocket で画面を更新する。
  # 初回検索時のモデル読み込み（約 1 分）で接続が切れないよう、既定の 60 秒から延ばす
  idle_timeout = 300
}

resource "aws_lb_target_group" "app" {
  name        = "${var.project}-app-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip" # Fargate はタスクの IP をターゲットにする

  health_check {
    path    = "/_stcore/health" # Streamlit 標準のヘルスチェック
    matcher = "200"
  }

  # Streamlit はセッションをタスクのメモリに持つため、台数を増やす場合に備えて同じタスクへ振り分ける
  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
  }

  # destroy や入れ替えを早くする（既定は 300 秒）
  deregistration_delay = 30
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

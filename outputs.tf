output "app_url" {
  description = "ブラウザで開く URL"
  value       = "http://${aws_lb.main.dns_name}"
}

output "ecr_repository_url" {
  description = "イメージの push 先"
  value       = aws_ecr_repository.app.repository_url
}

output "region" {
  value = var.region
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "gcp_service_account" {
  description = "AWS の ECS タスクがなりすます GCP のサービスアカウント"
  value       = google_service_account.aws_writer.email
}

output "gcp_workload_identity_pool" {
  value = google_iam_workload_identity_pool.aws.name
}

#!/usr/bin/env bash
# =====================================================================
# quest_2 のアプリを ARM64 でビルドし、AWS → GCP 接続用の入口スクリプト（docker/）を
# 上乗せしてから ECR に push する。
# ECS サービスが既にあれば、新しいイメージで入れ替える。
#
# 使い方（このリポジトリのフォルダで実行）:
#   ./scripts/push_image.sh ~/quest_2
#
# 前提: terraform apply（少なくとも ECR まで）済み、Docker と AWS CLI が使えること
# 注意: quest_2 の data/（speeches_clustered.csv、embeddings_round5.npy）は
#       Git に含まれないため、データが手元にある Mac でビルドする。
# =====================================================================
set -euo pipefail

APP_DIR="${1:?quest_2 のフォルダのパスを指定してください（例: ./scripts/push_image.sh ~/quest_2）}"

for f in Dockerfile app.py data/speeches_clustered.csv data/embeddings_round5.npy; do
  if [ ! -f "$APP_DIR/$f" ]; then
    echo "エラー: $APP_DIR/$f が見つかりません" >&2
    exit 1
  fi
done

REPO_URL="$(terraform output -raw ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"
# -target で ECR だけ作った時点では region の output がまだ無いため、URL から取り出す
# 例: 123456789012.dkr.ecr.ap-northeast-1.amazonaws.com → ap-northeast-1
REGION="$(echo "$REGISTRY" | cut -d. -f4)"

echo "==> ECR にログイン"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_TAG="dei-rag-base:latest"

echo "==> 1/2 quest_2 のイメージを ARM64 でビルド（初回は 10 分ほどかかります）"
docker build --platform linux/arm64 -t "$BASE_TAG" "$APP_DIR"

echo "==> 2/2 AWS → GCP 接続用の入口スクリプトを上乗せ（docker/）"
docker build --platform linux/arm64 \
  --build-arg BASE_IMAGE="$BASE_TAG" \
  -t "$REPO_URL:latest" "$SCRIPT_DIR/../docker"

echo "==> push"
docker push "$REPO_URL:latest"

# ECS サービスがすでに作られていれば、新しいイメージでタスクを入れ替える
if CLUSTER="$(terraform output -raw ecs_cluster_name 2>/dev/null)" \
   && SERVICE="$(terraform output -raw ecs_service_name 2>/dev/null)"; then
  echo "==> ECS サービスを新しいイメージで入れ替え"
  aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" \
    --force-new-deployment --query "service.serviceName" --output text
fi

echo "完了"

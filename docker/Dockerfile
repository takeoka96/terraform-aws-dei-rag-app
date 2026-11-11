# quest_2 のイメージを土台に、AWS → GCP 接続用の入口スクリプトだけを上乗せする。
# quest_2 のコード（app.py、Dockerfile）は一切変更しない。
#
# BASE_IMAGE には、quest_2 の Dockerfile からビルドしたイメージを指定する
# （scripts/push_image.sh が自動で行う）。
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

COPY entrypoint.py /opt/aws-gcp-bridge/entrypoint.py

# 作業ディレクトリは quest_2 と同じ /app のまま（app.py と data/ を相対パスで読むため）
CMD ["python", "/opt/aws-gcp-bridge/entrypoint.py"]

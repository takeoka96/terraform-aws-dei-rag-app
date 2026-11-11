"""
AWS（ECS Fargate）上で quest_2 のアプリを起動するための入口。

Google の認証ライブラリ（google-auth）は、AWS の認証情報を
「環境変数」または「EC2 のメタデータサーバー」から取得する。
ECS Fargate はどちらも使わず、専用のエンドポイント（169.254.170.2）で認証情報を配るため、
そのままでは Workload Identity 連携が動かない。

このスクリプトは:
  1. ECS のエンドポイントから AWS の一時的な認証情報を取得し、環境変数に入れる
  2. 認証情報は数時間で入れ替わるため、バックグラウンドで定期的に取り直す
  3. GCP の接続設定（環境変数 GCP_CREDENTIAL_CONFIG）をファイルに書き出し、
     GOOGLE_APPLICATION_CREDENTIALS で google-auth に渡す
  4. 同じプロセスで Streamlit を起動する（環境変数を共有するため）

google-auth はトークンを更新するたびに環境変数を読み直すので、
quest_2 の app.py を変更しなくても bigquery.Client() がそのまま動く。
GCP_CREDENTIAL_CONFIG が無いとき（第 1 段階の構成）は、何もせず Streamlit を起動する。
"""

import json
import os
import sys
import threading
import time
import urllib.request

ECS_CREDENTIALS_HOST = "http://169.254.170.2"
REFRESH_INTERVAL_SECONDS = 15 * 60
CREDENTIAL_FILE = "/tmp/gcp-credential-config.json"


def load_aws_credentials() -> None:
    """ECS タスクロールの一時的な認証情報を取得し、環境変数に設定する"""
    relative_uri = os.environ["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"]
    with urllib.request.urlopen(ECS_CREDENTIALS_HOST + relative_uri, timeout=5) as response:
        credentials = json.load(response)

    os.environ["AWS_ACCESS_KEY_ID"] = credentials["AccessKeyId"]
    os.environ["AWS_SECRET_ACCESS_KEY"] = credentials["SecretAccessKey"]
    os.environ["AWS_SESSION_TOKEN"] = credentials["Token"]


def refresh_loop() -> None:
    while True:
        time.sleep(REFRESH_INTERVAL_SECONDS)
        try:
            load_aws_credentials()
        except Exception as e:  # 失敗しても次回に再試行する。アプリは止めない
            print(f"[aws-gcp-bridge] AWS 認証情報の更新に失敗: {e}", flush=True)


def setup_gcp_bridge() -> None:
    config = os.environ.get("GCP_CREDENTIAL_CONFIG")
    if not config:
        print("[aws-gcp-bridge] GCP_CREDENTIAL_CONFIG なし。BigQuery 連携なしで起動", flush=True)
        return

    with open(CREDENTIAL_FILE, "w") as f:
        f.write(config)
    os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = CREDENTIAL_FILE

    try:
        load_aws_credentials()
        print("[aws-gcp-bridge] AWS 認証情報を取得。BigQuery 連携を有効化", flush=True)
    except Exception as e:
        print(f"[aws-gcp-bridge] AWS 認証情報の取得に失敗: {e}", flush=True)

    threading.Thread(target=refresh_loop, daemon=True).start()


if __name__ == "__main__":
    setup_gcp_bridge()

    # quest_2 の Dockerfile の CMD と同じ内容で Streamlit を起動
    from streamlit.web import cli as streamlit_cli

    sys.argv = [
        "streamlit", "run", "app.py",
        "--server.port=8080",
        "--server.address=0.0.0.0",
    ]
    sys.exit(streamlit_cli.main())

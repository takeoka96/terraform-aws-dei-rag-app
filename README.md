# terraform-aws-dei-rag-app

自作の RAG アプリ「**DEI 国民の声マップ**」（[quest_2](https://github.com/takeoka96/quest_2)）を、Google Cloud（Cloud Run）に加えて **AWS（ECS Fargate）でも動かす**ための Terraform コードです。

アプリのコードは quest_2 に置いたまま、このリポジトリには**インフラのコードだけ**を置いています（アプリとインフラのリポジトリを分ける構成）。

**目的**: 同じコンテナを Cloud Run と AWS の両方で動かし、マネージドなサーバーレス実行環境と、ネットワークから自分で組み立てる構成の違いを比較すること。

## 構成図

```mermaid
flowchart LR
    user([利用者のブラウザ])
    dev([開発者の Mac<br/>docker build --platform linux/arm64])

    subgraph AWS["AWS 東京リージョン"]
        ecr[(ECR<br/>コンテナイメージ)]
        sm[[Secrets Manager<br/>Gemini API キー]]
        cw[[CloudWatch Logs]]

        subgraph VPC["VPC 10.1.0.0/16（パブリックサブネット × 2）"]
            alb["ALB<br/>HTTP:80"]
            task["ECS Fargate タスク<br/>ARM64 / 2 vCPU / 4 GB<br/>Streamlit + ChromaDB（インメモリ）<br/>+ multilingual-e5-large-instruct"]
        end
    end

    gemini[[Gemini API<br/>gemini-2.5-flash]]
    hf[[Hugging Face<br/>埋め込みモデル]]
    bq[(BigQuery<br/>検索ログ・利用者の声<br/>※第 2 段階)]

    dev -->|push| ecr
    user --> alb -->|8080| task
    ecr -.->|イメージ取得| task
    sm -.->|環境変数| task
    task -.-> cw
    task --> gemini
    task -->|初回検索時| hf
    task -.->|第 2 段階| bq
```

| 要素 | 内容 |
|---|---|
| ネットワーク | VPC、パブリックサブネット 2（1a・1c）、IGW。NAT ゲートウェイなし |
| 入口 | ALB（HTTP:80）→ ターゲットグループ（IP ターゲット、8080、ヘルスチェック `/_stcore/health`） |
| 実行環境 | ECS Fargate、ARM64（Graviton）、2 vCPU / 4 GB、常時 1 タスク |
| イメージ | ECR。quest_2 の Dockerfile を Mac で ARM64 ビルドして push |
| 秘密情報 | Gemini API キーを Secrets Manager に保存し、実行ロール経由で環境変数として注入 |
| ログ | CloudWatch Logs（3 日保持） |
| セキュリティグループ | インターネット → ALB(80) → ECS(8080) と、手前の SG からのみ許可 |

## 動作確認（第 1 段階）

`terraform apply` で構築し、AWS 上で動作を確認したときの記録です。

### ALB 経由で検索できる

URL が ALB のアドレスになっており、AWS 上で動いています。「6301 件」はイメージ内の CSV と埋め込みから ChromaDB に登録された件数で、Cloud Run 版（外部の ChromaDB）と同じデータを、アプリのコードを変えずに読み込めています。

![検索画面](docs/images/aws-app-search.png)

### Gemini による考察が生成される

Secrets Manager に保存した API キーが、ECS の実行ロール経由で環境変数として渡されています。

![AI による考察](docs/images/aws-app-insight.png)

### ALB のヘルスチェックを通過

Fargate のタスクは IP（VPC 10.1.0.0/16 内）でターゲットグループに登録され、Streamlit のヘルスチェック `/_stcore/health` を通過しています。

![ターゲットグループ](docs/images/aws-target-healthy.png)

## Cloud Run 版との比較

| 項目 | Cloud Run 版（GCP） | AWS 版（このリポジトリ） |
|---|---|---|
| 実行環境 | Cloud Run（2 vCPU / 4 GiB） | ECS Fargate（2 vCPU / 4 GB） |
| CPU アーキテクチャ | x86_64 | ARM64（Graviton。x86 より約 2 割安い） |
| 入口・URL | Cloud Run が URL と HTTPS を自動で発行 | VPC・サブネット・SG・ALB・ターゲットグループを自分で構築 |
| イメージ置き場 | Artifact Registry | ECR |
| ChromaDB | 別サービス `chroma` に HTTP で接続 | アプリ内でインメモリ起動し、イメージ内の CSV / 埋め込みから登録 |
| API キー | Cloud Run のサービス設定 | Secrets Manager。値は Terraform の write-only 属性で渡し、**tfstate にも残らない** |
| BigQuery への書き込み | 同じ GCP 内なのでサービスアカウントで自動認証 | 別クラウドからの接続になる（第 2 段階で Workload Identity 連携） |
| 課金 | リクエストがないときは 0 台まで縮退 | ALB とタスクが常時課金（約 0.14 USD / 時）。確認後に destroy |
| 構築方法 | gcloud / コンソール | `terraform apply` |

**分かったこと**: Cloud Run は「コンテナを渡せば URL が出る」ところまでを肩代わりしてくれるのに対し、AWS ではネットワークとロードバランサーを自分で設計する必要がある。その分、通信経路（SG の連鎖）や権限（実行ロールとタスクロールの分離）をコードで細かく制御できる。ネットワークと ALB の部分は [terraform-aws-wordpress](https://github.com/takeoka96/terraform-aws-wordpress) と同じ設計を再利用した。

### ChromaDB の構成を変えた理由

Cloud Run 版は ChromaDB を別サービスに分けているが、AWS 版では 1 コンテナにまとめた。データは約 6,300 件と小さく、起動時にメモリへ登録しても数十秒で終わるため。`app.py` は環境変数 `CHROMA_HOST` の有無で接続先を切り替える作りになっており、**アプリのコードは変更せずに**構成だけを変えられた。

## 進め方

| 段階 | 内容 | 状態 |
|---|---|---|
| 第 1 段階 | ECS Fargate で動かす（検索と AI 考察） | 完了 |
| 第 2 段階 | Workload Identity 連携で、AWS からキーなしで BigQuery に書き込む | 予定 |

第 1 段階では GCP の認証情報を持たないため、BigQuery への書き込み（検索ログと「あなたの声」）は失敗します。検索ログの失敗は画面に表示されませんが、「あなたの声」の送信はエラーメッセージになります。

## 使い方

### 前提

- Terraform 1.11 以上、Docker、AWS CLI
- AWS の認証情報（`aws configure`）
- Gemini API キー
- [quest_2](https://github.com/takeoka96/quest_2) のフォルダと、その中の `data/speeches_clustered.csv` と `data/embeddings_round5.npy`（Git には含まれていないため、手元にあるもの）

### 構築

```bash
# 1. Gemini API キーを環境変数で渡す（ファイルには書かない）
export TF_VAR_gemini_api_key="Gemini API キー"

# 2. 初期化
terraform init

# 3. まずイメージ置き場（ECR）だけ作る
terraform apply -target=aws_ecr_repository.app

# 4. アプリをビルドして push（quest_2 のパスを指定。初回は 10 分ほど）
./scripts/push_image.sh ~/quest_2

# 5. 残りをすべて作る（約 5 分）
terraform apply
```

完了すると URL が表示されます。タスクの起動とヘルスチェックの通過まで、さらに 2〜3 分待ってから開いてください。初回の検索は埋め込みモデルのダウンロードのため 1 分ほどかかります。

```
app_url = "http://dei-rag-alb-xxxxxxxx.ap-northeast-1.elb.amazonaws.com"
```

ECR だけ先に作るのは、ECS がタスクを起動する時点でイメージが存在している必要があるためです。

### アプリを更新したとき

```bash
./scripts/push_image.sh ~/quest_2
```

イメージを push し、ECS のタスクを新しいイメージで入れ替えます。

### 削除

```bash
terraform destroy
```

ECR のイメージ、シークレットも含めてすべて削除されます。`TF_VAR_gemini_api_key` が設定されたターミナルで実行してください。

## 費用の目安

東京リージョン、オンデマンド料金での概算です。

| リソース | 時間あたり |
|---|---|
| Fargate ARM 2 vCPU / 4 GB | 約 0.10 USD |
| ALB | 約 0.024 USD + LCU |
| パブリック IPv4（タスク 1 + ALB 2） | 約 0.015 USD |
| **合計** | **約 0.14 USD / 時間** |

このほか、ECR のイメージ保存（約 2GB、月 0.2 USD 程度）と Secrets Manager（月 0.4 USD、日割り）がかかります。

## ファイル構成

```
.
├── versions.tf          # Terraform とプロバイダのバージョン
├── variables.tf         # 変数（Gemini API キーは ephemeral）
├── network.tf           # VPC、サブネット、IGW、セキュリティグループ
├── alb.tf               # ALB、ターゲットグループ、リスナー
├── ecr.tf               # コンテナイメージのリポジトリ
├── secrets.tf           # Secrets Manager（write-only でキーを保存）
├── ecs.tf               # ECS クラスター、タスク定義、サービス、IAM ロール
├── outputs.tf
├── scripts/
│   └── push_image.sh    # ARM64 ビルドと ECR への push、タスク入れ替え
└── terraform.tfvars.example
```

## 既知の制限と今後の改善点

- **BigQuery に書き込めない**: 第 2 段階で Workload Identity 連携を追加する
- **HTTP のみ**: 独自ドメインと ACM 証明書で HTTPS 化できる（terraform-aws-wordpress と同じ方法）
- **イメージに未使用のデータが入っている**: quest_2 の `data/` には、アプリが使わない過去の埋め込み（round1〜4, 6）や生データが含まれ、約 140MB 余分。`.dockerignore` で除外できる
- **埋め込みモデルを起動のたびにダウンロードしている**: ビルド時にイメージへ含めれば初回検索の待ち時間がなくなる（代わりにイメージが約 2GB 大きくなる）
- **ECS タスクがパブリックサブネットにある**: 受信は ALB からのみに制限済み。より厳密にするなら、プライベートサブネット + VPC エンドポイント（ECR、Secrets Manager、Logs）にする（費用増）
- **コンテナのヘルスチェックが未設定**: ALB のヘルスチェックで正常性は確認しているが、ECS のタスク画面ではヘルスステータスが「不明」と表示される。タスク定義に `healthCheck` を追加すれば ECS 側でも判定できる
- **常時 1 タスク**: 利用がないときは `desired_count = 0` にすれば ALB 以外の課金を止められる

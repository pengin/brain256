# brain-registry

`brain-registry` は、`brainwrt-ct` のバンドルを tar アーカイブで配布する小さな HTTP レジストリです。ホスト PC からはトークン認証付きでバンドルを送信し、デバイスからは認証なしで取得します。データはファイルシステムに保存するため、データベースや実行時の外部依存はありません。

この README はレジストリ単体の起動・運用を説明します。バンドルの作成とデバイス側の操作は、[リポジトリ全体の README](../README.md) と [`brainwrt-ct` の仕様](../docs/brainwrt-ct.md) を参照してください。

> **重要:** `brain-registry` にはユーザー認証やアクセス制御の仕組みがありません。`PUSH_TOKEN` は `PUT` の送信時に使う共有トークンにすぎず、`GET` は認証なしで実行できます。このサーバーをインターネットから到達できる場所へ、絶対に直接公開しないでください。信頼できる LAN または VPN などの閉じたネットワーク内だけで使用してください。

## 1. 役割と通信の流れ

レジストリはバンドルの内容を変更せず、そのまま保存・配布します。バンドルの作成はホスト側で行い、デバイス側の `brainwrt-ct pull` が取得後に登録します。

```text
ホスト PC
  bundles/<name>/
       │ PUT（PUSH_TOKEN で認証）
       ▼
brain-registry :8080
       │ GET（認証なし）
       ▼
デバイス上の brainwrt-ct pull
       │
       └ manifest.conf と root/ を検証して /data/apps/<name>/ へ登録
```

レジストリは tar の内容を検証しません。`PUT` で受け取ったデータを保存し、`GET` で返すだけです。`brainwrt-ct pull` は一時ディレクトリへ展開してから `manifest.conf` の存在と tar のパスを検証するため、配布物の最終的な検証はデバイス側で行われます。

## 2. 最短の起動・送信・取得

### 2.1 レジストリを起動する

`registry/` ディレクトリで実行します。`PUSH_TOKEN` は `PUT` に必要な秘密値です。

```sh
PUSH_TOKEN=<push-token> DATA_DIR=./data go run .
```

既定では `:8080` で待ち受けます。別のアドレスや保存先を指定する場合は、[設定](#6-設定) の環境変数を使います。

### 2.2 ホスト PC からバンドルを送信する

リポジトリのルートディレクトリで `scripts/registry.sh` を実行します。

```sh
BRAINWRT_REGISTRY_URL=http://<registry-host>:8080 \
BRAINWRT_REGISTRY_TOKEN=<push-token> \
  ./scripts/registry.sh push webcam
```

バージョンを省略すると、`YYYYMMDD_HHMMSS_<hash8>` 形式のバージョンを自動生成します。明示する場合は次のように指定します。

```sh
BRAINWRT_REGISTRY_URL=http://<registry-host>:8080 \
BRAINWRT_REGISTRY_TOKEN=<push-token> \
  ./scripts/registry.sh push webcam v2
```

`scripts/registry.sh` は `manifest.conf` と `root/` だけを tar に含めて送信します。`Dockerfile` と `packages.txt` は送信しません。

### 2.3 デバイスから取得する

```sh
export BRAINWRT_CT_REGISTRY_URL=http://<registry-host>:8080
brainwrt-ct pull webcam
brainwrt-ct up webcam
```

`pull` の既定バージョンは `latest` です。`pull` は取得・検証・登録までを行いますが、取得後に自動起動はしません。明示したバージョンを取得する場合は `brainwrt-ct pull webcam v2` と実行します。

## 3. HTTP API

### エンドポイント

| メソッド | パス | 認証 | 動作 |
|---|---|---|---|
| `PUT` | `/bundles/{name}/{version}` | 必須 | バンドルの tar アーカイブを保存します。成功時は `201 Created` を返します。 |
| `GET` | `/bundles/{name}/{version}` | 不要 | 指定したバージョンの tar アーカイブを返します。`version=latest` も使えます。 |
| `GET` | `/api/bundles` | 不要 | 登録済みバンドルとバージョンを JSON で返します。 |
| `GET` | `/` | 不要 | ブラウザーで一覧を見る HTML ページを返します。 |

### バンドルの送信

```http
PUT /bundles/webcam/v2 HTTP/1.1
Authorization: Bearer <PUSH_TOKEN>
Content-Type: application/x-tar

<tar archive bytes>
```

`Authorization` ヘッダーは `Bearer ` と `PUSH_TOKEN` を連結した値と完全一致する必要があります。サーバーはリクエスト本文を最大 512 MiB まで受け付けます。上限を超えた場合は `413 Request Entity Too Large` を返します。

同じ `{name}/{version}` をもう一度送信すると、そのバージョンのアーカイブを置き換えます。成功した送信のたびに、そのバージョンが `latest` になります。

### バンドルの取得

```sh
curl http://<registry-host>:8080/bundles/webcam/latest -o webcam.tar
curl http://<registry-host>:8080/bundles/webcam/v2 -o webcam-v2.tar
```

成功時の本文は tar アーカイブで、`Content-Type` は `application/x-tar` です。`latest` はバージョン文字列の大小で決まるのではなく、最後に成功した `PUT` が更新したポインターで解決されます。

### 一覧 JSON

`GET /api/bundles` は、次の形式の JSON を返します。

```json
{
  "webcam": {
    "versions": ["20260720_120000_abcd1234", "v2"],
    "latest": "v2"
  }
}
```

`versions` は辞書順、`latest` は最後に成功した送信のバージョンです。まだバンドルがない場合は `{}` を返します。トップページはこの API を使って、各バージョンの取得リンクを表示します。

### 主なエラー

| ステータス | 条件 |
|---|---|
| `400 Bad Request` | 名前・バージョンが不正、または `PUT` に `latest` を指定した場合 |
| `401 Unauthorized` | `PUT` のトークンがない、または一致しない場合 |
| `404 Not Found` | 指定したバンドルまたはバージョンが存在しない場合 |
| `413 Request Entity Too Large` | `PUT` の本文が 512 MiB を超えた場合 |
| `405 Method Not Allowed` | 対応していない HTTP メソッドを使った場合 |
| `500 Internal Server Error` | 保存先の読み書きなど、サーバー内部で失敗した場合 |

## 4. 名前・バージョン・`latest`

`{name}` と `{version}` には、次の条件があります。

- 使用できる文字は英数字、`.`、`_`、`-` です。
- 長さは 255 バイト以下です。
- 空文字、`.`、`..` は指定できません。
- `PUT` の `{version}` に `latest` は指定できません。`latest` は取得時の予約語です。

この制限は、URL の値をそのまま保存先のディレクトリ名・ファイル名に使うためです。条件に合わない値は `400 Bad Request` になります。

## 5. 保存形式と更新の扱い

`DATA_DIR` の下に、バンドル名ごとのディレクトリを作ります。

```text
<DATA_DIR>/
└── webcam/
    ├── 20260720_120000_abcd1234.tar
    ├── v2.tar
    └── latest        # 最後に成功した PUT のバージョン文字列
```

- バンドルの tar は、受信したバイト列のまま保存します。
- tar と `latest` は一時ファイルへ書き込んでから rename するため、各ファイルの更新途中の内容は公開しません。
- tar の保存と `latest` の更新は一つのトランザクションではありません。保存先の障害時には、新しい tar が存在しても `latest` が以前の値のまま残る場合があります。
- 削除 API はありません。不要なバージョンは、サービス停止後に `DATA_DIR` の該当 tar と `latest` を管理者が整理してください。
- レジストリのデータディレクトリは、プロセスの実行ユーザーが読み書きできる必要があります。

## 6. 設定

| 環境変数 | 既定値 | 内容 |
|---|---|---|
| `LISTEN_ADDR` | `:8080` | HTTP の待ち受けアドレスです。 |
| `DATA_DIR` | `./data` | tar と `latest` を保存するディレクトリです。起動時に作成します。 |
| `PUSH_TOKEN` | なし | 必須の送信認証トークンです。未設定の場合、起動に失敗します。 |

### 直接起動

```sh
PUSH_TOKEN=<push-token> \
DATA_DIR=/var/lib/brain-registry \
LISTEN_ADDR=:8080 \
  ./brain-registryd
```

### systemd

`deploy/brain-registry.service` に systemd のユニット例があります。ユニットは次の環境ファイルから `PUSH_TOKEN` を読み込みます。

```sh
# /etc/brain-registry/push-token.env
PUSH_TOKEN=<push-token>
```

このファイルには秘密値を記載するため、不要なユーザーが読めない権限を設定してください。ユニットでは `DynamicUser=yes` と `StateDirectory=brain-registry` を使います。配置先の systemd とファイル権限の運用に合わせて確認してください。

## 7. セキュリティと運用上の注意

- `GET /bundles/...` と `GET /api/bundles` に認証はありません。レジストリへ到達できる相手は、バンドルと一覧を取得できます。秘密情報をバンドルへ含めないでください。インターネット向けには公開せず、信頼できる LAN または VPN などの閉じたネットワーク内だけで使用してください。
- このサーバーは TLS を提供せず、平文 HTTP のみを受け付けます。HTTP 上で `PUSH_TOKEN` を送るため、信頼できる LAN、Tailscale などのプライベートネットワーク、または TLS 終端を行うリバースプロキシの背後で使ってください。
- 既定の `LISTEN_ADDR=:8080` は全インターフェースで待ち受けます。外部へ公開する必要がない場合は、`127.0.0.1:8080` やプライベートネットワーク側のアドレスに限定してください。
- 認証は送信権限だけを保護します。アクセス制御、レート制限、バンドルの署名検証、tar 内容の検査はこのサーバーの責務ではありません。
- `PUSH_TOKEN` は環境変数や systemd の環境ファイルで管理し、シェル履歴や公開リポジトリへ残さないでください。

## 8. ビルドとテスト

### ビルド

実行時の外部ライブラリに依存しない Linux 用バイナリを作成します。

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o brain-registryd .
```

配置先に合わせて `GOARCH` を変更してください。たとえば ARM64 なら `GOARCH=arm64` です。

### テスト

```sh
go test ./...
```

テストは HTTP API、トークン認証、`latest` の解決、名前とバージョンの検証、本文サイズ上限、一覧 API、トップページ、保存エラーの応答を確認します。

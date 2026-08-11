# brain-registry

`brainwrt-ct` のバンドル tar アーカイブを配布する、最小構成の HTTP レジストリです。ビルドマシンからはトークン認証付きで送信でき、ネットワークから到達可能な場所からは認証なしで取得できます。`brain-registry` は単一の静的 Go バイナリとして動作し、データをファイルシステムに保存します。データベースや外部依存は必要ありません。

## API

- `PUT /bundles/{name}/{version}` — リクエスト本文としてバンドルの tar アーカイブを受け取ります。`Authorization: Bearer <PUSH_TOKEN>` ヘッダーが必要です。`{version}` に文字列 `"latest"` は指定できません。`latest` は GET リクエストで最新版を取得するために予約されています。
+ `GET /bundles/{name}/{version}` — バンドルの tar アーカイブを返します。`{version}` に `latest` を指定すると、その名前で最後に送信されたバージョンを取得します。
+ `GET /api/bundles` — 認証は不要です。登録済みバンドルを JSON で一覧表示します。形式は `{"<name>": {"versions": [...], "latest": "..."}}` で、バージョンは辞書順に並びます。まだ何も送信されていない場合は `{}` を返します。
- `GET /` — 認証は不要です。バイナリに埋め込まれた自己完結型の HTML ページを返します。このページは `/api/bundles` を取得して一覧表を表示し、各バージョンから対応する `GET /bundles/{name}/{version}` のダウンロード URL にリンクします。

`{name}` と `{version}` は `^[A-Za-z0-9._-]+$` に一致しなければならず、`.` と `..` は指定できません。

## 設定（環境変数）

| 変数 | 既定値 | 備考 |
|---|---|---|
| `LISTEN_ADDR` | `:8080` | |
| `DATA_DIR` | `./data` | 存在しない場合は起動時に作成します |
| `PUSH_TOKEN` | *(なし)* | **必須**。未設定の場合、プロセスは起動しません |

## ビルド

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o brain-registryd .
```

`GOARCH` は配置先のアーキテクチャに置き換えます（例: `arm64`）。

## 起動

```sh
PUSH_TOKEN=<token> DATA_DIR=/var/lib/brain-registry ./brain-registryd
```

systemd ユニットの例は `deploy/brain-registry.service` を参照してください。TLS の復号を行うリバースプロキシや、Tailscale などのプライベートネットワークを使った外部アクセスの構成は、このサーバーの対象外です。このサーバーは平文 HTTP のみを提供するため、必要に応じて前段にリバースプロキシやプライベートネットワークを置いてください。

## 動作確認

```sh
curl -X PUT --data-binary @bundle.tar -H "Authorization: Bearer <token>" \
  http://<host>:8080/bundles/webcam/20260720_120000_abcd1234
curl http://<host>:8080/bundles/webcam/latest -o bundle.tar
```

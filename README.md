# WordPress Security Audit on JP Hosting

日本のホスティング環境で、指定ディレクトリ配下にある複数の WordPress サイトをまとめて検査・更新するためのシェルスクリプト集です。

## スクリプト一覧

| スクリプト | 目的 | サイトへの変更 |
|---|---|---|
| `check-wp.sh` | 情報収集 **＋ 改ざん検知**（コア/プラグインの整合性検証） | なし（読み取り専用） |
| `check-wp-noverify.sh` | 情報収集のみ（整合性検証を省いた軽量・高速版） | なし（読み取り専用） |
| `update-wp-all.sh` | 情報収集 **＋ 一括アップデート**（コア/プラグイン/テーマ/翻訳） | **あり（更新を実行）** |
| `check-log-and-file-sakura.sh` | さくら向け: `~/log/access_*.gz` から過去N日分のアクセスログを検索 | なし（読み取り専用） |

`check-wp.sh` / `check-wp-noverify.sh` / `update-wp-all.sh` は、指定ディレクトリ配下の `wp-config.php` を再帰的に探し、見つかった各 WordPress インストールに対して処理を実行します。
`check-log-and-file-sakura.sh` はさくらインターネットのレンタルサーバーを対象に、ホームフォルダの `~/log/` にある gzip 圧縮アクセスログを検索します（→ [アクセスログの検索](#アクセスログの検索-check-log-and-file-sakurash)）。

## 収集する情報（3スクリプト共通）

- サイト名（`blogname`）
- サイトURL（`home`）
- WordPress バージョン
- 管理者メールアドレス（`admin_email`）
- データベースサイズ（`wp db size`）
- フォルダサイズ（`du -sh`）

### `check-wp.sh` が追加で行う検証

- `wp core verify-checksums` — コアファイルの整合性検証
- `wp plugin verify-checksums --all` — 全プラグインファイルの整合性検証

### `update-wp-all.sh` が追加で行う更新

- WordPress コア本体の更新
- 全プラグインの更新
- 全テーマの更新
- コア/プラグイン/テーマの翻訳（言語パック）の更新

## 必要要件

- Bash
- WP-CLI がインストールされていること（`check-wp.sh` / `check-wp-noverify.sh` / `update-wp-all.sh`）
- 対象 WordPress ディレクトリへの権限
  - `check-wp.sh` / `check-wp-noverify.sh`: 読み取り権限
  - `update-wp-all.sh`: 更新を行うため書き込み権限
- `check-log-and-file-sakura.sh` は WP-CLI 不要（`gzip` / `find` / `grep` を使用）。さくらインターネットのレンタルサーバーを想定

## 使用方法

### ローカルで実行する場合

```bash
# 監査（改ざん検知あり）
bash check-wp.sh <検索対象のディレクトリ>

# 情報収集のみ（軽量・高速）
bash check-wp-noverify.sh <検索対象のディレクトリ>

# 一括アップデート（サイトを変更します）
bash update-wp-all.sh <検索対象のディレクトリ>
```

#### 実行例

```bash
bash check-wp.sh /path/to/hosting/directory
```

### リモートサーバーで実行する場合

GitHub から直接スクリプトをダウンロードして実行できます:

```bash
# 監査（改ざん検知あり）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-wp.sh | bash -s -- /var/www/html/wordpress

# 情報収集のみ
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-wp-noverify.sh | bash -s -- /var/www/html/wordpress

# 一括アップデート（サイトを変更します）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/update-wp-all.sh | bash -s -- /var/www/html/wordpress
```

## アクセスログの検索（`check-log-and-file-sakura.sh`）

さくらインターネットのレンタルサーバーで、ホームフォルダの `~/log/access_*.gz`（gzip 圧縮されたアクセスログ）から、**過去 N 日分**を対象に指定パターン（既定 `/batch/v1`）を検索します。gz はストリーム解凍するためディスクには展開しません。

- 第1引数: 検索パターン（省略時 `/batch/v1`）
- 第2引数: 対象日数（省略時は端末から対話入力。Enter で 7 日）

対象日数を引数で渡さない場合は `/dev/tty` から対話入力するため、`curl ... | bash` のパイプ実行でもプロンプトを表示できます。

### ローカルで実行する場合

```bash
# 対話入力（日数をプロンプトで指定）
bash check-log-and-file-sakura.sh

# 引数で指定（パターン /batch/v1 を過去7日分から検索）
bash check-log-and-file-sakura.sh /batch/v1 7
```

### curl で実行する場合

```bash
# 対話入力（/dev/tty から日数を読む）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-log-and-file-sakura.sh | bash

# 引数で指定（非対話）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-log-and-file-sakura.sh | bash -s -- /batch/v1 7
```

`bash -s --` の後ろに `<検索パターン> <日数>` を渡します。日数を省略すると対話入力になります（cron 等の端末が無い環境では第2引数での指定が必要です）。

## 出力例

```
--------------------------------------------------
Executing combined commands in /path/to/wordpress
SiteName    : Example Blog
SiteURL     : https://example.com
Version     : 6.4.2
admin_email : admin@example.com
wp db size  : {"database":"wp_example","size":"12 MB"}
folder size : 256M	/path/to/wordpress
Success: WordPress installation verifies against checksums.
Success: All plugin files verify against their checksums.
--------------------------------------------------
```

## エラーハンドリング

- 引数が指定されていない場合、使用方法を表示して終了します:

  ```
  エラー: 対象ディレクトリを引数でセットしてください
  Usage: ./check-wp.sh <search_directory>
  ```

- 指定したディレクトリが存在しない場合もエラーを表示して終了します。

## セキュリティ上の設計

- WP の設定値（`blogname` / `home` など）は改ざんされている可能性がある信頼できない値として扱い、`eval` を使わずに出力しています（コマンドインジェクション対策）。
- 検索対象は絶対パスに変換し、各サイトの処理をサブシェルで実行することで、複数サイト検査時のパス連結ずれを防止しています。

## ライセンス

MIT

## 注意事項

- `check-wp.sh` / `check-wp-noverify.sh` / `check-log-and-file-sakura.sh` は読み取り専用で、WordPress ファイルやデータベース、ログを変更しません。
- **`update-wp-all.sh` はサイトを実際に更新します。** 実行前に必ずバックアップを取得し、検証環境で確認してから本番に適用してください。
- チェックサム検証に失敗した場合は、ファイルが改ざんされている可能性があります。

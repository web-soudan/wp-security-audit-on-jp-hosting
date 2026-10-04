# WordPress Security Audit on JP Hosting

日本のホスティング環境で、指定ディレクトリ配下にある複数の WordPress サイトをまとめて検査・更新するためのシェルスクリプト集です。

## スクリプト一覧

| スクリプト | 目的 | サイトへの変更 |
|---|---|---|
| `check-wp.sh` | 情報収集 **＋ 改ざん検知**（コア/プラグインの整合性検証） | なし（読み取り専用） |
| `check-wp-noverify.sh` | 情報収集のみ（整合性検証を省いた軽量・高速版） | なし（読み取り専用） |
| `check-sc.sh` | SC（自己修復型バックドア）の痕跡を検査（ファイル8層 + DB + 共有メモリ） | なし（読み取り専用） |
| `update-wp-all.sh` | 情報収集 **＋ 一括アップデート**（コア/プラグイン/テーマ/翻訳） | **あり（更新を実行）** |
| `update-minor-wp-all.sh` | 情報収集 **＋ 一括アップデート**（コアは**マイナー更新のみ**、プラグイン/テーマ/翻訳） | **あり（更新を実行）** |
| `check-log-and-file-sakura.sh` | さくら向け: `~/log/access_*.gz` から過去N日分のアクセスログを検索 | なし（読み取り専用） |
| `check-files-by-date-sakura.sh` | さくら向け: 指定した日付範囲に**作成された**ファイルをホーム配下から検索 | なし（読み取り専用） |
| `check-cve-2026-87902-sakura.sh` | さくら向け: アクセスログ（gz + 未圧縮）から CVE-2026-87902（パストラバーサル）の**攻撃試行痕跡**を検索 | なし（読み取り専用） |
| `check-log-and-file-xserver.sh` | エックスサーバー向け: `public_html` を再帰検索して公開フォルダ(ドメイン)を特定し、各ドメインの `log/ドメイン名.access_log_*.gz` から過去N日分のアクセスログを検索 | なし（読み取り専用） |
| `check-cve-2026-87902-xserver.sh` | エックスサーバー向け: 各ドメインのアクセスログ（gz + 未圧縮）から CVE-2026-87902（パストラバーサル）の**攻撃試行痕跡**を検索 | なし（読み取り専用） |

`check-wp.sh` / `check-wp-noverify.sh` / `update-wp-all.sh` / `update-minor-wp-all.sh` は、指定ディレクトリ配下の `wp-config.php` を再帰的に探し、見つかった各 WordPress インストールに対して処理を実行します。
`check-sc.sh` も同じく `wp-config.php` を再帰的に探し、各サイトで SC（自己修復型バックドア）の痕跡を検査します（→ [SC の痕跡を検索](#sc自己修復型バックドアの痕跡を検索-check-scsh)）。
`check-log-and-file-sakura.sh` はさくらインターネットのレンタルサーバーを対象に、ホームフォルダの `~/log/` にある gzip 圧縮アクセスログを検索します（→ [アクセスログの検索](#アクセスログの検索-check-log-and-file-sakurash)）。
`check-files-by-date-sakura.sh` は同じくさくら向けで、ホーム配下（除外フォルダを除く）から作成日時が指定範囲内のファイルを探します（→ [作成日でファイルを検索](#作成日でファイルを検索-check-files-by-date-sakurash)）。
`check-cve-2026-87902-sakura.sh` は同じくさくら向けで、`~/log/` のアクセスログから CVE-2026-87902 を狙った攻撃試行の痕跡を検索します（→ [CVE-2026-87902 の攻撃痕跡を検索](#cve-2026-87902-の攻撃痕跡を検索-check-cve-2026-87902-sakurash)）。
`check-log-and-file-xserver.sh` はエックスサーバーを対象に、ホーム配下から `public_html` を再帰的に探して公開フォルダ(ドメイン)を特定し、各ドメインフォルダの `log/` にある gzip 圧縮アクセスログを検索します（→ [アクセスログの検索（エックスサーバー）](#アクセスログの検索エックスサーバー-check-log-and-file-xserversh)）。
`check-cve-2026-87902-xserver.sh` は同じくエックスサーバー向けで、各ドメインのアクセスログから CVE-2026-87902 を狙った攻撃試行の痕跡を検索します（→ [CVE-2026-87902 の攻撃痕跡を検索（エックスサーバー）](#cve-2026-87902-の攻撃痕跡を検索エックスサーバー-check-cve-2026-87902-xserversh)）。

## 収集する情報（WordPress 検査・更新スクリプト共通）

- サイト名（`blogname`）
- サイトURL（`home`）
- WordPress バージョン
- 管理者メールアドレス（`admin_email`）
- データベースサイズ（`wp db size`）
- フォルダサイズ（`du -sh`）

### `check-wp.sh` が追加で行う検証

- `wp core verify-checksums` — コアファイルの整合性検証
- `wp plugin verify-checksums --all` — 全プラグインファイルの整合性検証

### `update-wp-all.sh` / `update-minor-wp-all.sh` が追加で行う更新

- WordPress コア本体の更新
  - `update-wp-all.sh`: メジャーバージョンを含む最新版まで更新（`wp core update`）
  - `update-minor-wp-all.sh`: 同一メジャーバージョン内のマイナー（セキュリティ）更新のみ（`wp core update --minor`）
- 全プラグインの更新
- 全テーマの更新
- コア/プラグイン/テーマの翻訳（言語パック）の更新

コアのメジャーアップグレードによる互換性リスクを避けたい場合は `update-minor-wp-all.sh` を使用します。2つのスクリプトの違いはコア更新の `--minor` の有無のみで、プラグイン・テーマ・翻訳はどちらも一括更新します。

## 必要要件

- Bash
- WP-CLI がインストールされていること（`check-wp.sh` / `check-wp-noverify.sh` / `update-wp-all.sh` / `update-minor-wp-all.sh`）
- 対象 WordPress ディレクトリへの権限
  - `check-wp.sh` / `check-wp-noverify.sh`: 読み取り権限
  - `update-wp-all.sh` / `update-minor-wp-all.sh`: 更新を行うため書き込み権限
- `check-sc.sh` は WP-CLI が**あれば** DB 側（option / 隠し管理者 / cron / DBトリガー）も確認し、無い場合はファイル側のみ確認（`find` / `grep` を使用。共有メモリの確認には `ipcs` があれば使用）
- `check-log-and-file-sakura.sh` は WP-CLI 不要（`gzip` / `find` / `grep` を使用）。さくらインターネットのレンタルサーバーを想定
- `check-files-by-date-sakura.sh` は WP-CLI 不要。作成日時(birth time)の判定に BSD 系の `find -newerBt` / `stat -f` を使うため、FreeBSD（さくら）・macOS で動作（GNU/Linux は非対応）
- `check-cve-2026-87902-sakura.sh` は WP-CLI 不要（`gzip` / `find` / `grep` を使用）。さくらインターネットのレンタルサーバー（`~/log/` にアクセスログがある構成）を想定
- `check-log-and-file-xserver.sh` は WP-CLI 不要（`gzip` / `find` / `grep` を使用）。エックスサーバーのレンタルサーバーを想定（`~/ドメイン名/public_html` + `~/ドメイン名/log/` の構成）
- `check-cve-2026-87902-xserver.sh` は WP-CLI 不要（`gzip` / `find` / `grep` を使用）。同じくエックスサーバーの構成を想定

## 使用方法

### ローカルで実行する場合

```bash
# 監査（改ざん検知あり）
bash check-wp.sh <検索対象のディレクトリ>

# 情報収集のみ（軽量・高速）
bash check-wp-noverify.sh <検索対象のディレクトリ>

# SC（自己修復型バックドア）の痕跡を検査
bash check-sc.sh <検索対象のディレクトリ>

# 一括アップデート（サイトを変更します）
bash update-wp-all.sh <検索対象のディレクトリ>

# 一括アップデート（コアはマイナー更新のみ。サイトを変更します）
bash update-minor-wp-all.sh <検索対象のディレクトリ>
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

# SC（自己修復型バックドア）の痕跡を検査
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-sc.sh | bash -s -- /var/www/html/wordpress

# 一括アップデート（サイトを変更します）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/update-wp-all.sh | bash -s -- /var/www/html/wordpress

# 一括アップデート（コアはマイナー更新のみ。サイトを変更します）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/update-minor-wp-all.sh | bash -s -- /var/www/html/wordpress
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

## アクセスログの検索（エックスサーバー）（`check-log-and-file-xserver.sh`）

エックスサーバーはドメインごとに `~/ドメイン名/public_html`（公開フォルダ）と `~/ドメイン名/log/ドメイン名.access_log_YYYYMMDD.gz`（ログ）が対になっています（例: `~/eucalyption.me/public_html`, `~/eucalyption.me/log/eucalyption.me.access_log_20260721.gz`）。

このスクリプトはホームフォルダ(`~`)以下を再帰的に検索して `public_html` フォルダ（公開フォルダ）を特定し、対応する各ドメインの `log/ドメイン名.access_log_*.gz` から、**過去 N 日分**を対象に指定パターン（既定 `/batch/v1`）を検索します。複数ドメインが見つかった場合はすべてのドメインのログをまとめて検索します。gz はストリーム解凍するためディスクには展開しません。

- 第1引数: 検索パターン（省略時 `/batch/v1`）
- 第2引数: 対象日数（省略時は端末から対話入力。Enter で 7 日）

対象日数を引数で渡さない場合は `/dev/tty` から対話入力するため、`curl ... | bash` のパイプ実行でもプロンプトを表示できます。

### ローカルで実行する場合

```bash
# 対話入力（日数をプロンプトで指定）
bash check-log-and-file-xserver.sh

# 引数で指定（パターン /batch/v1 を過去7日分から検索）
bash check-log-and-file-xserver.sh /batch/v1 7
```

### curl で実行する場合

```bash
# 対話入力（/dev/tty から日数を読む）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-log-and-file-xserver.sh | bash

# 引数で指定（非対話）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-log-and-file-xserver.sh | bash -s -- /batch/v1 7
```

`bash -s --` の後ろに `<検索パターン> <日数>` を渡します。日数を省略すると対話入力になります（cron 等の端末が無い環境では第2引数での指定が必要です）。

#### 出力例

```
検出した公開フォルダ:
  /home/example/eucalyption.me/public_html  (ドメイン名: eucalyption.me)
--------------------------------------------------
対象期間     : 過去 7 日
対象ファイル : 2 件
  /home/example/eucalyption.me/log/eucalyption.me.access_log_20260720.gz
  /home/example/eucalyption.me/log/eucalyption.me.access_log_20260721.gz
検索パターン : /batch/v1
--------------------------------------------------
203.0.113.10 - - [21/Jul/2026:10:12:33 +0900] "GET /batch/v1 HTTP/1.1" 200 512
--------------------------------------------------
マッチ件数 : 1
```

## CVE-2026-87902 の攻撃痕跡を検索（`check-cve-2026-87902-sakura.sh`）

さくらインターネットのレンタルサーバーで、ホームフォルダの `~/log/` にあるアクセスログから、CVE-2026-87902（WordPress の page-template パストラバーサル）を狙った**攻撃試行の痕跡**を検索します。gz 圧縮ログ（`access_*.gz`）だけでなく**未圧縮のログ**も対象にします（直近の攻撃はまだ圧縮されていない当日ログに残ることが多いため）。gz はストリーム解凍するためディスクには展開しません。

- 第1引数: 検知パターン（`grep -E -i` の拡張正規表現。省略または空文字で既定パターン）
  - 既定パターンは、生・URLエンコード双方のパストラバーサル痕（`../` / `..%2f` / `%2e%2e/` / `..\` など）
- 第2引数: 対象日数（省略時は端末から対話入力。Enter で 14 日）
- 対象ファイルは `find -mtime` で選ぶため、ログのファイル名書式に依存しません。
- `pearcmd` / `php://` / `data://` / `expect://` / `phar://` / `/tmp/` / `/var/tmp/` を含む行は**高シグナル**として `[!]` 付きで強調表示します（LFI→RCE の定番ガジェットや、Web シェルの書き込み先として観測されている場所）。

対象日数を引数で渡さない場合は `/dev/tty` から対話入力するため、`curl ... | bash` のパイプ実行でもプロンプトを表示できます。

> **マッチ＝侵害成立ではありません。** 検出されるのは「攻撃の試行痕跡」です。ヒットしたサイトは要調査（WordPress の更新状況と公開ディレクトリのファイル点検）へ進んでください。
> 逆に、**ヒットが無くても安全の保証にはなりません**（POST 経由・ログ削除済み・対象期間外の可能性）。修正版へ更新済みかを必ず別途確認してください。

### ローカルで実行する場合

```bash
# 対話入力（日数をプロンプトで指定）
bash check-cve-2026-87902-sakura.sh

# 引数で指定（既定パターンを過去14日分から検索）
bash check-cve-2026-87902-sakura.sh "" 14
```

### curl で実行する場合

```bash
# 対話入力（/dev/tty から日数を読む）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-cve-2026-87902-sakura.sh | bash

# 引数で指定（非対話）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-cve-2026-87902-sakura.sh | bash -s -- "" 14
```

第1引数はパターン、第2引数は日数です。日数だけを指定したい場合は、第1引数に空文字 `""` を渡します（cron 等の端末が無い環境では第2引数での指定が必要です）。

#### 出力例

```
対象:       CVE-2026-87902 (WordPress page-template パストラバーサル)
対象期間:   過去 14 日
対象ファイル: 3 件 (gz:2 / 未圧縮:1)
  /home/example/log/access_20260910.gz
  /home/example/log/access_20260911.gz
  /home/example/log/access_log
検知パターン: (\.\.(/|%2f|%5c|\\)|%2e%2e(/|%2f|%5c))
--------------------------------------------------
[!] 203.0.113.10 - - [11/Sep/2026:03:14:22 +0900] "GET /?page_template=../../../../tmp/pearcmd.php HTTP/1.1" 200 1024
    198.51.100.7 - - [11/Sep/2026:04:02:51 +0900] "GET /?page_template=..%2f..%2fwp-config.php HTTP/1.1" 404 512
--------------------------------------------------
トラバーサル痕のヒット件数: 2
うち高シグナル [!] 行:      1  (pearcmd / php:// 等 / tmp書込 を含む)

=> 攻撃の【試行痕跡】が見つかりました。侵害成立の確定ではありません。
```

## CVE-2026-87902 の攻撃痕跡を検索（エックスサーバー）（`check-cve-2026-87902-xserver.sh`）

`check-cve-2026-87902-sakura.sh` のエックスサーバー版です。検知パターン・`[!]` 高シグナル判定・判定メッセージはさくら版と同一で、**ログの探し方だけ**がエックスサーバーの構成に合わせてあります。

ホームフォルダ(`~`)以下から `public_html` を再帰的に探して公開フォルダ(ドメイン)を特定し、各ドメインフォルダの `log/` にある `ドメイン名.access_log_*.gz`（gz）と `ドメイン名.access_log`（未圧縮の当日ログ）の両方を対象に、CVE-2026-87902（WordPress の page-template パストラバーサル）を狙った**攻撃試行の痕跡**を検索します。複数ドメインが見つかった場合はすべてまとめて検索します。gz はストリーム解凍するためディスクには展開しません。

- 第1引数: 検知パターン（`grep -E -i` の拡張正規表現。省略または空文字で既定パターン）
- 第2引数: 対象日数（省略時は端末から対話入力。Enter で 14 日）
- 既定パターン・高シグナル語（`pearcmd` / `php://` / `data://` / `expect://` / `phar://` / `/tmp/` / `/var/tmp/`）はさくら版と同じです（→ [さくら版の説明](#cve-2026-87902-の攻撃痕跡を検索-check-cve-2026-87902-sakurash)）。

> **マッチ＝侵害成立ではありません。** 検出されるのは「攻撃の試行痕跡」です。ヒットしたサイトは要調査（WordPress の更新状況と公開ディレクトリのファイル点検）へ進んでください。
> 逆に、**ヒットが無くても安全の保証にはなりません**（POST 経由・ログ削除済み・対象期間外の可能性）。修正版へ更新済みかを必ず別途確認してください。

### ローカルで実行する場合

```bash
# 対話入力（日数をプロンプトで指定）
bash check-cve-2026-87902-xserver.sh

# 引数で指定（既定パターンを過去14日分から検索）
bash check-cve-2026-87902-xserver.sh "" 14
```

### curl で実行する場合

```bash
# 対話入力（/dev/tty から日数を読む）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-cve-2026-87902-xserver.sh | bash

# 引数で指定（非対話）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-cve-2026-87902-xserver.sh | bash -s -- "" 14
```

#### 出力例

```
検出した公開フォルダ:
  /home/example/eucalyption.me/public_html  (ドメイン名: eucalyption.me)
  /home/example/example.com/public_html  (ドメイン名: example.com)
--------------------------------------------------
対象:       CVE-2026-87902 (WordPress page-template パストラバーサル)
対象期間:   過去 14 日
対象ファイル: 3 件 (gz:1 / 未圧縮:2)
  /home/example/eucalyption.me/log/eucalyption.me.access_log_20260920.gz
  /home/example/eucalyption.me/log/eucalyption.me.access_log
  /home/example/example.com/log/example.com.access_log
検知パターン: (\.\.(/|%2f|%5c|\\)|%2e%2e(/|%2f|%5c))
--------------------------------------------------
[!] 203.0.113.10 - - [11/Sep/2026:03:14:22 +0900] "GET /?page_template=../../../../tmp/pearcmd.php HTTP/1.1" 200 1024
    198.51.100.7 - - [11/Sep/2026:04:02:51 +0900] "GET /?page_template=..%2F..%2Fwp-config.php HTTP/1.1" 404 512
--------------------------------------------------
トラバーサル痕のヒット件数: 2
うち高シグナル [!] 行:      1  (pearcmd / php:// 等 / tmp書込 を含む)

=> 攻撃の【試行痕跡】が見つかりました。侵害成立の確定ではありません。
```

## SC（自己修復型バックドア）の痕跡を検索（`check-sc.sh`）

指定ディレクトリ配下の `wp-config.php` を再帰的に探し、見つかった各 WordPress に対して SC バックドアの痕跡を検査します。**読み取り専用**で、検出と報告のみを行います（マルウェアの削除や修正はしません）。

- 参考: [The Hacker News の記事](https://thehackernews.com/2026/10/wordpress-backdoor-rebuilds-itself.html) / [Sucuri の分析](https://blog.sucuri.net/2026/09/sc-wordpress-malware-a-self-healing-mesh-of-loaders-drop-ins-and-a-blockchain-controlled-backdoor.html)
- 第1引数: 検索対象ディレクトリ（必須）
- 最後に、検査したサイトを**サイト別の検出件数つきで一覧表示**します。複数サイトを再帰検査したときに、どのサイトに痕跡があったのかを出力を遡らずに確認できます。

SC は単体のマルウェアファイルではなく、**複数の層が互いを再生成し合う構成**です。プラグインを消せばドロップインが書き戻し、ドロップインを消せばテーマが書き戻し、ディスク上を全部消しても次のアクセスで DB や共有メモリから一式が復元されます。そのため「1箇所を見つけて消す」のではなく、**痕跡の分布を一度に洗い出す**ことが初動になります。

| # | チェック項目 | 位置づけ |
|---|---|---|
| 0 | SysV 共有メモリ（`ipcs -m`） | RAM 常駐。ファイル削除・DB 掃除でも消えない層 |
| 1 | `.user.ini` / `php.ini` / `.htaccess` の `auto_prepend_file` | 全リクエストの最上流。除去も最初にここから |
| 2 | ドロップイン `db.php` / `advanced-cache.php` / `object-cache.php` | WP 本体が自動で読み込む常駐先 |
| 3 | `wp-content` 直下のランダム hex 名 PHP / ドットで始まる隠しPHP | `c1b12371.php` / `.c1b12371.php` 型のローダー |
| 4 | `wp-content/mu-plugins` の PHP | 管理画面から無効化できない常駐先 |
| 5 | ランダム hex 名の ZIP | ファイル一括削除後の復元元 |
| 6 | PHP 内のシグネチャ（自己修復系 / 難読化系 / SC マーカー・Ethereum RPC） | C2 は公開 Ethereum RPC 経由 |
| 7 | DB（巨大 option / Base64 のみの option / `sc_` 系 option / DBトリガー / 管理者一覧 / ランダム風 cron） | WP-CLI がある場合のみ |

### WP-CLI の扱い

- WP-CLI があれば DB 側も確認し、無ければファイル側だけを確認します（その旨を冒頭に表示）。
- WP-CLI は `--skip-plugins --skip-themes` 付きで実行します。SC 自身がプラグインとして動作し、一覧や結果をフィルタで隠すためです。
- DB に接続できない場合は「未確認」と明示します（「該当なし」とは区別。未確認を安全と誤解しないため）。

### 誤検知・見逃しについて

- ドロップイン（`db.php` 等）はキャッシュ系・DB 系プラグインが正規に作る場合があります。検出時はファイル内のシグネチャ有無も併記します。
- `vendor` / `node_modules` / `tests` 配下と開発ツールの定番ドットファイル（`.phpstorm.meta.php` 等）は、本体の検出とは分けて**参考表示**にします。PHPUnit などが `shmop_open` や `auto_prepend_file` を文字列として列挙しているためです（除外ではなく分離。そこへの改ざんも有り得るため）。
- ファイル名・option 名・cron フック名はサイト毎にランダム化されるため、**未検出＝安全の保証にはなりません**。

### ローカルで実行する場合

```bash
bash check-sc.sh /home/example/public_html
```

### curl で実行する場合

```bash
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-sc.sh | bash -s -- /home/example/public_html
```

#### 出力例（痕跡が見つかった場合の抜粋）

```
[1] auto_prepend_file（.user.ini / php.ini / .htaccess）
[!] auto_prepend_file の指定を含む設定ファイルがあります（SC の最上流の仕掛け）
      /home/example/public_html/.user.ini
      /home/example/public_html/.user.ini:1:auto_prepend_file="/home/example/public_html/wp-content/.c1b12371.php"

[2] ドロップイン（db.php / advanced-cache.php / object-cache.php）
[!] /home/example/public_html/wp-content/db.php が存在します（キャッシュ/DB系プラグインが正規に作る場合もあり）
[!]   └ 上記ファイルに難読化/自己修復系のパターンを検出 → 感染濃厚
--------------------------------------------------
検査したサイト: 3 件
  [ ]    0 件  /home/example/clean.example.com/public_html
  [!]   10 件  /home/example/public_html
  [ ]    0 件  /home/example/sub.example.com/public_html

要調査として検出した項目: 10 件（痕跡のあったサイト: 1 / 3）

=> SC で使われる配置と一致する項目が見つかりました。要調査です。
```

#### 検出時の除去順序

SC は相互に再生成し合うため、**1箇所ずつ消すと必ず復活します**。Sucuri が示す順序を崩さずに進めてください（スクリプトの最後にも表示されます）。

1. `auto_prepend_file`（`.user.ini` 等）を先に無効化する
2. ディスク外のコピーを消す（option のペイロード・共有メモリ・制御 option）
3. cron イベントと DB トリガーを削除する
4. 隠し管理者アカウントを削除する
5. ファイルを“一度に”消す（ローダー・シム・両方のプラグイン・ZIP・ドロップイン）
6. 再スキャンし、ファイルが再生成されないか監視する

並行して、認証情報（DB・管理者・API キー）のローテーションも必要です。

## 作成日でファイルを検索（`check-files-by-date-sakura.sh`）

さくらインターネットのレンタルサーバーではドキュメントルートを自由な名前で作成できるため、**ホーム配下（`$HOME`）を丸ごと走査**し、除外フォルダ（既定は `~/log`）以外から、**指定した日付範囲に作成されたファイル**を列挙します。新規アップロードされた不審ファイルの発見を想定しています。

- 「作成」の判定はファイルの **birth time（作成日時）**。`touch` で改ざんしにくく、`mtime`（更新日時）より「いつ作られたか」の判断に適します。
- 除外フォルダはスクリプト内の `excludes` 配列で管理します（既定 `~/log`。`~/.ssh` 等を追記して拡張可）。
- 第1引数: 開始日（`YYYY-MM-DD`）
- 第2引数: 終了日（`YYYY-MM-DD`）
- 日付を引数で渡さない場合は `/dev/tty` から対話入力するため、`curl ... | bash` でもプロンプトを表示できます。

範囲は「開始日 00:00:00 〜 終了日 23:59:59」で、両端の日を含みます。

### ローカルで実行する場合

```bash
# 対話入力（開始日・終了日をプロンプトで指定）
bash check-files-by-date-sakura.sh

# 引数で指定（2026-07-01〜2026-07-08 に作成されたファイル）
bash check-files-by-date-sakura.sh 2026-07-01 2026-07-08
```

### curl で実行する場合

```bash
# 対話入力（/dev/tty から日付を読む）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-files-by-date-sakura.sh | bash

# 引数で指定（非対話）
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-files-by-date-sakura.sh | bash -s -- 2026-07-01 2026-07-08
```

#### 出力例

```
走査対象     : /home/example
除外フォルダ : /home/example/log
作成日時範囲 : 2026-07-01 00:00:00 〜 2026-07-08 23:59:59
--------------------------------------------------
2026-07-03 14:22:10  /home/example/www/wp-content/uploads/2026/07/shell.php
2026-07-05 09:01:44  /home/example/mydocroot/upload.php
--------------------------------------------------
該当件数 : 2
```

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

- `check-wp.sh` / `check-wp-noverify.sh` / `check-log-and-file-sakura.sh` / `check-files-by-date-sakura.sh` / `check-log-and-file-xserver.sh` / `check-cve-2026-87902-sakura.sh` / `check-cve-2026-87902-xserver.sh` / `check-sc.sh` は読み取り専用で、WordPress ファイルやデータベース、ログを変更しません。
- **`update-wp-all.sh` / `update-minor-wp-all.sh` はサイトを実際に更新します。** 実行前に必ずバックアップを取得し、検証環境で確認してから本番に適用してください。
- チェックサム検証に失敗した場合は、ファイルが改ざんされている可能性があります。

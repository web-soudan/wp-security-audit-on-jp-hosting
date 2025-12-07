# WordPress Security Audit on JP Hosting

日本のホスティング環境で複数のWordPressサイトのセキュリティ監査を一括で実行するためのシェルスクリプトです。

## 概要

このツールは、指定されたディレクトリ配下にある全てのWordPressインストールを検索し、以下の情報を取得・検証します:

- サイトURL
- WordPressバージョン
- 管理者メールアドレス
- コアファイルの整合性検証
- プラグインファイルの整合性検証

## 必要要件

- Bash
- WP-CLI がインストールされていること
- 対象WordPressディレクトリへの読み取り権限

## 使用方法

### ローカルで実行する場合

```bash
bash check-wp.sh <検索対象のディレクトリ>
```

#### 実行例

```bash
bash check-wp.sh /path/to/hosting/directory
```

### リモートサーバーで実行する場合

GitHubから直接スクリプトをダウンロードして実行することができます:

```bash
# WordPressのパスを指定する場合
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-wp.sh | bash -s -- /var/www/html/wordpress

# 複数の引数を渡す場合
curl -s https://raw.githubusercontent.com/web-soudan/wp-security-audit-on-jp-hosting/refs/heads/main/check-wp.sh | bash -s -- /path/to/wp --verbose --debug
```

## 実行内容

スクリプトは以下の処理を実行します:

1. 指定されたディレクトリ配下で `wp-config.php` ファイルを再帰的に検索
2. 見つかった各WordPressインストールに対して以下のコマンドを実行:
   - `wp option get home` - サイトURLの取得
   - `wp core version` - WordPressバージョンの取得
   - `wp option get admin_email` - 管理者メールアドレスの取得
   - `wp core verify-checksums` - コアファイルの整合性検証
   - `wp plugin verify-checksums --all` - 全プラグインの整合性検証

## 出力例

```
--------------------------------------------------
Executing combined commands in /path/to/wordpress
SiteURL : https://example.com
Version : 6.4.2
admin_email : admin@example.com
Success: WordPress installation verifies against checksums.
Success: All plugin files verify against their checksums.
--------------------------------------------------
```

## エラーハンドリング

引数が指定されていない場合、使用方法が表示されます:

```
エラー: 対象ディレクトリを引数でセットしてください
Usage: ./check-wp.sh <search_directory>
```

## ライセンス

MIT

## 注意事項

- このスクリプトは読み取り専用の操作のみを行います
- WordPressファイルやデータベースを変更することはありません
- チェックサム検証に失敗した場合は、ファイルが改ざんされている可能性があります

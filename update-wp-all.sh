# 検索対象のディレクトリをセット
search_dir="$1"

# 引数が渡されていない場合はエラーメッセージを表示して終了
if [ -z "$search_dir" ]; then
    echo "エラー: 対象ディレクトリを引数でセットしてください"
    echo "curl xxxxx -s /example.com/public_html"
    echo "Usage: $0 <search_directory>"
    exit 1
fi

# 相対パスで渡されても cd の副作用を受けないよう絶対パスに変換
if [ ! -d "$search_dir" ]; then
    echo "エラー: ディレクトリが存在しません: $search_dir"
    exit 1
fi
search_dir=$(cd "$search_dir" && pwd)


# 実行するWPコマンドを関数化
execute_wp_commands() {
    local wp_dir=$1

    # eval は使わない。WP の option 値（blogname/home 等）は改ざんされ得る
    # 信頼できない値なので、eval で再解釈するとコマンドインジェクションになる。
    # $(...) の出力は echo の引数になるだけで再解釈されないため安全。
    echo --------------------------------------------------
    echo "Executing combined commands in $wp_dir"
    echo "SiteName    : $(wp option get blogname    --path="$wp_dir")"
    echo "SiteURL     : $(wp option get home        --path="$wp_dir")"
    echo "Version     : $(wp core version           --path="$wp_dir")"
    echo "admin_email : $(wp option get admin_email --path="$wp_dir")"
    echo "wp db size  : $(wp db size --format=json   --path="$wp_dir")"
    echo "folder size : $(du -sh "$wp_dir")"

    # Update All
    wp core update --path="$wp_dir"
    wp plugin update --all --path="$wp_dir"
    wp theme update --all --path="$wp_dir"
    wp language core update --path="$wp_dir"
    wp language plugin update --all --path="$wp_dir"
    wp language theme update --all --path="$wp_dir"
    echo --------------------------------------------------
}

# 再帰的にwp-config.phpが存在するディレクトリを検索
find "$search_dir" -type f -name "wp-config.php" | while IFS= read -r wp_config; do
    # search_dir が絶対パスなので find の結果も絶対パス → dirname も絶対パス
    wp_dir=$(dirname "$wp_config")

    # cd の副作用がループに残らないようサブシェルで実行
    ( execute_wp_commands "$wp_dir" )
done

# 検索対象のディレクトリをセット
search_dir="$1"

# 引数が渡されていない場合はエラーメッセージを表示して終了
if [ -z "$search_dir" ]; then
    echo "エラー: 対象ディレクトリを引数でセットしてください"
	echo "curl xxxxx -s /example.com/public_html"
    echo "Usage: $0 <search_directory>"
    exit 1
fi


# 実行するWPコマンドを関数化
execute_wp_commands() {
    local wp_dir=$1

    # 実行するコマンドのリストを配列で設定
    wp_commands=(
		"echo SiteURL : $(wp option get home --path=$wp_dir)"
		"echo Version : $(wp core version --path=$wp_dir)"
#		"wp core verify-checksums"
#		"wp plugin verify-checksums --all"
        "find $wp_dir/wp-content/uploads/ -name \"*.php\""
    )

    # コマンドをまとめて1つのシェルコマンドにする
    combined_command=""
    for wp_command in "${wp_commands[@]}"; do
        combined_command+="$wp_command && "
    done

    # 最後の '&&' を取り除く
    combined_command=${combined_command%&& }

    # wp-config.phpが存在するディレクトリに移動
    cd "$wp_dir"

    # すべてのコマンドをまとめて実行
	echo --------------------------------------------------
	echo "Executing combined commands in $wp_dir"
	eval "$combined_command"
	echo --------------------------------------------------
}

# 再帰的にwp-config.phpが存在するディレクトリを検索
find "$search_dir" -type f -name "wp-config.php" | while read wp_config; do
    # wp-config.phpが存在するディレクトリを取得
    wp_dir=$(dirname "$wp_config")

    # WPコマンドを実行する関数を呼び出し
    execute_wp_commands "$wp_dir"
done

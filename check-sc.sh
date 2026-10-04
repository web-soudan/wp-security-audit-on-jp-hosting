#!/usr/bin/env bash
# SC（自己修復型 WordPress バックドア）の被害チェックスクリプト
#
# 参考記事:
#   https://thehackernews.com/2026/10/wordpress-backdoor-rebuilds-itself.html
#   https://blog.sucuri.net/2026/09/sc-wordpress-malware-a-self-healing-mesh-of-loaders-drop-ins-and-a-blockchain-controlled-backdoor.html
#
# SC は「1ファイルのマルウェア」ではなく、.user.ini の auto_prepend_file /
# ドロップイン(db.php, advanced-cache.php) / MUプラグイン / 通常プラグイン /
# テーマ functions.php / DB の option / SysV 共有メモリ / cron / DBトリガー が
# 互いを再生成し合う“面”として居座る。1箇所消しても次のアクセスで復活するため、
# 「どこに痕跡があるか」を一度に洗い出すことが初動として重要になる。
#
# このスクリプトは【読み取り専用】で、検出・報告のみを行う。
# ファイル・データベース・cron を変更したり、マルウェアを削除したりはしない。
#
# ※ 検出＝感染確定ではない（db.php 等はキャッシュ系プラグインが正規に作る）。
#    逆に未検出＝安全の保証でもない（名称はサイト毎にランダム化される）。
#
# 実行例:
#   ./check-sc.sh /home/example/public_html
#   curl -s <URL> | bash -s -- /home/example/public_html

set -u

# 検索対象のディレクトリをセット
search_dir="${1:-}"

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

# WP-CLI があれば DB 側（option / ユーザー / cron / トリガー）も確認する。
# 無ければファイル側だけを確認する。
has_wp=0
command -v wp >/dev/null 2>&1 && has_wp=1

# --- 検出パターン ------------------------------------------------------
# 1) 自己修復・隠蔽の中核。共有メモリ(shmop/ftok)と auto_prepend_file は
#    正規のテーマ・プラグインではまず使われないため信頼度が高い。
sig_persist='(shmop_open|shmop_read|shmop_write|ftok[[:space:]]*\(|auto_prepend_file)'
# 2) 難読化してその場で実行する定番形。
sig_obfus='(eval[[:space:]]*\([[:space:]]*(gzinflate|gzuncompress|base64_decode|str_rot13)|(gzinflate|gzuncompress)[[:space:]]*\([[:space:]]*base64_decode|create_function[[:space:]]*\(|assert[[:space:]]*\([[:space:]]*base64_decode)'
# 3) SC マーカーと、C2 に使われる Ethereum RPC ゲートウェイ。
sig_marker='(SC_[A-Za-z0-9_]{2,}|eth_call|eth_blockNumber|eth_getBalance|rpc\.ankr\.com|cloudflare-eth\.com|publicnode\.com|llamarpc\.com|infura\.io|drpc\.org|blockpi\.network|1rpc\.io|merkle\.io|rpc\.flashbots\.net)'

# 検出件数（[!] 行の数）
findings=0

# サイト別の結果（"件数 パス" の形で溜め、最後に一覧表示する）。
# 件数に空白は入らないので、最初の空白までを件数、残りをパスとして扱える
# （パス側に空白が含まれていても壊れない）。
site_results=()

hr() { echo "--------------------------------------------------"; }

# 要調査として表示（件数をカウント）
warn() {
    echo "[!] $*"
    findings=$(( findings + 1 ))
}

# 参考情報として表示（カウントしない）
info() {
    echo "[i] $*"
}

# 検出結果リストを表示する（第2引数で表示件数の上限。既定20件）
print_list() {
    local list="$1" limit="${2:-20}"
    [ -z "$list" ] && return 0
    local n
    n=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
    printf '%s\n' "$list" | head -"$limit" | sed 's/^/      /'
    [ "$n" -gt "$limit" ] && echo "      ... 他 $(( n - limit )) 件"
    return 0
}

# vendor / node_modules / tests 配下は、PHPUnit 等が shmop_open や
# auto_prepend_file を「文字列として列挙しているだけ」の誤検知が大半を占める。
# 除外せず、本体の検出とは分けて参考表示にする（そこに置かれる改ざんも在り得るため）。
dev_path_re='/(vendor|node_modules|[Tt]ests?)/'

# 開発ツールが置く定番のドット始まり PHP（.phpstorm.meta.php 等）も同様に参考扱い。
dev_file_re='/\.(phpstorm\.meta|php-cs-fixer(\.dist)?|php_cs(\.dist)?|phpunit(\.dist)?|phpstan(\.dist)?)\.php$'

# 検出パス一覧を、本体 / 開発用ライブラリ配下に分けて報告する
report_paths() {
    local label="$1" list="$2" main dev n
    if [ -z "$list" ]; then
        info "$label: 該当なし"
        return 0
    fi
    main=$(printf '%s\n' "$list" | grep -v -E -- "$dev_path_re" | grep -v -E -- "$dev_file_re")
    dev=$(printf '%s\n' "$list" | grep -E -- "$dev_path_re|$dev_file_re")
    if [ -n "$main" ]; then
        warn "$label"
        print_list "$main"
    else
        info "$label: 該当なし（本体）"
    fi
    if [ -n "$dev" ]; then
        n=$(printf '%s\n' "$dev" | wc -l | tr -d ' ')
        info "  └ 開発用ライブラリ/ツール配下に $n 件（PHPUnit の関数名列挙や CS Fixer の設定ファイル等、誤検知が大半）"
        print_list "$dev" 5
    fi
    return 0
}

# PHPファイルを対象にパターン検索し、該当ファイル一覧を返す。
# 2MB 超のファイルは正規のライブラリが大半なので除外して時間を抑える。
grep_php() {
    local dir="$1" pattern="$2"
    find "$dir" -type f -name '*.php' -size -2000k -print0 2>/dev/null |
        xargs -0 grep -l -E -I -- "$pattern" 2>/dev/null | sort
}

# --- 1サイト分のチェック -----------------------------------------------
check_site() {
    local wp_dir="$1"
    local content_dir="$wp_dir/wp-content"
    local list
    local db_ok=0
    # このサイトだけの検出件数を出すため、開始時点の累計を控えておく
    local before_findings=$findings

    hr
    echo "WordPress   : $wp_dir"
    # DB に繋がらないまま DB 側チェックを走らせると、全て「該当なし」に見えて
    # 未確認が安全と誤解されるため、先に疎通を確かめて db_ok で分岐する。
    # --skip-plugins / --skip-themes を付けるのは、マルウェア自身がプラグインとして
    # 動いて一覧や結果を隠す（フィルタで差し替える）のを防ぐため。
    if [ "$has_wp" -eq 1 ] &&
        [ "$(wp eval 'echo "OK";' --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)" = "OK" ]; then
        db_ok=1
        # 改ざんされ得る option 値は eval せず echo の引数として扱う。
        echo "SiteURL     : $(wp option get home --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)"
        echo "Version     : $(wp core version --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)"
    fi

    # --- (1) auto_prepend_file ------------------------------------------
    # 全PHPリクエストの前に読み込ませる最上流の仕掛け。除去は「最初」に無効化する。
    echo
    echo "[1] auto_prepend_file（.user.ini / php.ini / .htaccess）"
    list=$(find "$wp_dir" -maxdepth 3 -type f \( -name '.user.ini' -o -name 'php.ini' -o -name '.htaccess' \) -print0 2>/dev/null |
        xargs -0 grep -l -i -- 'auto_prepend_file' 2>/dev/null | sort)
    if [ -n "$list" ]; then
        warn "auto_prepend_file の指定を含む設定ファイルがあります（SC の最上流の仕掛け）"
        print_list "$list"
        printf '%s\n' "$list" | while IFS= read -r f; do
            grep -n -i -- 'auto_prepend_file' "$f" 2>/dev/null | sed "s|^|      ${f}:|"
        done
    else
        info "該当なし"
    fi

    # --- (2) ドロップイン ------------------------------------------------
    # wp-content 直下に置くだけで WP 本体が読み込むファイル。SC の常駐先。
    echo
    echo "[2] ドロップイン（db.php / advanced-cache.php / object-cache.php）"
    local d found_dropin=0
    for d in db.php advanced-cache.php object-cache.php; do
        if [ -f "$content_dir/$d" ]; then
            found_dropin=1
            warn "$content_dir/$d が存在します（キャッシュ/DB系プラグインが正規に作る場合もあり）"
            ls -l "$content_dir/$d" | sed 's/^/      /'
            if grep -l -E -I -- "$sig_persist|$sig_obfus|$sig_marker" "$content_dir/$d" >/dev/null 2>&1; then
                warn "  └ 上記ファイルに難読化/自己修復系のパターンを検出 → 感染濃厚"
            fi
        fi
    done
    [ "$found_dropin" -eq 0 ] && info "該当なし"

    # --- (3) wp-content 直下のランダム hex 名 PHP / 隠しPHP ---------------
    # 例: wp-content/c1b12371.php と wp-content/.c1b12371.php（名称はサイト毎に可変）
    echo
    echo "[3] ランダム hex 名の PHP / ドットで始まる隠しPHP"
    # find の -name は先頭ドットのファイルにもマッチするので、.c1b12371.php も拾える。
    list=$(find "$content_dir" -maxdepth 1 -type f -name '*.php' 2>/dev/null |
        grep -E '/\.?[0-9a-f]{6,16}\.php$' | sort)
    if [ -n "$list" ]; then
        warn "wp-content 直下にランダム hex 名の PHP があります（SC のローダー/シムの典型）"
        print_list "$list"
    else
        info "ランダム hex 名 PHP: 該当なし"
    fi

    report_paths "ドットで始まる隠しPHP（第1段ローダーの典型）" \
        "$(find "$wp_dir" -type f -name '.*.php' 2>/dev/null | sort)"

    # --- (4) MUプラグイン ------------------------------------------------
    # mu-plugins は管理画面で無効化できず、通常は空。例: hyper-engine-kit.php
    echo
    echo "[4] MUプラグイン（wp-content/mu-plugins）"
    if [ -d "$content_dir/mu-plugins" ]; then
        list=$(find "$content_dir/mu-plugins" -type f -name '*.php' 2>/dev/null | sort)
        if [ -n "$list" ]; then
            warn "mu-plugins に PHP があります（導入に心当たりが無ければ要調査）"
            print_list "$list"
        else
            info "mu-plugins は空"
        fi
    else
        info "mu-plugins ディレクトリなし"
    fi

    # --- (5) ランダム hex 名の ZIP（復元用バンドル）------------------------
    echo
    echo "[5] ランダム hex 名の ZIP（自己復元用バンドル）"
    report_paths "ランダム hex 名の ZIP（ファイル一括削除後の復元元）" \
        "$(find "$content_dir" "$content_dir/uploads" "$content_dir/themes" -type f -name '*.zip' 2>/dev/null |
            grep -E '/[0-9a-f]{6,32}\.zip$' | sort -u)"

    # --- (6) PHP ファイルのシグネチャ検索 ---------------------------------
    echo
    echo "[6] PHP ファイル内のシグネチャ検索（時間がかかる場合があります）"
    report_paths "自己修復・隠蔽系（shmop / ftok / auto_prepend_file）を含む PHP" "$(grep_php "$wp_dir" "$sig_persist")"
    report_paths "難読化実行系（eval + base64/gzinflate 等）を含む PHP" "$(grep_php "$wp_dir" "$sig_obfus")"
    report_paths "SC マーカー / Ethereum RPC（C2 の通信先）を含む PHP" "$(grep_php "$wp_dir" "$sig_marker")"

    # --- (7) データベース側（WP-CLI がある場合のみ）------------------------
    echo
    echo "[7] データベース（option / 管理者 / cron / トリガー）"
    if [ "$has_wp" -eq 0 ]; then
        info "WP-CLI が無いためスキップ（option・隠し管理者・cron・DBトリガーは未確認）"
    elif [ "$db_ok" -eq 0 ]; then
        info "WP-CLI で DB に接続できないためスキップ（option・隠し管理者・cron・DBトリガーは未確認）"
    else
        local out

        # 巨大な option は gzip+base64 のペイロード本体が入り込む場所。
        out=$(wp eval 'global $wpdb; $rows = $wpdb->get_results("SELECT option_name, LENGTH(option_value) AS len FROM {$wpdb->options} ORDER BY len DESC LIMIT 10"); foreach ($rows as $r) { printf("%12s bytes  %s\n", number_format($r->len), $r->option_name); }' \
            --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)
        if [ -n "$out" ]; then
            echo "  - option の値が大きい上位10件:"
            printf '%s\n' "$out" | sed 's/^/      /'
        fi

        # 1000バイト超で中身が Base64 だけの option はペイロード格納の典型。
        out=$(wp eval 'global $wpdb; $rows = $wpdb->get_results("SELECT option_name, LENGTH(option_value) AS len, LEFT(option_value, 160) AS head FROM {$wpdb->options} WHERE LENGTH(option_value) > 1000"); foreach ($rows as $r) { if (preg_match("#^[A-Za-z0-9+/=]{120,}#", $r->head)) { printf("%12s bytes  %s\n", number_format($r->len), $r->option_name); } }' \
            --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)
        if [ -n "$out" ]; then
            warn "中身が Base64 のみの巨大 option があります（ペイロード格納の典型）"
            printf '%s\n' "$out" | sed 's/^/      /'
        else
            info "Base64 のみの巨大 option: 該当なし"
        fi

        # sc_ 系の option / transient（制御フラグ・再生成タイマー）
        out=$(wp eval 'global $wpdb; $rows = $wpdb->get_col("SELECT option_name FROM {$wpdb->options}"); foreach ($rows as $name) { if (preg_match("#(^|_)sc_#i", $name)) { echo $name . "\n"; } }' \
            --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)
        if [ -n "$out" ]; then
            warn "sc_ を含む option / transient があります（SC の制御フラグの可能性）"
            print_list "$out"
        else
            info "sc_ を含む option: 該当なし"
        fi

        # DBトリガーは素の WordPress では 0 件。あれば管理者アカウント再生成等を疑う。
        out=$(wp eval 'global $wpdb; $rows = $wpdb->get_results("SHOW TRIGGERS", ARRAY_A); foreach ($rows as $r) { echo implode("  ", array($r["Trigger"], $r["Event"], $r["Table"])) . "\n"; }' \
            --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)
        if [ -n "$out" ]; then
            warn "DB トリガーがあります（削除した管理者を再生成する仕掛けの可能性）"
            print_list "$out"
        else
            info "DB トリガー: 0 件"
        fi

        # 隠し管理者。--skip-plugins で一覧を隠すフィルタを回避して取得する。
        out=$(wp user list --role=administrator --fields=ID,user_login,user_email,user_registered \
            --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)
        if [ -n "$out" ]; then
            echo "  - 管理者アカウント一覧（身に覚えのないものが無いか確認）:"
            printf '%s\n' "$out" | sed 's/^/      /'
        fi

        # ランダム風の cron フック（アンダースコアを含まない長い英数字）
        out=$(wp cron event list --fields=hook,next_run_relative --format=csv \
            --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null |
            tail -n +2 | grep -E '^[a-z0-9]{10,},' | sort -u)
        if [ -n "$out" ]; then
            warn "ランダム風の cron フックがあります（再配備タイマーの可能性）"
            print_list "$out"
        else
            info "ランダム風 cron フック: 該当なし"
        fi
    fi

    site_results+=("$(( findings - before_findings )) $wp_dir")
    hr
}

# --- 対象サイトの収集 ---------------------------------------------------
# 再帰的に wp-config.php が存在するディレクトリを検索する。
# パイプの while だと検出件数が子シェルに閉じるため、配列に集めてから回す。
wp_dirs=()
while IFS= read -r wp_config; do
    wp_dirs+=("$(dirname "$wp_config")")
done < <(find "$search_dir" -type f -name 'wp-config.php' 2>/dev/null | sort)

if [ "${#wp_dirs[@]}" -eq 0 ]; then
    echo "エラー: $search_dir 以下に wp-config.php が見つかりません" >&2
    exit 1
fi

echo "対象:       SC（自己修復型 WordPress バックドア）の痕跡"
echo "走査対象:   $search_dir"
echo "対象サイト: ${#wp_dirs[@]} 件"
if [ "$has_wp" -eq 0 ]; then
    echo "WP-CLI:     未検出（ファイル側のみ確認します）"
else
    echo "WP-CLI:     検出（DB 側も確認します）"
fi

# --- SysV 共有メモリ（サイト横断で1回だけ）------------------------------
# SC は固定キーの共有メモリにペイロードを置く。RAM 上なのでファイル削除でも
# DB 掃除でも消えず、次のアクセスで一式を書き戻す。
hr
echo "[0] SysV 共有メモリセグメント（ipcs -m）"
if command -v ipcs >/dev/null 2>&1; then
    shm=$(ipcs -m 2>/dev/null | sed '/^$/d')
    if [ -n "$shm" ]; then
        printf '%s\n' "$shm" | head -30 | sed 's/^/      /'
        info "セグメントが存在する場合、キーと所有者を確認してください（共有ホスティングでは別アカウント所有のこともあります）"
    else
        info "セグメントなし"
    fi
else
    info "ipcs コマンドが無いため未確認"
fi

for wp_dir in "${wp_dirs[@]}"; do
    check_site "$wp_dir"
done

# --- 検査したサイトの一覧 -----------------------------------------------
# 再帰検索で複数サイトが対象になった場合、どのサイトに痕跡があったのかを
# 最後にまとめて示す（スクロールを遡らずに済むように）。
sites_hit=0
echo "検査したサイト: ${#site_results[@]} 件"
for r in "${site_results[@]}"; do
    n="${r%% *}"
    d="${r#* }"
    if [ "$n" -gt 0 ]; then
        printf '  [!] %4s 件  %s\n' "$n" "$d"
        sites_hit=$(( sites_hit + 1 ))
    else
        printf '  [ ] %4s 件  %s\n' "$n" "$d"
    fi
done
echo
echo "要調査として検出した項目: $findings 件（痕跡のあったサイト: ${sites_hit} / ${#site_results[@]}）"
echo

# --- 判定メッセージ ----------------------------------------------------
if [ "$findings" -eq 0 ]; then
    echo "=> SC の典型的な痕跡は見つかりませんでした。"
    echo "   ただし安全の保証ではありません（ファイル名・option 名・cron 名は"
    echo "   サイト毎にランダム化されるため、未知の配置は検出できません）。"
    echo "   WordPress 本体・プラグイン・テーマを最新に保ち、管理画面のプラグイン"
    echo "   一覧と \`wp plugin list\` の差分（管理画面から隠された分）も確認を。"
else
    echo "=> SC で使われる配置と一致する項目が見つかりました。要調査です。"
    echo "   【重要】SC は相互に再生成し合うため、1箇所ずつ消すと必ず復活します。"
    echo "   Sucuri が示す除去順序（この順番を崩さないこと）:"
    echo "     1. auto_prepend_file（.user.ini 等）を先に無効化する"
    echo "     2. ディスク外のコピーを消す（option のペイロード・共有メモリ・制御 option）"
    echo "     3. cron イベントと DB トリガーを削除する"
    echo "     4. 隠し管理者アカウントを削除する"
    echo "     5. ファイルを“一度に”消す（ローダー・シム・両方のプラグイン・ZIP・ドロップイン）"
    echo "     6. 再スキャンし、ファイルが再生成されないか監視する"
    echo "   並行して、認証情報（DB・管理者・API キー）のローテーションも必要です。"
fi

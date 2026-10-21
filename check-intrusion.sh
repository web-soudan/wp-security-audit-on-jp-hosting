#!/usr/bin/env bash
# レンタルサーバー上の WordPress 侵害チェック（一次トリアージ）
#
# きっかけ: PHP エンジン本体の認証不要 RCE
#   CVE-2026-109618 / CVE-2026-109619
#   https://github.com/ikow/php2shell-poc
#   影響: PHP 5.4.0 〜 8.5.11 / 修正版: 8.2.35, 8.3.36, 8.4.27, 8.5.12
#   session.upload_progress（multipart の PHP_SESSION_UPLOAD_PROGRESS）が侵入口。
#   アプリ側の脆弱性が無くても成立するため、WordPress を最新にしても塞がらない。
#
# そのため「PHP が修正版か」と「既にやられていないか」の両方を1回で確認する。
# このスクリプトは【読み取り専用】で、検出と報告のみを行う。
#
# 使い方:
#   ./check-intrusion.sh <検索対象のディレクトリ> [--days N] [--no-http]
#     --days N    「最近」とみなす日数（既定 3）
#     --no-http   サイトへの HEAD リクエストを行わない
#
# 実行例:
#   ./check-intrusion.sh /home/example/public_html
#   ./check-intrusion.sh /home/example --days 30   (さかのぼって確認したいとき)
#   curl -s <URL> | bash -s -- /home/example/public_html

set -u

# バイト単位で一致を取るためロケールを C に固定する。
# ja_JP.UTF-8 のままだと、BSD grep は不正な UTF-8 を含むファイル（PHP を埋め込んだ
# 画像など）に一致しなくなり、本来見つけたいものを取りこぼす。
LC_ALL=C
export LC_ALL

usage() {
    echo "Usage: $0 <search_directory> [--days N] [--no-http]"
    echo "  --days N    「最近」とみなす日数（既定 3）"
    echo "  --no-http   Web 側 PHP バージョン確認のための HEAD リクエストを行わない"
}

# --- 引数の解釈 ---------------------------------------------------------
search_dir=""
days=3
use_http=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --days)
            shift
            days="${1:-}"
            ;;
        --no-http) use_http=0 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "エラー: 不明なオプションです: $1" >&2; usage >&2; exit 1 ;;
        *)
            if [ -n "$search_dir" ]; then
                echo "エラー: ディレクトリは1つだけ指定してください: $1" >&2
                exit 1
            fi
            search_dir="$1"
            ;;
    esac
    shift
done

if [ -z "$search_dir" ]; then
    echo "エラー: 対象ディレクトリを引数でセットしてください"
    usage
    exit 1
fi
case "$days" in
    ''|*[!0-9]*) echo "エラー: --days は正の整数で指定してください: $days" >&2; exit 1 ;;
esac
if [ ! -d "$search_dir" ]; then
    echo "エラー: ディレクトリが存在しません: $search_dir"
    exit 1
fi
search_dir=$(cd "$search_dir" && pwd)

has_wp=0
command -v wp >/dev/null 2>&1 && has_wp=1
has_curl=0
command -v curl >/dev/null 2>&1 && has_curl=1

# --- 表示色 ------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_warn=$'\033[1;31m'
    c_bold=$'\033[1m'
    c_off=$'\033[0m'
else
    c_warn=''
    c_bold=''
    c_off=''
fi

findings=0
site_results=()
nl=$'\n'
tab=$(printf '\t')

hr() { echo "--------------------------------------------------"; }
warn() { echo "${c_warn}[!] $*${c_off}"; findings=$(( findings + 1 )); }
info() { echo "[i] $*"; }

# 検出結果リストを表示する（第2引数で表示件数の上限。既定15件）
print_list() {
    local list="$1" limit="${2:-15}" n
    [ -z "$list" ] && return 0
    n=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
    printf '%s\n' "$list" | head -"$limit" | sed 's/^/      /'
    [ "$n" -gt "$limit" ] && echo "      ... 他 $(( n - limit )) 件"
    return 0
}

# stat の書式は GNU(-c) と BSD(-f) で異なり、GNU の -f は「ファイルシステム情報」の
# 意味になってエラーにならず ? を返す。/dev/null でどちらが使えるか先に判定する。
stat_mode=""
if [ "$(stat -c%s /dev/null 2>/dev/null)" = "0" ]; then
    stat_mode="gnu"
elif [ "$(stat -f%z /dev/null 2>/dev/null)" = "0" ]; then
    stat_mode="bsd"
fi

# 更新日時（mtime）。ユーザーの依頼どおり、検出したファイルには必ず添える。
file_mtime() {
    case "$stat_mode" in
        gnu) stat -c%y "$1" 2>/dev/null | cut -c1-16 ;;
        bsd) stat -f%Sm -t '%Y-%m-%d %H:%M' "$1" 2>/dev/null ;;
        *) echo "" ;;
    esac
}

# パス一覧に更新日時を付けて返す
with_mtime() {
    local list="$1" f
    [ -z "$list" ] && return 0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        printf '%-17s %s\n' "$(file_mtime "$f")" "$f"
    done <<EOF
$list
EOF
    return 0
}

# ファイル名に改行やタブを含むものは、行区切りの処理で壊れるため除外して扱う。
# 改ざんされたサイトでは攻撃者が意図的に仕込めるので、それ自体が確認対象でもある。
# これはフィルタに徹し（パイプの中＝子シェルで動くため変数を持たない）、
# 検出そのものは後段の scan_weird_names() が本体側で行う。
collect_files() {
    local f
    while IFS= read -r -d '' f; do
        case "$f" in
            *"$nl"*|*"$tab"*) ;;
            *) printf '%s\n' "$f" ;;
        esac
    done
}

# 不正な名前のファイルを本体側で拾う（プロセス置換なのでサブシェルにならない）。
# 全ファイルを舐めると重いので、このスクリプトが実際に扱う範囲に絞る。
# 名前に改行を含むため変数に溜めると行が割れる。見つけた時点で整形して出力する。
weird_count=0
scan_weird_names() {
    local f
    while IFS= read -r -d '' f; do
        case "$f" in
            *"$nl"*|*"$tab"*)
                if [ "$weird_count" -eq 0 ]; then
                    warn "ファイル名に改行やタブを含むファイルがあります（通常は付かない名前です。制御文字は ? で表示）"
                fi
                weird_count=$(( weird_count + 1 ))
                [ "$weird_count" -le 10 ] &&
                    printf '      %s\n' "$(printf '%s' "$f" | tr "$nl$tab" '??')"
                ;;
        esac
    done < <(find "$search_dir" -type f \( -name '*.php*' -o -name '.htaccess' -o -path '*/uploads/*' \) \
        -print0 2>/dev/null)
    [ "$weird_count" -gt 10 ] && echo "      ... 他 $(( weird_count - 10 )) 件"
    return 0
}

# WordPress がサイト直下に置く PHP の一覧。
# wp-*.php をまとめて「本体のファイル」と見なすと、攻撃者が wp-cache-config.php
# のような紛らわしい名前で置いた Web シェルを見逃すため、名前を列挙する。
core_root_re='^(index|xmlrpc|wp-activate|wp-blog-header|wp-comments-post|wp-config|wp-config-sample|wp-cron|wp-links-opml|wp-load|wp-login|wp-mail|wp-settings|wp-signup|wp-trackback)\.php$'

# 変更ファイルを「コンポーネント単位」に畳むための awk。
# プラグイン/テーマの更新では数千ファイルが一度に変わるため、そのまま並べると
# 読めない。どの構成要素が変わったかに畳み、少数しか変わっていないものだけ
# 個別に出す（ピンポイントの改ざんはそこに現れる）。
awk_group='
function keyof(rel,   a, n) {
    if (rel ~ /^wp-admin\//) { return "wp-admin/" }
    if (rel ~ /^wp-includes\//) { return "wp-includes/" }
    n = split(rel, a, "/")
    if (n >= 3 && a[1] == "wp-content" && (a[2] == "plugins" || a[2] == "themes" || a[2] == "mu-plugins")) {
        return a[1] "/" a[2] "/" a[3] "/"
    }
    if (n >= 2) { return a[1] "/" }
    # サイト直下は、WordPress 本体にある名前なら畳む。
    # 本体に無い名前は個別に出す（見慣れない PHP がそこに現れる）。
    if (rel ~ core_re) { return "（サイト直下のコアファイル）" }
    return rel
}
{
    rel = $0
    if (index($0, prefix) == 1) { rel = substr($0, length(prefix) + 1) }
    k = keyof(rel)
    cnt[k]++
    paths[k] = paths[k] $0 "\n"
}
END {
    for (k in cnt) {
        printf "G\t%d\t%s\n", cnt[k], k
        if (cnt[k] <= small) { printf "%s", paths[k] }
    }
}'

# --- バージョン比較 -----------------------------------------------------
# sort -V は環境差があるので awk で数値比較する
version_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            ai = (i <= na ? x[i] + 0 : 0); bi = (i <= nb ? y[i] + 0 : 0)
            if (ai > bi) { print 1; exit }
            if (ai < bi) { print 0; exit }
        }
        print 1
    }'
}

# PHP バージョンが CVE-2026-109618 / 109619 の修正版かを判定する。
# 戻り値: 0=修正済み 1=未修正 2=判定不能
judge_php() {
    local ver="$1" branch fixed
    [ -z "$ver" ] && return 2
    branch=$(printf '%s\n' "$ver" | awk -F. '{print $1 "." $2}')
    case "$branch" in
        8.2) fixed="8.2.35" ;;
        8.3) fixed="8.3.36" ;;
        8.4) fixed="8.4.27" ;;
        8.5) fixed="8.5.12" ;;
        *)
            # 8.6 以降は修正後のリリース。8.1 以前は修正が出ておらず EOL。
            if [ "$(version_ge "$branch" "8.6")" = "1" ]; then
                return 0
            fi
            return 1
            ;;
    esac
    [ "$(version_ge "$ver" "$fixed")" = "1" ] && return 0
    return 1
}

# バージョン文字列から x.y.z だけを取り出す
extract_ver() {
    printf '%s\n' "$1" | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# PHP バージョンを判定して表示する（第2引数は「どこで調べたか」）
report_php_version() {
    local ver="$1" where="$2"
    if [ -z "$ver" ]; then
        info "$where: 判定できませんでした"
        return 0
    fi
    if judge_php "$ver"; then
        info "$where: PHP $ver（CVE-2026-109618/109619 の修正版）"
    else
        case $? in
            2) info "$where: PHP $ver（判定できませんでした）" ;;
            *) warn "$where: PHP $ver は未修正です（修正版: 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12）" ;;
        esac
    fi
    return 0
}

# --- 1サイト分のチェック -----------------------------------------------
check_site() {
    local wp_dir="$1"
    local content_dir="$wp_dir/wp-content"
    local uploads_dir="$content_dir/uploads"
    local before_findings=$findings
    local db_ok=0 home="" list out core_checked=0

    hr
    echo "WordPress   : $wp_dir"
    # DB に繋がらないまま DB 側を「該当なし」と出すと、未確認を安全と誤解するため先に疎通確認する。
    # --skip-plugins / --skip-themes は、改ざんされたプラグインが一覧をフィルタで隠すのを防ぐため。
    if [ "$has_wp" -eq 1 ] &&
        [ "$(wp eval 'echo "OK";' --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)" = "OK" ]; then
        db_ok=1
        home=$(wp option get home --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)
        echo "SiteURL     : $home"
        echo "WP Version  : $(wp core version --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)"
    fi

    # --- (1) Web 側の PHP バージョン ------------------------------------
    # レンタルサーバーでは SSH の php（CLI）と Web の PHP が別バージョンのことが多い。
    # CLI だけ見て「修正済み」と判断すると取り違えるため、サイト単位でも確認する。
    echo
    echo "[1] このサイトの PHP バージョン"
    # .htaccess のハンドラ指定（例: AddHandler x-httpd-php82 .php / SetHandler application/x-httpd-php8.2）
    list=$(find "$wp_dir" -maxdepth 2 -type f -name '.htaccess' -print0 2>/dev/null |
        xargs -0 grep -h -i -E 'AddHandler|SetHandler|AddType' 2>/dev/null |
        grep -i 'php' | sed 's/^[[:space:]]*//' | sort -u)
    if [ -n "$list" ]; then
        info ".htaccess の PHP ハンドラ指定:"
        print_list "$list" 5
    fi

    # HTTP ヘッダ（X-Powered-By）が最も確実。自サイトへの HEAD を1回だけ送る。
    if [ "$use_http" -eq 1 ] && [ "$has_curl" -eq 1 ] && [ -n "$home" ]; then
        out=$(curl -sI -m 10 -A 'check-intrusion.sh' "$home" 2>/dev/null |
            grep -i '^x-powered-by:' | head -1)
        if [ -n "$out" ]; then
            report_php_version "$(extract_ver "$out")" "Web 側（X-Powered-By）"
        else
            info "Web 側: X-Powered-By ヘッダが無く、HTTP からは判定できません"
        fi
    elif [ "$use_http" -eq 0 ]; then
        info "Web 側: --no-http のため HTTP 確認をスキップしました"
    fi
    info "※ 管理画面の「サイトヘルス」→「サーバー」でも Web 側の PHP バージョンを確認できます"

    # --- (2) uploads 内の実行可能ファイル -------------------------------
    # uploads は本来「画像などの置き場」で、PHP が置かれること自体が異常。
    echo
    echo "[2] uploads 内の実行可能ファイル"
    if [ -d "$uploads_dir" ]; then
        list=$(find "$uploads_dir" -type f \( -iname '*.php' -o -iname '*.php[0-9]' -o -iname '*.phtml' \
            -o -iname '*.phar' -o -iname '*.pht' -o -iname '*.shtml' -o -iname '*.cgi' \
            -o -iname '*.pl' -o -iname '*.py' -o -iname '*.sh' \) -print0 2>/dev/null | collect_files | sort)
        # index.php は WordPress やプラグインが「中身を見せない」ために置く正規のファイル
        list=$(printf '%s\n' "$list" | grep -v -E '/index\.php$' | sed '/^$/d')
        if [ -n "$list" ]; then
            warn "uploads に実行可能ファイルがあります（Web シェル設置の典型）"
            with_mtime "$list" | sed 's/^/      /'
        else
            info "実行可能ファイル: 該当なし（index.php を除く）"
        fi

        # 画像を装った二重拡張子（例: photo.jpg.php）
        list=$(find "$uploads_dir" -type f -iname '*.*.*' -print0 2>/dev/null | collect_files |
            grep -i -E '\.(jpe?g|png|gif|webp|svg|pdf|zip|txt)\.(php[0-9]?|phtml|phar|pht|shtml)$' | sort)
        if [ -n "$list" ]; then
            warn "画像などを装った二重拡張子のファイルがあります"
            with_mtime "$list" | sed 's/^/      /'
        else
            info "二重拡張子: 該当なし"
        fi

        # 画像ファイルに PHP コードが埋め込まれていないか。
        # 全件 grep は重いので、最近 ${days} 日以内に更新された画像だけを対象にする。
        # 判定は「<?php + 空白」「<?= + 変数」に限定する。<?= の3バイトだけだと
        # PNG/JPEG の圧縮データに偶然現れて誤検知が大量に出る。
        list=$(find "$uploads_dir" -type f -mtime -"$days" -size -5000k \
            \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.webp' \) \
            -print0 2>/dev/null | xargs -0 grep -l -a -E -- '<\?php[[:space:]]|<\?=[[:space:]]*\$' 2>/dev/null | sort)
        if [ -n "$list" ]; then
            warn "画像ファイルに PHP コードが埋め込まれています（直近 ${days} 日に更新されたもの）"
            with_mtime "$list" | sed 's/^/      /'
        else
            info "画像内の PHP コード: 該当なし（直近 ${days} 日に更新された画像を対象）"
        fi
    else
        info "uploads ディレクトリなし"
    fi

    # --- (3) 最近変更されたファイル -------------------------------------
    # コアとプラグイン/テーマが対象。uploads とキャッシュは通常運用で変わるため除外する。
    echo
    echo "[3] 本体ファイルの改ざん検証（チェックサム）"
    # 更新日時は touch で偽装できるが、チェックサムは公式の配布物との1ファイル単位の
    # 照合なので、改変・欠落・本来存在しないファイルを確定できる。
    # api.wordpress.org への通信が必要なため、--no-http のときは行わない。
    core_checked=0
    if [ "$has_wp" -eq 0 ]; then
        info "WP-CLI が無いためスキップ"
    elif [ "$use_http" -eq 0 ]; then
        info "--no-http のためスキップ（api.wordpress.org への通信が必要です）"
    else
        # --include-root を付けると、ルート直下に置かれた「本体に無いファイル」も
        # 警告してくれる。Web シェルの定番の置き場所なので必ず付ける。
        out=$(wp core verify-checksums --include-root --path="$wp_dir" --skip-plugins --skip-themes 2>&1)
        if printf '%s\n' "$out" | grep -q "^Success:"; then
            info "コア: チェックサム一致（ルート直下の余計なファイルも無し）"
            core_checked=1
        elif printf '%s\n' "$out" | grep -q -i "couldn.t get checksums\|Error: Supplied\|HTTP code 404"; then
            # ベータ版や独自ビルドでは公式のチェックサムが配布されていない
            info "コア: チェックサムを取得できず判定不能（ベータ版などの可能性）"
        else
            warn "コアのチェックサム検証で差分があります（改変・欠落・本体に無いファイル）"
            printf '%s\n' "$out" | grep -v "^Success" | head -15 | sed 's/^/      /'
            core_checked=1
        fi

        # プラグインは wordpress.org 配布のものだけ照合できる。
        # 有料・自作プラグインは「照合できない」であって「改ざん」ではないので分けて示す。
        out=$(wp plugin verify-checksums --all --path="$wp_dir" --skip-plugins --skip-themes 2>&1)
        local unverifiable mismatch
        unverifiable=$(printf '%s\n' "$out" |
            grep -c -i -E "could not retrieve the checksums|plugin-checksums/.*(404|403)" 2>/dev/null | tr -d ' ')
        mismatch=$(printf '%s\n' "$out" |
            grep -v -i -E "could not retrieve the checksums|plugin-checksums/.*(404|403)" |
            grep -v "^Success" | sed '/^$/d')
        if [ -n "$mismatch" ]; then
            warn "プラグインのチェックサム検証で差分があります"
            printf '%s\n' "$mismatch" | head -10 | sed 's/^/      /'
        else
            info "プラグイン: 照合できた範囲で差分なし"
        fi
        [ "${unverifiable:-0}" -gt 0 ] &&
            info "  └ ${unverifiable} 件は wordpress.org 配布でないため照合できません（有料・自作プラグイン）"
    fi

    echo
    echo "[3-2] 直近 ${days} 日に変更されたファイル（uploads・キャッシュを除く）"
    list=$(find "$wp_dir" -type f -name '*.php' -mtime -"$days" -print0 2>/dev/null | collect_files |
        grep -v -E '/wp-content/(uploads|cache|upgrade|backup[^/]*)/' | sort)
    if [ -n "$list" ]; then
        local grouped singles
        grouped=$(printf '%s\n' "$list" | awk -v prefix="$wp_dir/" -v small=3 -v core_re="$core_root_re" "$awk_group")
        # 構成要素ごとの件数（多い順）。更新履歴と突き合わせる用。
        info "変更のあった構成要素（直近 ${days} 日）:"
        printf '%s\n' "$grouped" | grep "^G$tab" | cut -f2,3 |
            sort -rn | awk -F"$tab" '{ printf "      %6d 件  %s\n", $1, $2 }' | head -15
        # 少数しか変わっていない構成要素のファイルは個別に出す
        singles=$(printf '%s\n' "$grouped" | grep -v "^G$tab" | sed '/^$/d' | sort)
        if [ -n "$singles" ]; then
            warn "少数のファイルだけが変更された箇所があります（更新作業で説明が付かない場合は要確認）"
            with_mtime "$singles" | sort -r | sed 's/^/      /' | head -20
            out=$(printf '%s\n' "$singles" | wc -l | tr -d ' ')
            [ "$out" -gt 20 ] && echo "      ... 他 $(( out - 20 )) 件"
        else
            info "少数だけ変更された箇所: なし（まとまった更新のみ）"
        fi
    else
        info "該当なし"
    fi

    # サイト直下に、WordPress 本体には無い名前の PHP が置かれていないか。
    # 更新日時に関係なく確認する（古い侵害ほど mtime だけでは見つからないため）。
    # [3] の --include-root で確認できた場合は、そちらのほうが確実なので省く。
    if [ "$core_checked" -eq 1 ]; then
        info "サイト直下の確認は [3] の --include-root で実施済み"
    else
        list=$(find "$wp_dir" -maxdepth 1 -type f -name '*.php' -print0 2>/dev/null | collect_files |
            awk -F/ -v core_re="$core_root_re" '$NF !~ core_re { print }' | sort)
        if [ -n "$list" ]; then
            warn "サイト直下に WordPress 本体には無い名前の PHP があります（心当たりが無ければ要確認）"
            with_mtime "$list" | sed 's/^/      /' | head -10
        else
            info "サイト直下の見慣れない PHP: 該当なし"
        fi
    fi

    # コア直下（wp-admin / wp-includes）の変更は、更新作業以外ではまず起きない
    list=$(find "$wp_dir/wp-admin" "$wp_dir/wp-includes" -type f -mtime -"$days" -print0 2>/dev/null |
        collect_files | sort)
    if [ -n "$list" ]; then
        warn "コアディレクトリ（wp-admin / wp-includes）に直近の変更があります"
        with_mtime "$list" | sed 's/^/      /' | head -10
    else
        info "コアディレクトリの直近の変更: 該当なし"
    fi

    # --- (4) 更新日時を偽装された疑いのあるファイル ----------------------
    # 攻撃者は touch で mtime を過去に戻して「最近変更されたファイル」の一覧から逃れる。
    # ctime（inode の変更時刻）は一般ユーザーでは書き換えられないため、
    # 「ctime は最近なのに mtime は古い」ファイルは偽装の有力な手がかりになる。
    echo
    echo "[4] 更新日時を偽装された疑いのあるファイル（ctime は最近 / mtime は古い）"
    # プラグインやテーマの更新は zip を mtime 付きで展開するため、正常な更新でも
    # 「ctime は新しい / mtime は古い」状態になる。更新で説明が付かない場所
    # （サイト直下・uploads）だけを要確認にし、それ以外は参考表示に回す。
    local backdated high="" low="" rel
    backdated=$(find "$wp_dir" -type f -name '*.php' -ctime -"$days" ! -mtime -"$days" -print0 2>/dev/null |
        collect_files | grep -v -E '/wp-content/(cache|upgrade)/' | sort)
    if [ -n "$backdated" ]; then
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            rel="${f#"$wp_dir"/}"
            case "$rel" in
                */uploads/*|uploads/*) high="$high$f$nl" ;;
                */*) low="$low$f$nl" ;;
                *) high="$high$f$nl" ;;
            esac
        done <<EOF
$backdated
EOF
    fi
    if [ -n "$high" ]; then
        warn "サイト直下や uploads に、mtime が古いまま ctime だけ新しい PHP があります（touch による偽装の疑い）"
        with_mtime "${high%$nl}" | sed 's/^/      /' | head -15
    else
        info "サイト直下・uploads: 該当なし"
    fi
    if [ -n "$low" ]; then
        out=$(printf '%s\n' "${low%$nl}" | wc -l | tr -d ' ')
        info "  └ プラグイン/テーマ/コア配下にも $out 件（更新の展開でも同じ状態になるため参考表示）"
        with_mtime "${low%$nl}" | sed 's/^/      /' | head -5
    fi
    info "  └ バックアップからの復元・権限変更・ファイル移動でも ctime は更新されます"

    # --- (5) wp-config.php / .htaccess ----------------------------------
    echo
    echo "[5] wp-config.php と .htaccess"
    local cfg
    for cfg in "$wp_dir/wp-config.php" "$wp_dir/../wp-config.php"; do
        [ -f "$cfg" ] || continue
        echo "  $(file_mtime "$cfg")  $cfg"
        # wp-config.php に本来現れない実行系のコード
        out=$(grep -n -E -- 'eval[[:space:]]*\(|base64_decode|gzinflate|str_rot13|\$_(GET|POST|REQUEST|COOKIE)|file_get_contents[[:space:]]*\([[:space:]]*["'"'"']https?:|auto_prepend_file|create_function' "$cfg" 2>/dev/null | head -5)
        if [ -n "$out" ]; then
            warn "wp-config.php に不審なコードがあります: $cfg"
            printf '%s\n' "$out" | sed 's/^/      /'
        fi
        # 誰でも書ける状態になっていないか（レンタルサーバーでは 777 を見かける）
        out=$(ls -l "$cfg" 2>/dev/null | awk '{print $1}')
        case "$out" in
            *w*w*w*|*rwxrwxrwx*) warn "wp-config.php のパーミッションが緩い可能性があります: $out $cfg" ;;
        esac
    done

    list=$(find "$wp_dir" -type f -name '.htaccess' -print0 2>/dev/null | collect_files | sort)
    if [ -n "$list" ]; then
        info ".htaccess 一覧（更新日時付き）:"
        with_mtime "$list" | sed 's/^/      /' | head -10
        # 拡張子の偽装（画像を PHP として実行させる）や、最上流に割り込む指定
        out=$(printf '%s\n' "$list" | tr '\n' '\0' |
            xargs -0 grep -n -i -E -- 'auto_prepend_file|auto_append_file|AddType[[:space:]]+application/x-httpd-php[[:space:]]+\.(jpg|jpeg|png|gif|txt|ico)|php_value[[:space:]]+(allow_url_include|disable_functions)|RewriteRule.*https?://' 2>/dev/null | head -8)
        if [ -n "$out" ]; then
            warn ".htaccess に不審な指定があります（拡張子偽装・外部転送・PHP 設定の上書き）"
            printf '%s\n' "$out" | sed 's/^/      /'
        else
            info ".htaccess の不審な指定: 該当なし"
        fi
    else
        info ".htaccess: 見つかりません"
    fi

    # --- (6) ユーザーと権限（WP-CLI がある場合）--------------------------
    echo
    echo "[6] ユーザー・権限・サイト設定"
    if [ "$has_wp" -eq 0 ]; then
        info "WP-CLI が無いためスキップ（管理者・設定は未確認）"
    elif [ "$db_ok" -eq 0 ]; then
        info "WP-CLI で DB に接続できないためスキップ（管理者・設定は未確認）"
    else
        out=$(wp user list --role=administrator --fields=ID,user_login,user_email,user_registered \
            --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)
        if [ -n "$out" ]; then
            echo "  - 管理者アカウント一覧:"
            printf '%s\n' "$out" | sed 's/^/      /'
        fi

        # 直近に登録された管理者。侵害時に最初に行われる永続化の典型。
        out=$(wp eval 'global $wpdb; $days = '"$days"'; $since = gmdate("Y-m-d H:i:s", time() - $days * 86400);
            $rows = $wpdb->get_results($wpdb->prepare("SELECT u.user_login, u.user_email, u.user_registered FROM {$wpdb->users} u INNER JOIN {$wpdb->usermeta} m ON m.user_id = u.ID WHERE m.meta_key = %s AND m.meta_value LIKE %s AND u.user_registered > %s", $wpdb->get_blog_prefix() . "capabilities", "%administrator%", $since));
            foreach ($rows as $r) { echo $r->user_registered . "  " . $r->user_login . "  " . $r->user_email . "\n"; }' \
            --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)
        if [ -n "$out" ]; then
            warn "直近 ${days} 日に登録された管理者がいます"
            print_list "$out"
        else
            info "直近 ${days} 日に登録された管理者: なし"
        fi

        # アプリケーションパスワードは、管理画面のパスワードを変えても生き残る永続化手段。
        out=$(wp eval 'global $wpdb; $rows = $wpdb->get_results($wpdb->prepare("SELECT u.user_login, m.meta_value FROM {$wpdb->usermeta} m INNER JOIN {$wpdb->users} u ON u.ID = m.user_id WHERE m.meta_key = %s", "_application_passwords"));
            foreach ($rows as $r) { $aps = json_decode($r->meta_value, true); if (!is_array($aps)) { continue; }
            foreach ($aps as $ap) { $c = isset($ap["created"]) ? gmdate("Y-m-d", $ap["created"]) : "?";
            $u = (isset($ap["last_used"]) && $ap["last_used"]) ? gmdate("Y-m-d", $ap["last_used"]) : "未使用";
            echo $r->user_login . "  作成:" . $c . "  最終使用:" . $u . "  " . (isset($ap["name"]) ? $ap["name"] : "") . "\n"; } }' \
            --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)
        if [ -n "$out" ]; then
            warn "アプリケーションパスワードが登録されています（パスワード変更後も有効。心当たりが無ければ失効を）"
            print_list "$out"
        else
            info "アプリケーションパスワード: なし"
        fi

        # 誰でも管理者として登録できる状態にされていないか
        out=$(wp option get users_can_register --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)
        local role
        role=$(wp option get default_role --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)
        if [ "$out" = "1" ] && [ "$role" = "administrator" ]; then
            warn "誰でも登録でき、既定の権限が管理者になっています（users_can_register=1 / default_role=administrator）"
        elif [ "$role" = "administrator" ]; then
            warn "新規ユーザーの既定の権限が管理者になっています（default_role=administrator）"
        elif [ "$out" = "1" ]; then
            info "ユーザー登録が開放されています（users_can_register=1 / default_role=${role}）"
        else
            info "ユーザー登録の設定: 問題なし（users_can_register=${out} / default_role=${role}）"
        fi

        # siteurl と home の書き換え（別ドメインへの誘導）
        out=$(wp option get siteurl --path="$wp_dir" --skip-plugins --skip-themes 2>/dev/null)
        if [ -n "$home" ] && [ -n "$out" ]; then
            local h_host s_host
            h_host=$(printf '%s\n' "$home" | awk -F/ '{print $3}')
            s_host=$(printf '%s\n' "$out" | awk -F/ '{print $3}')
            if [ "$h_host" != "$s_host" ]; then
                warn "siteurl と home のホストが異なります（home=$home / siteurl=$out）"
            else
                info "siteurl と home: 一致（$h_host）"
            fi
        fi
    fi

    site_results+=("$(( findings - before_findings )) $wp_dir")
    hr
}

# --- 対象サイトの収集 ---------------------------------------------------
wp_dirs=()
while IFS= read -r wp_config; do
    [ -z "$wp_config" ] && continue
    wp_dirs+=("$(dirname "$wp_config")")
done < <(find "$search_dir" -type f -name 'wp-config.php' -print0 2>/dev/null | collect_files | sort)

if [ "${#wp_dirs[@]}" -eq 0 ]; then
    echo "エラー: $search_dir 以下に wp-config.php が見つかりません" >&2
    exit 1
fi

echo "対象:       WordPress の侵害チェック（CVE-2026-109618 / 109619 を含む）"
echo "走査対象:   $search_dir"
echo "対象サイト: ${#wp_dirs[@]} 件"
echo "「最近」の定義: 直近 ${days} 日"
if [ "$has_wp" -eq 0 ]; then
    echo "WP-CLI:     未検出（ファイル側のみ確認します）"
else
    echo "WP-CLI:     検出（DB 側も確認します）"
fi

# --- ホスト全体: CLI の PHP と緩和設定 ----------------------------------
hr
echo "[0] サーバーの PHP（CLI）と緩和設定"
if command -v php >/dev/null 2>&1; then
    cli_ver=$(extract_ver "$(php -v 2>/dev/null | head -1)")
    report_php_version "$cli_ver" "CLI（php -v）"
    info "※ レンタルサーバーでは CLI と Web で PHP のバージョンが異なることがよくあります"
    info "   サイトごとの Web 側バージョンは各サイトの [1] を参照してください"

    # 侵入口になる session.upload_progress の設定。修正版までの応急処置として Off が推奨。
    upload_progress=$(php -r 'echo ini_get("session.upload_progress.enabled") ? "On" : "Off";' 2>/dev/null)
    only_cookies=$(php -r 'echo ini_get("session.use_only_cookies") ? "On" : "Off";' 2>/dev/null)
    if [ "$upload_progress" = "On" ]; then
        warn "session.upload_progress.enabled = On（CLI 基準）。侵入口になるため Off を推奨"
    elif [ -n "$upload_progress" ]; then
        info "session.upload_progress.enabled = Off（CLI 基準）"
    fi
    [ -n "$only_cookies" ] && info "session.use_only_cookies = ${only_cookies}（On 推奨）"
    info "※ いずれも CLI の設定です。Web 側は .user.ini や php.ini、管理パネルで確認してください"
else
    info "php コマンドが無いため CLI 側は未確認"
fi

for wp_dir in "${wp_dirs[@]}"; do
    check_site "$wp_dir"
done

# --- 不正な名前のファイル -----------------------------------------------
scan_weird_names
[ "$weird_count" -gt 0 ] && hr

# --- 検査したサイトの一覧 -----------------------------------------------
sites_hit=0
site_total=0
for r in "${site_results[@]}"; do
    site_total=$(( site_total + ${r%% *} ))
done

echo "検査したサイト: ${#site_results[@]} 件"
[ "$(( findings - site_total ))" -gt 0 ] &&
    printf '  %s[!] %4s 件%s  （ホスト全体: PHP バージョンなど）\n' \
        "$c_warn" "$(( findings - site_total ))" "$c_off"
for r in "${site_results[@]}"; do
    n="${r%% *}"
    d="${r#* }"
    if [ "$n" -gt 0 ]; then
        printf '  %s[!] %4s 件%s  %s\n' "$c_warn" "$n" "$c_off" "$d"
        sites_hit=$(( sites_hit + 1 ))
    else
        printf '  [ ] %4s 件  %s\n' "$n" "$d"
    fi
done
echo
if [ "$findings" -gt 0 ]; then
    echo "${c_warn}要確認として検出した項目: $findings 件（検出のあったサイト: ${sites_hit} / ${#site_results[@]}）${c_off}"
else
    echo "要確認として検出した項目: 0 件"
fi
echo

# --- まとめ -------------------------------------------------------------
if [ "$findings" -eq 0 ]; then
    echo "=> 典型的な侵害の痕跡は見つかりませんでした。"
    echo "   ただし安全の保証ではありません。次も併せて実施してください:"
else
    echo "${c_warn}=> 確認が必要な項目が見つかりました。${c_off}"
    echo "${c_bold}   PHP が未修正の場合、WordPress を最新にしても塞がりません（エンジン側の脆弱性のため）。${c_off}"
    echo "   対応の順序:"
    echo "     1. PHP を修正版へ（8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 以降）。"
    echo "        すぐに上げられない場合の応急処置: session.upload_progress.enabled = Off"
    echo "     2. 不審なファイル・管理者・アプリケーションパスワードを精査して除去"
    echo "     3. 認証情報（DB・管理者・API キー・FTP）をローテーション"
    echo "   併せて次も実施してください:"
fi
echo "     - check-wp.sh: チェックサム検証だけを行う軽量版（--no-http で省いた場合はこちら）"
echo "     - check-sc.sh: 自己修復型バックドアの痕跡（ドロップイン・共有メモリ・DBトリガー）"
echo "     - check-log-and-file-sakura.sh / -xserver.sh: アクセスログの調査"
echo "       侵入の痕跡は multipart POST の PHP_SESSION_UPLOAD_PROGRESS が目印です"
echo "       例: bash check-log-and-file-sakura.sh PHP_SESSION_UPLOAD_PROGRESS 30"

#!/usr/bin/env bash
# All-in-One WP Migration のバックアップ (.wpress) 棚卸しスクリプト
#
# .wpress は wp-content/ai1wm-backups/ に置かれる「サイト丸ごと」のバックアップで、
# DB ダンプ（＝wp-config.php の情報や利用者の個人情報を含む）までまとまっている。
# 置き場所に設置される .htaccess はディレクトリの一覧表示を止めるだけなので、
# ファイル名さえ分かれば URL を直接叩いて誰でもダウンロードできる。
# 不要なバックアップを放置しないよう、どのサイトに何件あるかを棚卸しする。
#
# 既定は【読み取り専用】で一覧と集計のみ。--delete を付けたときだけ削除する。
#
# 使い方:
#   ./check-wpress.sh <検索対象のディレクトリ> [--delete] [--yes]
#     --delete   一覧を表示したうえで .wpress を削除する（確認あり）
#     --yes      --delete の確認プロンプトを省略する（cron 等の非対話実行用）
#
# 実行例:
#   ./check-wpress.sh /home/example                     (一覧・集計のみ)
#   ./check-wpress.sh /home/example --delete            (確認してから削除)
#   curl -s <URL> | bash -s -- /home/example            (一覧・集計のみ)
#   curl -s <URL> | bash -s -- /home/example --delete   (確認してから削除)

set -u

usage() {
    echo "Usage: $0 <search_directory> [--delete] [--yes]"
    echo "  <search_directory>  .wpress を再帰的に探す起点のディレクトリ"
    echo "  --delete            一覧表示のうえで .wpress を削除する（確認あり）"
    echo "  --yes               --delete の確認プロンプトを省略する"
}

# --- 引数の解釈 ---------------------------------------------------------
search_dir=""
do_delete=0
assume_yes=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --delete) do_delete=1 ;;
        --yes|-y) assume_yes=1 ;;
        -h|--help) usage; exit 0 ;;
        -*)
            echo "エラー: 不明なオプションです: $1" >&2
            usage >&2
            exit 1
            ;;
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
    echo "curl xxxxx -s /example.com/public_html"
    usage
    exit 1
fi

# 相対パスで渡されても cd の副作用を受けないよう絶対パスに変換
if [ ! -d "$search_dir" ]; then
    echo "エラー: ディレクトリが存在しません: $search_dir"
    exit 1
fi
search_dir=$(cd "$search_dir" && pwd)

# WP-CLI があればサイト URL を取得して「公開ドメイン」として表示する
has_wp=0
command -v wp >/dev/null 2>&1 && has_wp=1

# --- 表示色 ------------------------------------------------------------
# 端末に出力しているときだけ色を付ける（リダイレクト時に制御文字を混ぜない）。
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    c_warn=$'\033[1;31m'
    c_bold=$'\033[1m'
    c_off=$'\033[0m'
else
    c_warn=''
    c_bold=''
    c_off=''
fi

tab=$(printf '\t')
nl=$'\n'
no_wp_label="(WordPress の外)"

hr() { echo "--------------------------------------------------"; }

# stat の書式は GNU(-c) と BSD(-f) で違う。しかも GNU の -f は
# 「ファイルシステム情報」の意味になり、エラーにならずに ? を返してしまう。
# そのためサイズが自明な /dev/null で、どちらの書式が使えるかを先に判定する。
stat_mode=""
if [ "$(stat -c%s /dev/null 2>/dev/null)" = "0" ]; then
    stat_mode="gnu"
elif [ "$(stat -f%z /dev/null 2>/dev/null)" = "0" ]; then
    stat_mode="bsd"
fi

# ファイルサイズ（バイト）。stat が使えない環境では ls の5列目で代用する。
file_size() {
    local size=""
    case "$stat_mode" in
        gnu) size=$(stat -c%s "$1" 2>/dev/null) ;;
        bsd) size=$(stat -f%z "$1" 2>/dev/null) ;;
    esac
    [ -z "$size" ] && size=$(ls -ld "$1" 2>/dev/null | awk '{print $5}')
    # 数値でなければ 0 として扱う（集計の計算が壊れないように）
    case "$size" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$size" ;;
    esac
}

# 最終更新日時。取れなければ空文字を返す。
file_mtime() {
    case "$stat_mode" in
        gnu) stat -c%y "$1" 2>/dev/null | cut -c1-16 ;;
        bsd) stat -f%Sm -t '%Y-%m-%d %H:%M' "$1" 2>/dev/null ;;
        *) echo "" ;;
    esac
}

# バイト数を読みやすい単位にする
human() {
    awk -v b="${1:-0}" 'BEGIN {
        split("B KB MB GB TB", u, " ")
        i = 1
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) { printf "%d%s\n", b, u[i] } else { printf "%.1f%s\n", b, u[i] }
    }'
}

# .wpress の置かれている WordPress を特定する。
# wp-load.php は WordPress のルートに必ずあるため、これを目印に上へ辿る
# （wp-config.php は1つ上の階層に置ける構成があり、ルートの判定には使えない）。
find_wp_root() {
    local dir="$1" parent
    # 絶対パス以外は辿らない（相対パスだと . から先に進めず無限ループになり、
    # しかも実行時のカレントディレクトリ次第で別のサイトを指してしまう）
    case "$dir" in
        /*) ;;
        *) return 1 ;;
    esac
    while [ -n "$dir" ] && [ "$dir" != "/" ]; do
        if [ -f "$dir/wp-load.php" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
        parent=$(dirname "$dir")
        # dirname が同じ値を返したら、それ以上は遡れないので打ち切る
        [ "$parent" = "$dir" ] && break
        dir="$parent"
    done
    return 1
}

# --- .wpress の収集 -----------------------------------------------------
# 改ざんされたサイトでは、攻撃者がファイル名に改行やタブを仕込める。
# 行区切りで受け取ると1つの名前が複数行に割れ、途中までのパスを別ファイルとして
# 扱ってしまうため、NUL 区切りで受け取る。
files=()
weird=()
while IFS= read -r -d '' f; do
    case "$f" in
        *"$nl"*|*"$tab"*) weird+=("$f") ;;
        *) files+=("$f") ;;
    esac
done < <(find "$search_dir" -type f -name '*.wpress' -print0 2>/dev/null)

echo "対象:       All-in-One WP Migration のバックアップ (.wpress)"
echo "走査対象:   $search_dir"

# 改行やタブを含む名前は集計・削除の対象から外し、手動確認を促す。
# 通常のバックアップには付かない名前なので、それ自体が確認すべき兆候でもある。
if [ "${#weird[@]}" -gt 0 ]; then
    echo "${c_warn}[!] ファイル名に改行やタブを含む .wpress が ${#weird[@]} 件あります${c_off}"
    echo "    通常は付かない名前です。集計・削除の対象から外しました（制御文字は ? で表示）。"
    for f in "${weird[@]}"; do
        printf '      %s\n' "$(printf '%s' "$f" | tr "$nl$tab" '??')"
    done
    echo
fi

if [ "${#files[@]}" -eq 0 ]; then
    echo ".wpress は見つかりませんでした。"
    exit 0
fi

# 「WordPress ルート<TAB>サイズ<TAB>パス」を作り、ルートでまとめる
records=$(
    for f in "${files[@]}"; do
        root=$(find_wp_root "$(dirname "$f")") || root="$no_wp_label"
        printf '%s\t%s\t%s\n' "$root" "$(file_size "$f")" "$f"
    done | sort -t "$tab" -k1,1 -k3,3
)

# --- サイト単位で一覧表示 -----------------------------------------------
summary=""      # 「件数<TAB>合計サイズ<TAB>表示名」を溜める
total_count=0
total_bytes=0
cur_root=""
cur_label=""
cur_home=""
cur_count=0
cur_bytes=0

# サイトの区切りで小計を出力し、集計用の行を summary に積む
flush_group() {
    [ -z "$cur_root" ] && return 0
    echo "  小計: ${cur_count} 件 / $(human "$cur_bytes")"
    summary="${summary}${cur_count}${tab}${cur_bytes}${tab}${cur_label}
"
    return 0
}

while IFS="$tab" read -r root size path; do
    [ -z "$path" ] && continue

    if [ "$root" != "$cur_root" ]; then
        flush_group
        cur_root="$root"
        cur_count=0
        cur_bytes=0
        cur_home=""

        hr
        if [ "$root" = "$no_wp_label" ]; then
            cur_label="$no_wp_label"
            echo "サイト: $no_wp_label"
        else
            # 公開ドメインは WP-CLI の home から取る。
            # 値は改ざんされ得るので eval せず echo の引数としてのみ扱う。
            if [ "$has_wp" -eq 1 ]; then
                cur_home=$(wp option get home --path="$root" --skip-plugins --skip-themes 2>/dev/null)
            fi
            cur_label="${cur_home:-$root}"
            echo "サイト: $cur_label"
            [ -n "$cur_home" ] && echo "  WP   : $root"
        fi
    fi

    cur_count=$(( cur_count + 1 ))
    cur_bytes=$(( cur_bytes + size ))
    total_count=$(( total_count + 1 ))
    total_bytes=$(( total_bytes + size ))

    printf '  %-10s  %-16s  %s\n' "$(human "$size")" "$(file_mtime "$path")" "$path"
    # ファイル名さえ分かれば直接ダウンロードできる、という点を具体的に示す
    if [ -n "$cur_home" ]; then
        case "$path" in
            "$root"/*) echo "            └ URL: ${cur_home}${path#"$root"}" ;;
        esac
    fi
done <<EOF
$records
EOF
flush_group

# --- ドメイン別の集計 ---------------------------------------------------
hr
echo "${c_bold}ドメイン別の .wpress${c_off}"
printf '%s' "$summary" | sort -t "$tab" -k1,1nr | while IFS="$tab" read -r cnt bytes label; do
    [ -z "$label" ] && continue
    printf '  %4s 件  %-10s  %s\n' "$cnt" "$(human "$bytes")" "$label"
done
echo
echo "${c_warn}合計: ${total_count} 件 / $(human "$total_bytes")${c_off}"
echo

# --- 削除 ---------------------------------------------------------------
if [ "$do_delete" -eq 0 ]; then
    echo "=> .wpress はファイル名が分かれば URL から直接ダウンロードできます。"
    echo "   置き場所の .htaccess は一覧表示を止めるだけで、ダウンロードは防げません。"
    echo "   不要なものは削除を推奨します（削除する場合は --delete を付けて再実行）。"
    echo "   必要なバックアップは、手元にダウンロードしてから削除してください。"
    exit 0
fi

hr
echo "${c_bold}削除リスト（${total_count} 件 / $(human "$total_bytes")）${c_off}"
printf '%s\n' "$records" | while IFS="$tab" read -r root size path; do
    [ -z "$path" ] && continue
    printf '  %-10s  %s\n' "$(human "$size")" "$path"
done
echo

if [ "$assume_yes" -eq 0 ]; then
    if : 2>/dev/null < /dev/tty; then
        echo "${c_warn}削除すると元に戻せません。必要なバックアップは先にダウンロードしてください。${c_off}"
        read -r -p "上記 ${total_count} 件を削除します。よろしければ yes と入力 : " ans < /dev/tty
        # 端末によっては末尾に CR が残るため、空白ごと落としてから判定する
        ans=$(printf '%s' "$ans" | tr -d '\r' | tr -d '[:space:]')
        case "$ans" in
            yes|YES|Yes) ;;
            *) echo "中止しました（削除していません）"; exit 0 ;;
        esac
    else
        echo "エラー: 非対話実行で削除するには --yes を付けてください" >&2
        exit 1
    fi
fi

# search_dir が / のときに // で始まる判定パターンにならないようにする
case "$search_dir" in
    /) path_prefix="" ;;
    *) path_prefix="$search_dir" ;;
esac

deleted=0
failed=0
freed=0
# 削除はテキストを読み直さず、収集した配列をそのまま辿る。
# 途中でタブ区切りに変換しないので、名前の細工で対象がずれることがない。
for path in "${files[@]}"; do
    # 走査対象の配下にある .wpress であることを、消す直前にもう一度確かめる
    case "$path" in
        "$path_prefix"/*.wpress) ;;
        *)
            echo "${c_warn}[!] 走査対象外のパスのためスキップ: $path${c_off}"
            failed=$(( failed + 1 ))
            continue
            ;;
    esac
    # シンボリックリンク経由で想定外のファイルを消さないよう、実体だけを対象にする
    if [ -L "$path" ] || [ ! -f "$path" ]; then
        echo "[!] 実体のファイルではないためスキップ: $path"
        failed=$(( failed + 1 ))
        continue
    fi
    size=$(file_size "$path")
    if rm -f -- "$path" 2>/dev/null && [ ! -e "$path" ]; then
        echo "削除: $path"
        deleted=$(( deleted + 1 ))
        freed=$(( freed + size ))
    else
        echo "${c_warn}[!] 削除できませんでした（権限を確認してください）: $path${c_off}"
        failed=$(( failed + 1 ))
    fi
done

hr
echo "削除: ${deleted} 件 / 解放: $(human "$freed")"
[ "$failed" -gt 0 ] && echo "${c_warn}失敗: ${failed} 件${c_off}"
echo
echo "=> 削除は .wpress のみを対象にしています（ai1wm-backups 内の .htaccess や"
echo "   index.php はプラグインの動作に必要なため残しています）。"
echo "   バックアップの自動生成を止めたい場合は、プラグイン側の設定も見直してください。"

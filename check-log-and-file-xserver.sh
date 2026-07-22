#!/usr/bin/env bash
# エックスサーバー向けログの確認スクリプト
# ホームフォルダ(~)で実行する。
#
# エックスサーバーはドメインごとに
#   ~/ドメイン名/public_html   (公開フォルダ)
#   ~/ドメイン名/log/ドメイン名.access_log_YYYYMMDD.gz  (ログ)
# という構成になっている（例: ~/eucalyption.me/public_html,
# ~/eucalyption.me/log/eucalyption.me.access_log_20260721.gz）。
#
# "public_html" フォルダを再帰的に検索することで公開フォルダ(=ドメインフォルダ)を特定し、
# 見つかった各ドメインフォルダの log から「過去N日分」の access_log を対象に検索する。
# N は第2引数で指定するか、未指定なら端末(/dev/tty)から対話入力する。
# gz ファイルをストリーム解凍して cat | grep "/batch/v1" を探す
#
# 実行例:
#   ./check-log-and-file-xserver.sh                         (対話入力)
#   ./check-log-and-file-xserver.sh /batch/v1 7             (引数で指定)
#   curl -s <URL> | bash                                   (対話入力: /dev/tty から読む)
#   curl -s <URL> | bash -s -- /batch/v1 7                 (引数で指定・非対話)

set -u

# 検索パターン（第1引数で上書き可。デフォルト /batch/v1）
pattern="${1:-/batch/v1}"

# 対象日数（第2引数で指定可。未指定なら端末から対話入力）
days="${2:-}"

# 検索の起点（ホームディレクトリ）
base_dir="$HOME"

# 日数が引数で渡されなければ端末(/dev/tty)から対話入力する。
# /dev/tty から読むことで curl | bash でも stdin(=スクリプト本体)を消費せずに済む。
# [ -r /dev/tty ] は端末が無くても真になるため、実際に開けるかで判定する
# （2>/dev/null を先に置き、制御端末が無い場合の open エラーも抑止する）。
if [ -z "$days" ]; then
    if : 2>/dev/null < /dev/tty; then
        read -r -p "過去何日分のログを対象にしますか？ (例: 7 / Enterで7) : " days < /dev/tty
        days="${days:-7}"
    else
        echo "エラー: 非対話実行では日数を第2引数で指定してください (例: ... | bash -s -- \"$pattern\" 7)" >&2
        exit 1
    fi
fi

# 入力チェック（正の整数のみ）
case "$days" in
    ''|*[!0-9]*)
        echo "エラー: 日数は正の整数で入力してください: $days" >&2
        exit 1
        ;;
esac

# --- 公開フォルダ(ドメイン)の特定 -----------------------------------------
# "public_html" フォルダを再帰的に検索し、その親フォルダをドメインフォルダとみなす。
# 例: ~/eucalyption.me/public_html が見つかれば、ドメイン名は eucalyption.me。
# --------------------------------------------------------------------------
domain_dirs=()
while IFS= read -r d; do
    domain_dirs+=("$d")
done < <(find "$base_dir" -type d -name 'public_html' 2>/dev/null | sed 's#/public_html$##' | sort -u)

if [ "${#domain_dirs[@]}" -eq 0 ]; then
    echo "エラー: $base_dir 以下に public_html フォルダが見つかりません" >&2
    exit 1
fi

echo "検出した公開フォルダ:"
for d in "${domain_dirs[@]}"; do
    echo "  $d/public_html  (ドメイン名: $(basename "$d"))"
done
echo --------------------------------------------------

# --- 対象ログファイルの選択 -----------------------------------------------
# 各ドメインフォルダの log/ から、mtime が過去 N 日以内の
# "ドメイン名.access_log_*.gz" を集める（新しい順は sort で整える）。
# --------------------------------------------------------------------------
files=()
for d in "${domain_dirs[@]}"; do
    domain="$(basename "$d")"
    log_dir="$d/log"
    [ -d "$log_dir" ] || continue
    while IFS= read -r f; do
        files+=("$f")
    done < <(find "$log_dir" -type f -name "${domain}.access_log_*.gz" -mtime -"$days" 2>/dev/null | sort)
done

if [ "${#files[@]}" -eq 0 ]; then
    echo "エラー: 過去 ${days} 日以内に該当する access_log ファイルが見つかりません" >&2
    exit 1
fi

echo "対象期間     : 過去 ${days} 日"
echo "対象ファイル : ${#files[@]} 件"
printf '  %s\n' "${files[@]}"
echo "検索パターン : $pattern"
echo --------------------------------------------------

# gz をストリーム解凍（ディスクに展開しない）して grep（解凍は1回のみ）
matches=$(gzip -dc "${files[@]}" | grep -- "$pattern" || true)

count=0
if [ -n "$matches" ]; then
    printf '%s\n' "$matches"
    count=$(printf '%s\n' "$matches" | wc -l | tr -d ' ')
fi

echo --------------------------------------------------
echo "マッチ件数 : $count"

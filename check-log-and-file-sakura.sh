#!/usr/bin/env bash
# さくらインターネット レンタルサーバー向けログの確認スクリプト
# ホームフォルダで実行し ~/log/access_*.gz から「過去N日分」を対象に検索する
# N は第2引数で指定するか、未指定なら端末(/dev/tty)から対話入力する。
# gz ファイルをストリーム解凍して cat | grep "/batch/v1" を探す
#
# 実行例:
#   ./check-log-and-file-sakura.sh                         (対話入力)
#   ./check-log-and-file-sakura.sh /batch/v1 7             (引数で指定)
#   curl -s <URL> | bash                                   (対話入力: /dev/tty から読む)
#   curl -s <URL> | bash -s -- /batch/v1 7                 (引数で指定・非対話)

set -u

# 検索パターン（第1引数で上書き可。デフォルト /batch/v1）
pattern="${1:-/batch/v1}"

# 対象日数（第2引数で指定可。未指定なら端末から対話入力）
days="${2:-}"

# ログディレクトリ
log_dir="$HOME/log"

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

# --- 対象ファイルの選択 -------------------------------------------------
# mtime が過去 N 日以内の access_*.gz を集める（新しい順は sort で整える）。
# find -mtime -N は FreeBSD / GNU 双方で使え、ファイル名の書式に依存しない。
# ----------------------------------------------------------------------
files=()
while IFS= read -r f; do
    files+=("$f")
done < <(find "$log_dir" -type f -name 'access_*.gz' -mtime -"$days" 2>/dev/null | sort)

if [ "${#files[@]}" -eq 0 ]; then
    echo "エラー: 過去 ${days} 日以内に $log_dir/access_*.gz が見つかりません" >&2
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

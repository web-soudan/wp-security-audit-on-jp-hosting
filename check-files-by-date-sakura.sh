#!/usr/bin/env bash
# さくらインターネット レンタルサーバー向け: 指定した日付範囲で作成されたファイルの確認
#
# さくらではドキュメントルートを自由な名前で作成できるため、ホーム配下を丸ごと走査し、
# 除外フォルダ（既定は ~/log）以外から「作成日時(birth time)が指定範囲内」のファイルを探す。
# 新規アップロードされた不審ファイルの発見を想定。
# birth time は touch で改ざんしにくく「いつ作られたか」の判断に mtime より適する。
# (-newerBt / stat -f は FreeBSD・macOS の BSD 系ツールが対応。GNU/Linux は非対応)
#
# 日付範囲は引数で指定するか、未指定なら端末(/dev/tty)から対話入力する。
#
# 実行例:
#   ./check-files-by-date-sakura.sh                          (対話入力)
#   ./check-files-by-date-sakura.sh 2026-07-01 2026-07-08    (引数で指定)
#   curl -s <URL> | bash                                     (対話入力: /dev/tty から読む)
#   curl -s <URL> | bash -s -- 2026-07-01 2026-07-08         (引数で指定・非対話)

set -u

# 走査の起点（さくらのホーム）。必要に応じて変更可
scan_dir="$HOME"

# 除外するフォルダ（絶対パス）。ここに追記すれば対象から外せる
excludes=(
    "$HOME/log"
)

# --- 日付範囲の決定 -----------------------------------------------------
# 開始日=第1引数 / 終了日=第2引数。未指定なら端末から対話入力。
# /dev/tty から読むことで curl | bash でも stdin(=スクリプト本体)を消費せずに済む。
start="${1:-}"
end="${2:-}"

if [ -z "$start" ] || [ -z "$end" ]; then
    if : 2>/dev/null < /dev/tty; then
        [ -z "$start" ] && read -r -p "開始日 (YYYY-MM-DD) : " start < /dev/tty
        [ -z "$end" ]   && read -r -p "終了日 (YYYY-MM-DD) : " end   < /dev/tty
    else
        echo "エラー: 非対話実行では開始日・終了日を引数で指定してください (例: ... | bash -s -- 2026-07-01 2026-07-08)" >&2
        exit 1
    fi
fi

# 日付フォーマットの検証（YYYY-MM-DD）
for d in "$start" "$end"; do
    case "$d" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
        *) echo "エラー: 日付は YYYY-MM-DD 形式で指定してください: $d" >&2; exit 1 ;;
    esac
done

# 範囲: 開始日 00:00:00 〜 終了日 23:59:59（両端の日を含む）
start_ts="$start 00:00:00"
end_ts="$end 23:59:59"

# --- 除外条件(prune)を組み立てる ---------------------------------------
# find "$scan_dir" \( -path A -o -path B -o -false \) -prune -o <条件> -print0
# 除外フォルダを prune することで、その配下には降りない。
prune_expr=()
for d in "${excludes[@]}"; do
    prune_expr+=( -path "$d" -o )
done

echo "走査対象     : $scan_dir"
echo "除外フォルダ : ${excludes[*]}"
echo "作成日時範囲 : $start_ts 〜 $end_ts"
echo --------------------------------------------------

# birth time が範囲内のファイルを列挙し、作成日時とともに表示する
count=0
while IFS= read -r -d '' file; do
    btime=$(stat -f '%SB' -t '%Y-%m-%d %H:%M:%S' "$file" 2>/dev/null)
    printf '%s  %s\n' "$btime" "$file"
    count=$((count + 1))
done < <(
    find "$scan_dir" \( "${prune_expr[@]}" -false \) -prune -o \
        -type f -newerBt "$start_ts" ! -newerBt "$end_ts" -print0
)

echo --------------------------------------------------
echo "該当件数 : $count"

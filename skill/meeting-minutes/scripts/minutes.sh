#!/bin/bash
# 把一場會議的逐字稿整理成 minutes.md，再輸出 minutes.pdf（需要 Claude Code 的 claude 指令）。
#
# 用法：  bash minutes.sh <會議資料夾 | transcript.txt | 錄音檔> [會議名稱]
#   - 給資料夾或 txt：直接整理
#   - 給錄音檔：先轉逐字稿再整理

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
. "$HERE/config.sh"

IN="${1:-}"
if [ -z "$IN" ]; then
  # 沒給參數：用最新的一場會議
  IN="$(ls -td "$MEETINGS_DIR"/*/ 2>/dev/null | head -1)"
  [ -n "$IN" ] || { echo "用法：minutes <會議資料夾 | transcript.txt | 錄音檔>"; exit 1; }
  echo "使用最新的會議：$IN"
fi
[ -e "$IN" ] || { echo "找不到：$IN"; exit 1; }

if [ -d "$IN" ]; then
  DIR="$(cd "$IN" && pwd)"
  TXT="$DIR/transcript.txt"
  if [ ! -f "$TXT" ]; then
    AUDIO="$(ls "$DIR"/audio.* 2>/dev/null | head -1)"
    [ -n "$AUDIO" ] || { echo "資料夾裡沒有 transcript.txt 或錄音檔：$DIR"; exit 1; }
    bash "$HERE/transcribe.sh" "$AUDIO" || exit 1
  fi
else
  DIR="$(cd "$(dirname "$IN")" && pwd)"
  case "$IN" in
    *.txt) TXT="$DIR/$(basename "$IN")" ;;
    *)     bash "$HERE/transcribe.sh" "$IN" || exit 1; TXT="$DIR/transcript.txt" ;;
  esac
fi

# 會議名稱：參數 > 資料夾名稱（YYYY-MM-DD_HHMM_名稱）
NAME="${2:-}"
if [ -z "$NAME" ]; then
  NAME="$(basename "$DIR" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}_?//; s/_/ /g')"
fi

if ! command -v claude >/dev/null; then
  echo
  echo "逐字稿：$TXT"
  echo "沒有找到 Claude Code（claude 指令），請把這個 txt 拖進 Claude，說「用 meeting-minutes 整理」。"
  echo "安裝 Claude Code 之後，這一步就會自動完成。"
  exit 0
fi

echo
echo "交給 Claude 整理會議記錄…"
(
  cd "$DIR" && claude -p "用 meeting-minutes skill（位於 $SKILL_DIR）把 $(basename "$TXT") 整理成 minutes.md，然後執行 python3 \"$SKILL_DIR/scripts/md2pdf.py\" minutes.md 輸出 PDF。會議名稱：${NAME:-從內容判斷}。資料夾名稱：$(basename "$DIR")。" \
    --allowedTools "Read,Write,Edit,Bash(python3:*)"
)

if [ -f "$DIR/minutes.pdf" ]; then
  echo "完成：$DIR/minutes.pdf"
  open "$DIR/minutes.pdf" 2>/dev/null || true
elif [ -f "$DIR/minutes.md" ]; then
  python3 "$HERE/md2pdf.py" "$DIR/minutes.md" && open "$DIR/minutes.pdf" 2>/dev/null || true
fi

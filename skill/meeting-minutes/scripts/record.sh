#!/bin/bash
# 錄下一場會議，結束後自動轉逐字稿，再整理成 minutes.md / minutes.pdf。
#
# 用法：  bash record.sh [會議名稱]
# 結束：  按 q（按 Ctrl+C 也可以）
#
# 臨時改設定（不影響設定檔）：
#   MIC=iPhone          麥克風名稱關鍵字
#   MEETINGS_DIR=路徑   會議資料夾的根目錄
#   AUTO_MINUTES=0      錄完只轉逐字稿，不自動整理

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/config.sh"

NAME="${1:-會議}"
NAME="${NAME// /_}"
DIR="$MEETINGS_DIR/$(date +%Y-%m-%d_%H%M)_$NAME"

command -v ffmpeg >/dev/null || { echo "找不到 ffmpeg，請先執行：brew install ffmpeg"; exit 1; }

# 用名稱找麥克風的編號（iPhone 連上或斷開時編號會變，所以不寫死）
DEVICES="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | awk '/audio devices:/{a=1; next} a')"
LINE="$(printf '%s\n' "$DEVICES" | grep -iF -- "$MIC" | head -1 || true)"
if [ -z "$LINE" ]; then
  echo "找不到符合「$MIC」的麥克風。目前的音訊裝置："
  printf '%s\n' "$DEVICES" | sed -E 's/^\[[^]]*\] //'
  echo "臨時指定：MIC=名稱關鍵字 meeting $NAME"
  echo "永久修改：meeting-setup mic"
  exit 1
fi
IDX="$(printf '%s' "$LINE" | sed -E 's/.*\] \[([0-9]+)\] .*/\1/')"
DEVNAME="$(printf '%s' "$LINE" | sed -E 's/.*\] \[[0-9]+\] //')"

mkdir -p "$DIR"
echo "麥克風：$DEVNAME"
echo "存到：  $DIR"
echo "錄音中… 按 q 結束（time= 應該跟著實際時間跑）"
echo

# 讓 Ctrl+C 只停掉 ffmpeg，腳本繼續往下做轉錄
trap 'true' INT
ffmpeg -hide_banner -loglevel error -stats -f avfoundation -i ":$IDX" -ac 1 -ar 16000 "$DIR/audio.wav"
trap - INT
echo

if [ ! -s "$DIR/audio.wav" ]; then
  echo "沒有錄到聲音，請確認 Terminal 有麥克風權限（系統設定 → 隱私權與安全性 → 麥克風）。"
  exit 1
fi

bash "$HERE/transcribe.sh" "$DIR/audio.wav" || exit 1

if [ "$AUTO_MINUTES" != "0" ]; then
  bash "$HERE/minutes.sh" "$DIR" "${NAME//_/ }"
else
  echo "逐字稿完成：$DIR/transcript.txt"
  echo "要整理成會議記錄：minutes \"$DIR\""
fi

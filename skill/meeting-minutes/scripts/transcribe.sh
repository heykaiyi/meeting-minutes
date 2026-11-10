#!/bin/bash
# 把錄音轉成逐字稿：同資料夾產生 transcript.txt 和 transcript.srt
#
# 用法：  bash transcribe.sh 錄音檔（wav / m4a / mp3 都可以）
# 臨時改設定：WHISPER_MODEL=模型路徑、WHISPER_LANG=en

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/config.sh"

IN="${1:?用法：stt 錄音檔}"
[ -f "$IN" ] || { echo "找不到檔案：$IN"; exit 1; }
DIR="$(cd "$(dirname "$IN")" && pwd)"
MODEL="$WHISPER_MODEL"
PROMPT="以下是繁體中文的會議記錄。"
[ "$WHISPER_LANG" = "zh" ] || PROMPT=""

command -v whisper-cli >/dev/null || { echo "找不到 whisper-cli，請先執行：brew install whisper-cpp"; exit 1; }
if [ ! -s "$MODEL" ] || [ "$(wc -c < "$MODEL")" -lt 10000000 ]; then
  echo "找不到模型或模型不完整：$MODEL"
  echo "重新下載：meeting-setup model"
  exit 1
fi

# whisper 要 16kHz 單聲道 wav；不是的話先轉
WAV="$IN"
if [ "${IN##*.}" != "wav" ] || ! ffprobe -v error -show_entries stream=sample_rate -of csv=p=0 "$IN" 2>/dev/null | grep -qx 16000; then
  WAV="$DIR/.audio_16k.wav"
  ffmpeg -hide_banner -loglevel error -y -i "$IN" -ac 1 -ar 16000 "$WAV"
fi

echo "轉逐字稿中（$(basename "$MODEL")）…"
ARGS=(-m "$MODEL" -l "$WHISPER_LANG" -f "$WAV" -otxt -osrt -of "$DIR/transcript")
[ -n "$PROMPT" ] && ARGS+=(--prompt "$PROMPT")
whisper-cli "${ARGS[@]}"

[ "$WAV" != "$IN" ] && rm -f "$WAV"

# 有 opencc 就把簡體轉成台灣繁體與用語
if [ "$WHISPER_LANG" = "zh" ] && command -v opencc >/dev/null; then
  for f in "$DIR/transcript.txt" "$DIR/transcript.srt"; do
    if opencc -i "$f" -o "$f.tmp" -c s2twp.json 2>/dev/null && [ -s "$f.tmp" ]; then mv "$f.tmp" "$f"; else rm -f "$f.tmp"; fi
  done
fi

echo "完成：$DIR/transcript.txt"

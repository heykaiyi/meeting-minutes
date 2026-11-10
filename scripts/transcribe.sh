#!/bin/bash
# 把錄音轉成逐字稿：同資料夾產生 transcript.txt 和 transcript.srt
#
# 用法：  bash transcribe.sh 錄音檔（wav / m4a / mp3 都可以）
# 環境變數：WHISPER_MODEL=模型路徑（預設 ~/ggml-large-v3-turbo.bin）

set -euo pipefail

IN="${1:?用法：bash transcribe.sh 錄音檔}"
[ -f "$IN" ] || { echo "找不到檔案：$IN"; exit 1; }
DIR="$(cd "$(dirname "$IN")" && pwd)"
MODEL="${WHISPER_MODEL:-$HOME/ggml-large-v3-turbo.bin}"
PROMPT="以下是繁體中文的會議記錄。"

command -v whisper-cli >/dev/null || { echo "找不到 whisper-cli，請先執行：brew install whisper-cpp"; exit 1; }
if [ ! -s "$MODEL" ] || [ "$(wc -c < "$MODEL")" -lt 10000000 ]; then
  echo "找不到模型或模型不完整：$MODEL"
  echo "下載：curl -L -o ~/ggml-large-v3-turbo.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
  exit 1
fi

# whisper 要 16kHz 單聲道 wav；不是的話先轉
WAV="$IN"
if [ "${IN##*.}" != "wav" ] || ! ffprobe -v error -show_entries stream=sample_rate -of csv=p=0 "$IN" 2>/dev/null | grep -qx 16000; then
  WAV="$DIR/.audio_16k.wav"
  ffmpeg -hide_banner -loglevel error -y -i "$IN" -ac 1 -ar 16000 "$WAV"
fi

echo "轉逐字稿中（$(basename "$MODEL")）…"
whisper-cli -m "$MODEL" -l zh -f "$WAV" -otxt -osrt -of "$DIR/transcript" --prompt "$PROMPT"

[ "$WAV" != "$IN" ] && rm -f "$WAV"

# 有 opencc 就把簡體轉成台灣繁體與用語
if command -v opencc >/dev/null; then
  for f in "$DIR/transcript.txt" "$DIR/transcript.srt"; do
    opencc -i "$f" -o "$f.tmp" -c s2twp.json && mv "$f.tmp" "$f"
  done
fi

echo "完成：$DIR/transcript.txt"

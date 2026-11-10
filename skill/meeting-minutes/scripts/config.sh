# 讀取使用者設定。優先順序：當下的環境變數 > ~/.config/meeting-minutes/config > 預設值
# 由其他腳本 source，不要直接執行。

MM_CONFIG="${MM_CONFIG:-$HOME/.config/meeting-minutes/config}"
# shellcheck disable=SC1090
[ -f "$MM_CONFIG" ] && . "$MM_CONFIG"

export MIC="${MIC:-MacBook}"
export MEETINGS_DIR="${MEETINGS_DIR:-$HOME/Meetings}"
export WHISPER_MODEL="${WHISPER_MODEL:-$HOME/.meeting-minutes/models/ggml-large-v3-turbo.bin}"
export WHISPER_LANG="${WHISPER_LANG:-zh}"
export AUTO_MINUTES="${AUTO_MINUTES:-1}"

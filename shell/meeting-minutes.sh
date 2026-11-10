# meeting-minutes 快捷指令（zsh / bash 通用）
# 由 install.sh 加進 ~/.zshrc，不需要手動 source。

: "${MM_HOME:=$HOME/.meeting-minutes}"
_MM_SKILL="$MM_HOME/skill/meeting-minutes"

# 避免跟之前手動設的 alias 衝突
unalias meeting stt minutes md2pdf meetings 2>/dev/null

meeting()        { bash "$_MM_SKILL/scripts/record.sh" "$@"; }
stt()            { bash "$_MM_SKILL/scripts/transcribe.sh" "$@"; }
minutes()        { bash "$_MM_SKILL/scripts/minutes.sh" "$@"; }
md2pdf()         { python3 "$_MM_SKILL/scripts/md2pdf.py" "$@"; }
meetings()       { ( . "$_MM_SKILL/scripts/config.sh"; mkdir -p "$MEETINGS_DIR" && open "$MEETINGS_DIR" ); }
meeting-setup()  { bash "$MM_HOME/install.sh" "$@"; }
meeting-update() { git -C "$MM_HOME" pull --ff-only && bash "$MM_HOME/install.sh" skill; }

meeting-help() {
  cat <<'EOF'
會議記錄快捷指令

  錄音與整理
    meeting [名稱]        開始錄音，按 q 結束 → 逐字稿 → md → pdf
    stt <錄音檔>          只轉逐字稿（wav / m4a / mp3）
    minutes [資料夾|txt]  整理成 minutes.md + minutes.pdf（不給參數 = 最新一場）
    md2pdf <minutes.md>   只把 md 轉成 pdf（加 --html 會留下網頁版）
    meetings              打開會議資料夾

  臨時改設定（只影響這一次）
    MIC=iPhone meeting 週會       用 iPhone 收音
    AUTO_MINUTES=0 meeting 週會   錄完只轉逐字稿
    WHISPER_LANG=en stt a.wav     英文會議

  設定與維護
    meeting-setup          重新跑完整設定
    meeting-setup mic      重新選麥克風
    meeting-setup model    換 Whisper 模型
    meeting-setup folder   改會議資料夾
    meeting-setup test     錄 3 秒測試麥克風
    meeting-setup check    查看目前狀態
    meeting-update         從 GitHub 更新到最新版
EOF
}

#!/bin/bash
# meeting-minutes 安裝程式（macOS）
#
# 一行安裝：
#   curl -fsSL https://raw.githubusercontent.com/heykaiyi/meeting-minutes/main/install.sh | bash
# 或先 clone：
#   git clone https://github.com/heykaiyi/meeting-minutes.git ~/.meeting-minutes && bash ~/.meeting-minutes/install.sh
#
# 只重做某一步：bash install.sh [deps|model|mic|folder|skill|shell|test|check]
# 裝好之後也可以用 meeting-setup [同上] 重新設定。

set -uo pipefail

REPO_URL="${MM_REPO:-https://github.com/heykaiyi/meeting-minutes.git}"
CONFIG_DIR="$HOME/.config/meeting-minutes"
CONFIG="$CONFIG_DIR/config"
SKILLS_DIR="$HOME/.claude/skills"
MARK_BEGIN="# >>> meeting-minutes >>>"
MARK_END="# <<< meeting-minutes <<<"
HF="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

# ───────────── 外觀 ─────────────
if [ -t 1 ]; then B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B= D= G= Y= R= N=; fi
step() { printf '\n%s▍%s%s\n' "$B" "$1" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$1"; }
fail() { printf '  %s✗%s %s\n' "$R" "$N" "$1"; }
info() { printf '  %s%s%s\n' "$D" "$1" "$N"; }

# 互動輸入：curl | bash 時 stdin 是腳本本身，所以從 /dev/tty 讀；沒有終端機就用預設值
ask() {
  local prompt="$1" default="${2:-}" answer=""
  if [ -r /dev/tty ] && [ -z "${MM_YES:-}" ]; then
    printf '  %s%s%s ' "$B" "$prompt" "$N" > /dev/tty
    [ -n "$default" ] && printf '%s[%s]%s ' "$D" "$default" "$N" > /dev/tty
    IFS= read -r answer < /dev/tty || true
  fi
  printf '%s' "${answer:-$default}"
}
yes_no() { case "$(ask "$1 (y/n)" "${2:-y}")" in [Yy]*) return 0 ;; *) return 1 ;; esac; }

# ───────────── 找到（或下載）repo ─────────────
SELF_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "$SELF_DIR" ] && [ -d "$SELF_DIR/skill/meeting-minutes" ]; then
  MM_HOME="$SELF_DIR"
else
  MM_HOME="${MM_HOME:-$HOME/.meeting-minutes}"
  if [ -d "$MM_HOME/.git" ]; then
    git -C "$MM_HOME" pull --ff-only -q || true
  else
    command -v git >/dev/null || { echo "需要 git：請先執行 xcode-select --install"; exit 1; }
    git clone -q "$REPO_URL" "$MM_HOME" || { echo "下載失敗：$REPO_URL"; exit 1; }
  fi
fi
SKILL_SRC="$MM_HOME/skill/meeting-minutes"

# ───────────── 設定檔 ─────────────
load_config() {
  # 不要被目前 shell 的環境變數影響：先清空，讀設定檔，再補預設值
  unset MIC MEETINGS_DIR WHISPER_MODEL WHISPER_LANG AUTO_MINUTES
  # shellcheck disable=SC1090
  [ -f "$CONFIG" ] && . "$CONFIG"
  MIC="${MIC:-MacBook}"; MEETINGS_DIR="${MEETINGS_DIR:-$HOME/Meetings}"
  WHISPER_MODEL="${WHISPER_MODEL:-$MM_HOME/models/ggml-large-v3-turbo.bin}"
  WHISPER_LANG="${WHISPER_LANG:-zh}"; AUTO_MINUTES="${AUTO_MINUTES:-1}"
}
save_config() {
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG" <<EOF
# meeting-minutes 設定（meeting-setup 會改寫這個檔）
# 寫成 \${變數:-值} 的形式，讓臨時的環境變數（例如 MIC=iPhone meeting）可以蓋過設定
MIC="\${MIC:-$MIC}"
MEETINGS_DIR="\${MEETINGS_DIR:-$MEETINGS_DIR}"
WHISPER_MODEL="\${WHISPER_MODEL:-$WHISPER_MODEL}"
WHISPER_LANG="\${WHISPER_LANG:-$WHISPER_LANG}"
AUTO_MINUTES="\${AUTO_MINUTES:-$AUTO_MINUTES}"
EOF
}
load_config

# ───────────── 1. 套件 ─────────────
do_deps() {
  step "1. 安裝套件（ffmpeg、whisper.cpp、opencc）"
  if [ "$(uname)" != "Darwin" ]; then
    warn "這套工具是給 macOS 用的（錄音靠 AVFoundation），目前系統是 $(uname)。"
  fi
  if ! command -v brew >/dev/null; then
    fail "沒有 Homebrew。請先到 https://brew.sh 複製安裝指令執行，再重跑這個安裝程式。"
    exit 1
  fi
  local pkg bin
  for pair in "ffmpeg:ffmpeg" "whisper-cpp:whisper-cli" "opencc:opencc"; do
    pkg="${pair%%:*}"; bin="${pair##*:}"
    if command -v "$bin" >/dev/null; then
      ok "$pkg 已安裝"
    else
      info "安裝 $pkg…"
      if brew install "$pkg" >/dev/null; then ok "$pkg 安裝完成"; else fail "$pkg 安裝失敗，請手動執行：brew install $pkg"; fi
    fi
  done

  local chrome=""
  for app in "Google Chrome" "Microsoft Edge" "Brave Browser" "Chromium"; do
    [ -d "/Applications/$app.app" ] && { chrome="$app"; break; }
  done
  if [ -n "$chrome" ]; then ok "轉 PDF 會用 $chrome"; else warn "沒找到 Chrome / Edge / Brave，轉 PDF 需要其中一個"; fi

  if command -v claude >/dev/null; then
    ok "Claude Code 已安裝，錄完會自動整理成 md 和 pdf"
  else
    warn "沒有 Claude Code（claude 指令）。錄音和逐字稿照常可用；整理 md/pdf 需要 Claude Code，或把 txt 丟給 Claude。"
  fi
}

# ───────────── 2. Whisper 模型 ─────────────
model_ok() { [ -s "$1" ] && [ "$(wc -c < "$1")" -gt 10000000 ]; }

do_model() {
  step "2. Whisper 語音辨識模型"
  if model_ok "$WHISPER_MODEL" && [ "${1:-}" != "force" ]; then
    ok "已設定：$WHISPER_MODEL"
    yes_no "要換一個模型嗎？" n || return 0
  fi

  # 之前手動下載過的模型直接沿用
  for f in "$HOME/ggml-large-v3-turbo.bin" "$HOME/Downloads/ggml-large-v3-turbo.bin"; do
    if model_ok "$f" && [ "$f" != "$WHISPER_MODEL" ]; then
      if yes_no "找到之前下載的 $f，直接用它？" y; then
        WHISPER_MODEL="$f"; save_config; ok "模型：$f"; return 0
      fi
    fi
  done

  echo "  可選的模型（越大越準、越慢）："
  echo "    1) large-v3-turbo  1.6 GB  推薦：準確又快"
  echo "    2) medium          1.5 GB"
  echo "    3) small           0.5 GB  舊電腦或只想快速試用"
  local choice name
  choice="$(ask "選哪一個？" 1)"
  case "$choice" in 2) name="medium" ;; 3) name="small" ;; *) name="large-v3-turbo" ;; esac

  mkdir -p "$MM_HOME/models"
  local dest="$MM_HOME/models/ggml-$name.bin"
  if model_ok "$dest"; then
    ok "已經下載過：$dest"
  else
    info "下載 ggml-$name.bin（可以中斷，重跑會接續下載）…"
    if ! curl -L --fail -C - --progress-bar -o "$dest.part" "$HF/ggml-$name.bin"; then
      fail "下載失敗，請檢查網路後執行：meeting-setup model"; return 1
    fi
    mv "$dest.part" "$dest"
    ok "下載完成"
  fi
  WHISPER_MODEL="$dest"; save_config
  ok "模型：$dest"
}

# ───────────── 3. 麥克風 ─────────────
do_mic() {
  step "3. 選擇麥克風"
  if ! command -v ffmpeg >/dev/null; then fail "需要先裝 ffmpeg"; return 1; fi
  local devices names i=0 default=0 first_real=0 n
  devices="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
    | awk '/audio devices:/{a=1; next} a' | sed -E 's/.*\] \[[0-9]+\] //')"
  if [ -z "$devices" ]; then fail "沒有偵測到音訊裝置"; return 1; fi

  names=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    i=$((i + 1)); names+=("$line")
    local note=""
    case "$line" in
      *Teams*|*Zoom*|*BlackHole*|*Loopback*|*Aggregate*) note=" ${D}(虛擬裝置，錄不到現場聲音)${N}" ;;
      *)
        [ "$first_real" = 0 ] && first_real=$i
        case "$line" in *"$MIC"*) [ "$default" = 0 ] && default=$i ;; esac ;;
    esac
    printf '    %d) %s%s\n' "$i" "$line" "$note"
  done <<< "$devices"
  [ "$default" = 0 ] && default="$first_real"
  [ "$default" = 0 ] && default=1

  n="$(ask "現場會議要用哪一個？" "$default")"
  case "$n" in ''|*[!0-9]*) n="$default" ;; esac
  [ "$n" -ge 1 ] && [ "$n" -le "${#names[@]}" ] || n="$default"
  MIC="${names[$((n - 1))]}"
  save_config
  ok "麥克風：$MIC"
  info "臨時換成 iPhone：MIC=iPhone meeting 週會"
}

# ───────────── 4. 會議資料夾 ─────────────
do_folder() {
  step "4. 會議檔案存放位置"
  local d
  d="$(ask "每場會議會放在這個資料夾底下：" "$MEETINGS_DIR")"
  d="${d/#\~/$HOME}"
  mkdir -p "$d" && MEETINGS_DIR="$d" && save_config && ok "會議資料夾：$MEETINGS_DIR"
}

# ───────────── 5. Claude skill ─────────────
do_skill() {
  step "5. 安裝 Claude skill"
  mkdir -p "$SKILLS_DIR"
  local target="$SKILLS_DIR/meeting-minutes"
  if [ -L "$target" ]; then
    rm "$target"
  elif [ -e "$target" ]; then
    local bak="$target.bak-$(date +%Y%m%d%H%M%S)"
    mv "$target" "$bak"
    warn "原本的 skill 已備份到 $bak"
  fi
  ln -s "$SKILL_SRC" "$target"
  chmod +x "$SKILL_SRC"/scripts/*.sh "$SKILL_SRC"/scripts/*.py 2>/dev/null || true
  ok "已連結到 $target（之後 meeting-update 就會一起更新）"
}

# ───────────── 6. 快捷指令 ─────────────
rc_files() {
  local files=()
  case "${SHELL:-}" in
    *bash) files+=("$HOME/.bash_profile") ;;
    *)     files+=("$HOME/.zshrc") ;;
  esac
  printf '%s\n' "${files[@]}"
}

do_shell() {
  step "6. 設定快捷指令"
  local rc
  while IFS= read -r rc; do
    touch "$rc"
    # 先移除舊的區塊再寫入，重跑不會重複
    if grep -qF "$MARK_BEGIN" "$rc"; then
      awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1; next} $0==e{skip=0; next} !skip' "$rc" > "$rc.mm-tmp" && mv "$rc.mm-tmp" "$rc"
    fi
    {
      echo "$MARK_BEGIN"
      echo "export MM_HOME=\"$MM_HOME\""
      echo "[ -f \"\$MM_HOME/shell/meeting-minutes.sh\" ] && . \"\$MM_HOME/shell/meeting-minutes.sh\""
      echo "$MARK_END"
    } >> "$rc"
    ok "已寫入 $rc"

    # 提醒之前手動加的同名函式（新的會蓋過，但留著容易混淆）
    if grep -nE '^(rec|stt|memo)\(\)' "$rc" >/dev/null 2>&1; then
      warn "$rc 裡還有之前手動加的 rec / stt / memo 函式，可以刪掉："
      grep -nE '^(rec|stt|memo)\(\)' "$rc" | sed 's/^/      第 /; s/:/ 行：/' | cut -c1-80
    fi
  done < <(rc_files)
}

# ───────────── 7. 錄音測試 ─────────────
do_test() {
  step "7. 錄音測試"
  yes_no "要錄 3 秒測試麥克風嗎？（第一次會跳出麥克風權限視窗，請按允許）" y || { info "略過"; return 0; }
  local idx line tmp vol
  line="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | awk '/audio devices:/{a=1; next} a' | grep -iF -- "$MIC" | head -1)"
  [ -n "$line" ] || { fail "找不到麥克風「$MIC」，請執行 meeting-setup mic"; return 1; }
  idx="$(printf '%s' "$line" | sed -E 's/.*\] \[([0-9]+)\] .*/\1/')"
  tmp="$(mktemp "${TMPDIR:-/tmp}/mmtest.XXXXXX").wav"
  echo "  請對著麥克風說幾句話…"
  ffmpeg -hide_banner -loglevel error -y -f avfoundation -i ":$idx" -t 3 -ac 1 -ar 16000 "$tmp" < /dev/null
  if [ ! -s "$tmp" ]; then
    fail "沒有錄到檔案。請到「系統設定 → 隱私權與安全性 → 麥克風」允許 Terminal，再執行 meeting-setup test"
    return 1
  fi
  vol="$(ffmpeg -hide_banner -i "$tmp" -af volumedetect -f null - 2>&1 | sed -nE 's/.*max_volume: (-?[0-9.]+) dB.*/\1/p')"
  rm -f "$tmp"
  if [ -z "$vol" ]; then
    warn "錄到了，但無法判斷音量"
  elif awk -v v="$vol" 'BEGIN{exit !(v < -50)}'; then
    warn "錄到的幾乎是靜音（最大音量 ${vol} dB）。可能選錯麥克風或沒有權限：meeting-setup mic"
  else
    ok "麥克風正常（最大音量 ${vol} dB）"
  fi
}

# ───────────── 檢查 ─────────────
do_check() {
  step "目前狀態"
  load_config
  for b in ffmpeg whisper-cli opencc claude; do
    if command -v "$b" >/dev/null; then ok "$b"; else warn "$b 未安裝"; fi
  done
  if model_ok "$WHISPER_MODEL"; then ok "模型：$WHISPER_MODEL"; else warn "模型不存在：$WHISPER_MODEL"; fi
  ok "麥克風關鍵字：$MIC"
  ok "會議資料夾：$MEETINGS_DIR"
  if [ -L "$SKILLS_DIR/meeting-minutes" ]; then ok "skill：$SKILLS_DIR/meeting-minutes"; else warn "skill 尚未安裝"; fi
  ok "設定檔：$CONFIG"
}

finish() {
  step "完成"
  cat <<EOF
  重新開一個 Terminal 視窗（或執行 ${B}source ~/.zshrc${N}）之後就能用：

    ${B}meeting 週會${N}        開始錄音，按 q 結束，自動產生逐字稿、md、pdf
    ${B}stt 檔案${N}            只轉逐字稿（wav / m4a / mp3）
    ${B}minutes${N}             把最新一場會議整理成 md + pdf
    ${B}md2pdf minutes.md${N}   只把 md 轉成 pdf
    ${B}meetings${N}            打開會議資料夾
    ${B}meeting-help${N}        查看所有指令

EOF
}

# ───────────── 主程式 ─────────────
case "${1:-all}" in
  all)
    printf '%smeeting-minutes 安裝程式%s\n' "$B" "$N"
    info "程式位置：$MM_HOME"
    do_deps; do_model; do_mic; do_folder; do_skill; do_shell; do_test; finish ;;
  deps)   do_deps ;;
  model)  do_model force ;;
  mic)    do_mic ;;
  folder) do_folder ;;
  skill)  do_skill ;;
  shell)  do_shell ;;
  test)   do_test ;;
  check)  do_check ;;
  *) echo "用法：bash install.sh [all|deps|model|mic|folder|skill|shell|test|check]"; exit 1 ;;
esac

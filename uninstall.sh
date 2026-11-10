#!/bin/bash
# 移除 meeting-minutes。不會刪除你的會議檔案，也不會移除 brew 套件。
set -uo pipefail

MM_HOME="${MM_HOME:-$(cd "$(dirname "$0")" && pwd)}"
MARK_BEGIN="# >>> meeting-minutes >>>"
MARK_END="# <<< meeting-minutes <<<"

ask() { local a=""; printf '%s (y/n) [n] ' "$1" > /dev/tty 2>/dev/null; IFS= read -r a < /dev/tty 2>/dev/null || true; case "$a" in [Yy]*) return 0 ;; *) return 1 ;; esac; }

for rc in "$HOME/.zshrc" "$HOME/.bash_profile"; do
  [ -f "$rc" ] && grep -qF "$MARK_BEGIN" "$rc" || continue
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1; next} $0==e{skip=0; next} !skip' "$rc" > "$rc.mm-tmp" && mv "$rc.mm-tmp" "$rc"
  echo "✓ 已從 $rc 移除快捷指令"
done

if [ -L "$HOME/.claude/skills/meeting-minutes" ]; then
  rm "$HOME/.claude/skills/meeting-minutes"
  echo "✓ 已移除 Claude skill"
fi

if [ -d "$HOME/.config/meeting-minutes" ] && ask "刪除設定檔 ~/.config/meeting-minutes？"; then
  rm -rf "$HOME/.config/meeting-minutes"; echo "✓ 已刪除設定檔"
fi

if [ -d "$MM_HOME/models" ] && ask "刪除下載的 Whisper 模型（$(du -sh "$MM_HOME/models" | cut -f1)）？"; then
  rm -rf "$MM_HOME/models"; echo "✓ 已刪除模型"
fi

echo
echo "會議檔案沒有動到。brew 套件如果也不需要了，可以執行：brew uninstall whisper-cpp opencc"
echo "最後刪掉程式資料夾即可：rm -rf \"$MM_HOME\""

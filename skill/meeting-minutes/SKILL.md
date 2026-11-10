---
name: meeting-minutes
description: 用 Mac 的 ffmpeg 錄下實體會議，用 whisper.cpp 轉成逐字稿，再整理成固定格式的 Markdown 會議記錄，最後輸出成黑白極簡風格的 PDF。使用者說「錄會議」「開始錄音」「整理會議記錄」「逐字稿轉 md / pdf」，或給你一個會議 .wav / .txt 要整理時使用。
---

# 會議記錄：錄音 → 逐字稿 → Markdown → PDF

整條流程分四步。每一步都可以單獨執行，例如使用者只給你一個 `.txt`，就從第 3 步開始。

```
record.sh ──> audio.wav ──> transcribe.sh ──> transcript.txt ──> (你整理) ──> minutes.md ──> md2pdf.py ──> minutes.pdf
```

每場會議都放在自己的資料夾，預設是 `~/Meetings/<日期_時間_會議名稱>/`：

```
~/Meetings/2026-11-10_1530_週會/
├── audio.wav          錄音（16kHz 單聲道）
├── transcript.txt     whisper 逐字稿
├── transcript.srt     有時間軸的逐字稿（回頭查某句話用）
├── minutes.md         整理後的會議記錄（固定格式）
└── minutes.pdf        黑白極簡版型的 PDF
```

`SKILL_DIR` 指的是這份 SKILL.md 所在的資料夾（通常是 `~/.claude/skills/meeting-minutes`）。

使用者如果是用 repo 的 `install.sh` 安裝，terminal 裡會有這些快捷指令，跟使用者說明時優先講這些：

| 指令 | 做什麼 |
|---|---|
| `meeting 週會` | 錄音 → 逐字稿 → md → pdf 一次跑完 |
| `stt 檔案` | 只轉逐字稿 |
| `minutes [資料夾]` | 把逐字稿整理成 md 和 pdf（不給參數就用最新一場） |
| `md2pdf minutes.md` | 只把 md 轉成 pdf |
| `meetings` | 打開會議資料夾 |
| `meeting-setup` | 重新設定麥克風、模型、資料夾 |

設定存在 `~/.config/meeting-minutes/config`（`MIC`、`MEETINGS_DIR`、`WHISPER_MODEL`、`WHISPER_LANG`、`AUTO_MINUTES`）。所有腳本都會讀它；當下的環境變數優先。

## 第 1 步：錄音

```bash
bash SKILL_DIR/scripts/record.sh 週會
```

- 按 `q` 結束錄音。結束後腳本會自動接著跑第 2 步，並用 `scripts/minutes.sh` 呼叫 Claude Code 跑第 3、4 步。
- 麥克風用**名稱**比對，不用編號，因為 iPhone 連上或斷開時編號會跑掉。關鍵字來自設定檔的 `MIC`。臨時改用 iPhone 收音就加 `MIC=iPhone`。
- 錄音要使用者自己在 terminal 執行（要按 `q` 才會停）。不要在背景幫使用者啟動錄音。

## 第 2 步：轉逐字稿

```bash
bash SKILL_DIR/scripts/transcribe.sh ~/Meetings/2026-11-10_1530_週會/audio.wav
```

會在同一個資料夾產生 `transcript.txt` 和 `transcript.srt`。有裝 `opencc` 的話會自動把簡體轉成台灣繁體。

模型路徑來自設定檔的 `WHISPER_MODEL`（預設 `~/.meeting-minutes/models/ggml-large-v3-turbo.bin`）。一小時的錄音在 M 系列 Mac 上大約要幾分鐘。

## 第 3 步：把逐字稿整理成 minutes.md（這一步由你來做）

1. 讀 `transcript.txt`。需要時間資訊時讀 `transcript.srt`（最後一段的時間戳就是會議長度）。
2. 讀 `SKILL_DIR/assets/template.md`，**完全照它的結構寫**：標題、資訊表、章節名稱和順序都不能改，也不能自己加章節。`md2pdf.py` 是照這個結構排版的。
3. 寫入同一個資料夾的 `minutes.md`。

整理時的規則：

- **用台灣繁體中文和台灣用語**（軟體、資料、影片、品質），就算逐字稿是簡體也一樣。
- **逐字稿是語音辨識結果，一定有錯字。** 依上下文修正明顯的同音錯字和專有名詞。改不確定的就不要猜，放進「待確認」。
- **不要編造。** 沒提到的負責人、期限寫「未指定」；看不出與會者就寫「未記錄」。資訊不足的地方寧可留白，也不要補上逐字稿裡沒有的內容。
- **整理，不是逐句搬運。** 「討論重點」依主題分組，不照時間順序。每組用一個小標題，底下 2–5 個重點。口語贅詞、重複、離題閒聊都去掉。
- **決議和待辦要分清楚。** 決議是「大家同意了什麼」；待辦是「誰要去做什麼」。待辦一律用動詞開頭（例如「整理 Q4 預算表」）。
- 會議名稱優先用使用者給的名稱，其次用資料夾名稱，最後才從內容推斷。
- 日期時間從資料夾名稱取得（格式 `YYYY-MM-DD_HHMM_名稱`），取不到就用檔案的修改時間。

## 第 4 步：輸出 PDF

```bash
python3 SKILL_DIR/scripts/md2pdf.py ~/Meetings/2026-11-10_1530_週會/minutes.md
```

會在旁邊產生 `minutes.pdf`。版型是 Tailwind CSS 設計的黑白極簡風格：A4、圓角卡片、黑底摘要、編號決議、待辦表格（負責人用膠囊標籤），首頁頂端有 10px 全寬黑色色條，右下角有頁碼。

- 圖示只出現在會議資訊列（日期、時長、與會者），用 Solar Bold Duotone（存在 `assets/icons.json`，已改成 `currentColor`）。章節標題、badge、摘要、footer 都不放圖示。
- 資訊列只顯示「日期、時長、與會者」，用圖示代替標籤，不要在 md 裡加回「記錄方式」這類欄位。
- 版面結構和 Tailwind class 寫在 `md2pdf.py` 的各個 `sec_*` 函式裡；`assets/tailwind.css` 是預先編譯好的 CSS，所以**不需要網路**；`assets/print.css` 管 A4 頁邊距、首頁色條和頁碼。
- 改了 class 之後，如果新 class 不在 `tailwind.css` 裡，加 `--cdn` 改用 Tailwind 官方 CDN 即時編譯（需要網路）。
- 需要 Google Chrome、Microsoft Edge、Brave 或 Chromium 其中一個（用無頭模式列印 PDF）。輸出的是向量文字，可以選取、搜尋、複製。
- 只用 Python 標準函式庫，不需要 pip 安裝任何東西。
- 加 `--html` 會同時留下 HTML 檔，用瀏覽器打開就能預覽版型。

產生 PDF 之後，用 `open minutes.pdf` 打開給使用者看，並用一兩句話說明會議重點和待辦數量。不要把整份記錄再貼一次到對話裡。

## 常見問題

| 狀況 | 處理方式 |
|---|---|
| 錄音的 `speed` 遠低於 1x、`time` 比實際時間少很多 | 錄到虛擬裝置了（例如 Microsoft Teams Audio）。用 `MIC=MacBook` 指定麥克風 |
| `找不到符合「…」的麥克風` | 執行 `meeting-setup mic` 重新選擇，或用 `MIC=` 臨時指定 |
| 逐字稿是簡體 | `brew install opencc`，再重跑 `transcribe.sh` |
| 逐字稿一直重複同一句 | whisper 在長時間靜音時偶爾會這樣。整理時直接略過重複段落 |
| `找不到 Chrome` | 安裝 Google Chrome，或用 `CHROME=瀏覽器執行檔路徑` 指定 |
| PDF 中文顯示成方塊 | 系統缺字型。Mac 內建 PingFang TC，一般不會發生 |

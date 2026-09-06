# CUPS Watermark Filter v5 — PDF-Overlay 架構

在每個列印頁面自動疊印浮水印（45度、淺灰色、三行文字），採用
**PostScript → PDF → Python 疊印 → PostScript** 的穩健架構，
取代 v1~v4 直接修改 PostScript 文字的脆弱做法。

---

## 為何改用這個架構（相對於 v1~v4）

| 問題（v1~v4 遇到的）| v5 的解法 |
|---------------------|-----------|
| HP 驅動程式內建的錯誤處理碼含有 `showpage` 字樣，誤判插入點 | PDF 有明確頁面物件結構，用 `pikepdf` 操作不會誤判文字片段 |
| 浮水印插入順序錯誤，被原內容蓋掉 | `pikepdf.Page.add_overlay()` 保證疊在現有內容之上 |
| 不同來源（PS/PDF）需要不同處理分支，行為不一致 | 已確認所有來源皆為 PostScript（HP UPS Driver + Passthrough 關閉），架構單一化 |
| PostScript DSC 結構解析容易因驅動版本不同而失準 | 完全不解析 PostScript 結構，交給 Ghostscript 處理 |

---

## 前提條件（已由管理者確認並落實）

1. 所有 Windows 用戶端強制使用 **HP Universal PS Driver**
2. **PostScript Passthrough 已關閉**
3. 已驗證 AutoCAD / Office / PDF / 純文字 / JPEG 等列印來源，到達 CUPS 時皆為 `application/postscript`
4. 不開放 BYOD 或 Web UI 直接上傳檔案列印

---

## 架構流程

```
Windows PC（任何應用程式）
        ↓ HP Universal PS Driver
CUPS 收到：application/postscript
        ↓
[cups-watermark-filter]
   1. 安全檢查：確認輸入確實是 PS/PJL（非 PS 直接拒絕）
   2. 解析 PJL header → 取得 userid / hostname / 列印時間
   3. Ghostscript：PostScript → PDF
   4. pikepdf + reportlab：逐頁疊印浮水印
        - 讀取每頁 MediaBox，自動適應紙張尺寸與轉向
        - 45度旋轉、淺灰色、三行文字（userid / hostname+IP / datetime）
        - add_overlay() 疊在原內容之上
   5. Ghostscript：PDF → PostScript（送印表機）
        ↓
HP M428fdn
```

---

## 浮水印內容

| 行 | 來源 | 範例 |
|----|------|------|
| 1 | PJL `JobAcct1`（username）| `royhu` |
| 2 | PJL `JobAcct2`（hostname）+ CUPS `REMOTE_HOST`（真實IP，不可偽造）| `LABR01 / 192.168.11.117` |
| 3 | PJL `JobAcct4`（列印時間）| `2026-06-19 21:12:00` |

---

## 檔案清單

```
cups-watermark-v2/
├── cups-watermark-filter      # 主程式（Python3 CUPS filter）
├── watermark.convs            # CUPS MIME conversion 規則
├── install.sh                 # 安裝腳本（含套件檢查）
├── uninstall.sh                # 解除安裝腳本
├── test-watermark.sh          # 離線測試腳本（含 PNG 預覽產生）
├── restrict-to-postscript.sh  # 限制佇列只接受 PostScript（建議執行）
└── README.md                  # 本文件
```

---

## 安裝步驟

### 1. 前置需求確認

```bash
python3 --version
gs --version          # Ghostscript，若無：apt install ghostscript
systemctl status cups
```

### 2. 執行安裝腳本

```bash
cd cups-watermark-v2
./install.sh
```

安裝腳本會自動：
- 檢查並安裝 `pikepdf`、`reportlab`（若缺少）
- 複製 filter 到 `/usr/lib/cups/filter/`
- 複製 MIME 規則到 `/etc/cups/watermark.convs`
- 重啟 CUPS

### 3.（強烈建議）限制佇列只接受 PostScript

```bash
./restrict-to-postscript.sh hpm428fdn
```

這是系統層的第二道防線：即使有人嘗試用非標準方式送入其他格式，
CUPS 會直接拒絕，不會進入未經測試的分支。

### 4. 離線測試

```bash
# 先保留 spool 檔案以便測試
cupsctl PreserveJobFiles=86400
systemctl restart cups

# 從 Windows 重新列印一次測試頁，立即查看 spool 目錄
ls -la /var/spool/cups/

# 用實際 spool 檔測試（含自動產生 PNG 預覽）
./test-watermark.sh /var/spool/cups/dXXXXXX-001

# 查看預覽圖（會印出路徑，類似 /tmp/watermark-test-XXXX/preview-1.png）
```

### 5. 實際列印測試

從 Windows PC 列印測試頁，確認浮水印正確疊印在最上層。

---

## 監控與除錯

```bash
# 即時監看 filter 執行記錄
journalctl -f | grep cups-watermark

# CUPS 詳細 filter chain 記錄
tail -f /var/log/cups/error_log | grep -i watermark
```

### 常見訊息與意義

| 訊息 | 意義 | 處理方式 |
|------|------|----------|
| `Watermark applied: job=... user=... host_ip=... dt=...` | 正常完成 | 無需處理 |
| `ps2pdf failed (rc=...)` | Ghostscript 轉換 PS→PDF 失敗，通常是輸入 PS 本身有語法問題 | 檢查該筆 spool 檔，確認來源應用程式/驅動是否異常 |
| `watermark overlay failed` | pikepdf/reportlab 疊印階段失敗，但仍會送印（不含浮水印）| 檢查 PDF 頁面結構是否異常（極少數情況）|
| `pdf_to_ps failed` | PDF→PS 轉換失敗，會改送 PDF 直接給印表機 | 確認印表機是否能直接接受 PDF |
| `input does not look like PostScript/PJL` | 收到非預期格式，已被拒絕 | 確認 Windows 端驅動設定是否被誤改 |

---

## 自訂浮水印樣式

編輯 `/usr/lib/cups/filter/cups-watermark-filter`，修改
`create_watermark_overlay_pdf()` 呼叫處或函數預設參數：

```python
def create_watermark_overlay_pdf(page_width_pt, page_height_pt, lines,
                                  gray=0.55, alpha=0.40, base_fontsize=28):
```

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `gray` | `0.55` | 灰階值（0=黑, 1=白）。數字越大越淺 |
| `alpha` | `0.40` | 透明度（0=完全透明, 1=完全不透明）|
| `base_fontsize` | `28` | A4 直向（短邊595pt）基準字型大小，其他尺寸自動等比例縮放 |

修改後重啟 CUPS：`systemctl restart cups`

---

## 效能參考

根據實測（A4 雙頁文件，含文字內容）：

| 階段 | 耗時參考 |
|------|---------|
| PostScript → PDF（Ghostscript）| < 1 秒 |
| 浮水印疊印（pikepdf + reportlab）| < 0.5 秒 |
| PDF → PostScript（Ghostscript）| < 1 秒 |
| **總計** | **約 1-3 秒/工作**（視頁數與圖片含量增加）|

對一般辦公文件（文字為主、少量圖片），現有硬體應已足夠；
若大量列印高解析度圖片或工程圖，建議：CPU 4 核心、RAM 4GB 以上。

---

## 解除安裝

```bash
./uninstall.sh

# 若曾執行 restrict-to-postscript.sh，需另外還原：
lpadmin -p hpm428fdn -o document-format-default=auto
```

#!/bin/bash
# =============================================================================
# 離線測試腳本：用 spool 副本驗證浮水印效果，並輸出可視覺檢查的 PNG 預覽
#
# 用法：./test-watermark.sh [spool_file]
# =============================================================================

FILTER="/usr/lib/cups/filter/cups-watermark-filter"
SPOOL_FILE="${1:?用法: ./test-watermark.sh /var/spool/cups/dXXXXXX-001}"
OUTDIR="/tmp/watermark-test-$$"

echo "======================================================"
echo " CUPS Watermark Filter v5 離線測試"
echo "======================================================"
echo " 輸入 spool 檔：$SPOOL_FILE"
echo " 輸出目錄：$OUTDIR"
echo "======================================================"

if [ ! -f "$FILTER" ]; then
    echo "[ERROR] Filter 尚未安裝：$FILTER"
    exit 1
fi

if [ ! -f "$SPOOL_FILE" ]; then
    echo "[ERROR] Spool 檔案不存在：$SPOOL_FILE"
    echo "        先執行：cupsctl PreserveJobFiles=86400 && systemctl restart cups"
    echo "        再重新列印一次，並用 ls -la /var/spool/cups/ 找到正確檔名"
    exit 1
fi

mkdir -p "$OUTDIR"

echo ""
echo "[1/3] 執行 filter..."
env REMOTE_HOST="192.168.11.117" \
  python3 "$FILTER" \
  999 testuser "TestPage" 1 "" "$SPOOL_FILE" \
  > "$OUTDIR/output.ps" 2> "$OUTDIR/stderr.txt"

RESULT=$?
echo "exit code: $RESULT"

if [ -s "$OUTDIR/stderr.txt" ]; then
    echo ""
    echo "--- stderr ---"
    cat "$OUTDIR/stderr.txt"
fi

echo ""
echo "[2/3] 輸出檔案資訊..."
ls -la "$OUTDIR/output.ps" "$SPOOL_FILE"

echo ""
echo "[3/3] 產生 PNG 預覽（供視覺檢查浮水印位置與疊印效果）..."
if command -v gs &>/dev/null; then
    gs -dNOPAUSE -dBATCH -sDEVICE=png16m -r100 \
       -sOutputFile="$OUTDIR/preview-%d.png" \
       "$OUTDIR/output.ps" 2>/dev/null
    echo ""
    echo "預覽圖片："
    ls -la "$OUTDIR"/preview-*.png 2>/dev/null
else
    echo "[WARN] 找不到 gs，無法產生預覽圖"
fi

echo ""
echo "======================================================"
echo " 測試完成，請查看以下檔案："
echo "   $OUTDIR/output.ps          (最終 PostScript)"
echo "   $OUTDIR/preview-*.png      (各頁視覺預覽)"
echo "======================================================"

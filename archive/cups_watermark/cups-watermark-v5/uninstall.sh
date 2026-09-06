#!/bin/bash
# =============================================================================
# CUPS Watermark Filter v5 解除安裝腳本
# 需以 root 執行：./uninstall.sh
# =============================================================================

set -e

echo "======================================================"
echo " CUPS Watermark Filter v5 解除安裝"
echo "======================================================"

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 請以 root 執行：./uninstall.sh"
    exit 1
fi

for f in \
    /usr/lib/cups/filter/cups-watermark-filter \
    /etc/cups/watermark.convs \
    /etc/cups/watermark.types
do
    if [ -f "$f" ]; then
        rm -f "$f"
        echo "[REMOVED] $f"
    else
        echo "[SKIP]    $f 不存在"
    fi
done

echo ""
echo "重啟 CUPS..."
systemctl restart cups
sleep 2
if systemctl is-active --quiet cups; then
    echo "[OK] CUPS 已重啟，浮水印 filter 已完全移除"
else
    echo "[ERROR] CUPS 重啟失敗，請手動檢查"
    journalctl -u cups -n 10 --no-pager
fi
echo "======================================================"
echo ""
echo "注意：document-format-default 限制設定（若曾執行過"
echo "      restrict-to-postscript.sh）需另外手動還原："
echo "      lpadmin -p hpm428fdn -o document-format-default=auto"
echo "======================================================"

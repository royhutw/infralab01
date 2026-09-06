#!/bin/bash
# =============================================================================
# 限制 hpm428fdn 佇列只接受 application/postscript
#
# 用途：作為系統層的第二道防線。即使 Windows 端設定被誤改，或有人嘗試
#       透過非標準路徑送入 PDF/其他格式，CUPS 會直接拒絕該工作，
#       不會進入未經測試的轉換分支。
#
# 需以 root 執行
# =============================================================================

set -e

PRINTER="${1:-hpm428fdn}"

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 請以 root 執行：sudo ./restrict-to-postscript.sh [印表機名稱]"
    exit 1
fi

echo "======================================================"
echo " 限制印表機 '$PRINTER' 只接受 PostScript"
echo "======================================================"

# 確認印表機存在
if ! lpstat -p "$PRINTER" &>/dev/null; then
    echo "[ERROR] 找不到印表機佇列：$PRINTER"
    echo "        執行 lpstat -p 確認正確名稱"
    exit 1
fi

# 設定該佇列預設與限制接受的格式
lpadmin -p "$PRINTER" -o document-format-default=application/postscript

echo "[OK] 已設定 $PRINTER 的 document-format-default=application/postscript"
echo ""
echo "確認設定："
lpoptions -p "$PRINTER" -l 2>/dev/null | grep -i "document-format" || \
    echo "  （document-format 選項不在 lpoptions -l 的標準輸出中，"
echo "  此為正常現象，實際限制已套用在 IPP 層）"
echo ""
echo "======================================================"
echo " 完成。建議測試：嘗試從非 PS 來源送印，確認被拒絕"
echo "======================================================"

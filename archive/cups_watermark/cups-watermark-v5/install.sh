#!/bin/bash
# =============================================================================
# CUPS Watermark Filter v5 安裝腳本（PDF-overlay 架構）
# 適用：Debian 13 / CUPS 2.4.x
# 需以 root 執行：./install.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILTER_SRC="$SCRIPT_DIR/cups-watermark-filter"
FILTER_DST="/usr/lib/cups/filter/cups-watermark-filter"
CONVS_SRC="$SCRIPT_DIR/watermark.convs"
CONVS_DST="/etc/cups/watermark.convs"

echo "======================================================"
echo " CUPS Watermark Filter v5 安裝程式（PDF-overlay 架構）"
echo " 適用：Debian 13 / CUPS 2.4.x"
echo "======================================================"

if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 請以 root 執行：./install.sh"
    exit 1
fi

# --- 檢查 Python3 ---
if ! command -v python3 &>/dev/null; then
    echo "[ERROR] 找不到 python3，請先安裝：apt install python3"
    exit 1
fi
PY3=$(command -v python3)
echo "[OK] Python3：$PY3"

# --- 檢查 Ghostscript ---
if ! command -v gs &>/dev/null; then
    echo "[ERROR] 找不到 ghostscript，請先安裝：apt install ghostscript"
    exit 1
fi
echo "[OK] Ghostscript：$(command -v gs)"

# --- 檢查 / 安裝 Python 套件 ---
echo ""
echo "[檢查 Python 套件 pikepdf / reportlab]"
MISSING_PKGS=""
python3 -c "import pikepdf" 2>/dev/null || MISSING_PKGS="$MISSING_PKGS pikepdf"
python3 -c "import reportlab" 2>/dev/null || MISSING_PKGS="$MISSING_PKGS reportlab"

if [ -n "$MISSING_PKGS" ]; then
    echo "[INFO] 缺少套件：$MISSING_PKGS，嘗試安裝..."
    pip3 install $MISSING_PKGS --break-system-packages
    echo "[OK] 套件安裝完成"
else
    echo "[OK] pikepdf 與 reportlab 皆已安裝"
fi

echo ""

# --- 備份既有檔案 ---
for f in "$FILTER_DST" "$CONVS_DST"; do
    if [ -f "$f" ]; then
        BACKUP="${f}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$f" "$BACKUP"
        echo "[BACKUP] $f → $BACKUP"
    fi
done

# --- 移除舊版殘留檔案（v1~v4 的 watermark.types 已不需要）---
OLD_TYPES="/etc/cups/watermark.types"
if [ -f "$OLD_TYPES" ]; then
    mv "$OLD_TYPES" "${OLD_TYPES}.bak.$(date +%Y%m%d%H%M%S)"
    echo "[REMOVED] 舊版 $OLD_TYPES（已備份，v5 不需要此檔案）"
fi

# --- 安裝 Filter Script ---
echo "[1/3] 安裝 filter → $FILTER_DST"
install -m 755 -o root -g root "$FILTER_SRC" "$FILTER_DST"
sed -i "1s|.*|#!$PY3|" "$FILTER_DST"
echo "      shebang：#!$PY3"

# --- 安裝 MIME Convs ---
echo "[2/3] 安裝 MIME convs → $CONVS_DST"
install -m 644 -o root -g root "$CONVS_SRC" "$CONVS_DST"
echo "      內容："
grep -v '^#' "$CONVS_DST" | grep -v '^$' | sed 's/^/        /'

# --- 重啟 CUPS ---
echo "[3/3] 重啟 CUPS..."
systemctl restart cups
sleep 2
if systemctl is-active --quiet cups; then
    echo "      [OK] CUPS 重啟成功"
else
    echo "      [ERROR] CUPS 重啟失敗"
    journalctl -u cups -n 20 --no-pager
    exit 1
fi

# --- 驗證 ---
echo ""
echo "======================================================"
echo " 驗證安裝"
echo "======================================================"
ls -la "$FILTER_DST"
echo ""
echo "MIME convs："
cat "$CONVS_DST" | grep -v '^#' | grep -v '^$'

echo ""
echo "======================================================"
echo " 安裝完成！"
echo ""
echo " 強烈建議：執行 restrict-to-postscript.sh 限制佇列格式"
echo "   ./restrict-to-postscript.sh hpm428fdn"
echo ""
echo " 測試步驟："
echo "   1. 離線測試："
echo "      ./test-watermark.sh /var/spool/cups/dXXXXXX-001"
echo ""
echo "   2. 實際列印測試頁，確認浮水印疊印在內容上層"
echo ""
echo "   3. 監看 syslog："
echo "      journalctl -f | grep cups-watermark"
echo "======================================================"

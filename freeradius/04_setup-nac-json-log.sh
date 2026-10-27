#!/usr/bin/env bash
# ==============================================================================
#  04_setup-nac-json-log.sh (v1 集中化設定檔版)
#  自動設定 FreeRADIUS 802.1X / MAB 結構化 JSON 稽核日誌 (linelog) 與 Logrotate
#  專供 Wazuh SIEM 收集交換器 IP、實體 Port、MAC 與動態 VLAN 派發結果
#
#  適用系統：Debian 13 (Trixie) / FreeRADIUS 3.2.7
#  前置條件：同目錄下需存在 config.env，且已完成 02_setup-freeradius.sh 部署
# ==============================================================================
set -euo pipefail

# ── [載入共用環境參數設定檔] ─────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"

if [ ! -f "${CONFIG_FILE}" ]; then
    echo "[ERROR] 找不到共用設定檔: ${CONFIG_FILE}" >&2
    exit 1
fi
source "${CONFIG_FILE}"

# 若 config.env 尚未加入第 6 區參數，提供預設Fallback值確保腳本相容性
NAC_AUDIT_LOG_DIR="${NAC_AUDIT_LOG_DIR:-/var/log/freeradius}"
NAC_AUDIT_JSON_FILE="${NAC_AUDIT_JSON_FILE:-${NAC_AUDIT_LOG_DIR}/nac_audit.json}"
LOGROTATE_RETENTION_DAYS="${LOGROTATE_RETENTION_DAYS:-90}"
# ──────────────────────────────────────────────────────────────────────────────

echo "=============================================================================="
echo " 開始設定 FreeRADIUS NAC JSON 結構化稽核日誌與 Logrotate..."
echo "   - 輸出日誌路徑 : ${NAC_AUDIT_JSON_FILE}"
echo "   - 日誌保留天數 : ${LOGROTATE_RETENTION_DAYS} 天 (每日輪替壓縮)"
echo "=============================================================================="

# ── [步驟 1/4] 同步更新 /etc/freeradius/3.0/corp_8021x.env ───────────────────
if [ -n "${INSTALLED_ENV_FILE:-}" ] && [ -d "${FR_CONF_DIR}" ]; then
    cp -f "${CONFIG_FILE}" "${INSTALLED_ENV_FILE}"
    chown root:freerad "${INSTALLED_ENV_FILE}"
    chmod 640 "${INSTALLED_ENV_FILE}"
fi

# ── [步驟 2/4] 建立 linelog_nac_json 模組設定 ────────────────────────────────
echo ""
echo "==> [1/4] 建立 JSON 格式日誌模組 (${FR_CONF_DIR}/mods-available/linelog_nac_json)..."

cat << EOF > "${FR_CONF_DIR}/mods-available/linelog_nac_json"
linelog linelog_nac_json {
    filename = ${NAC_AUDIT_JSON_FILE}
    permissions = 0640
    group = freerad
    format = "%t"
    reference = "messages.%{%{reply:Packet-Type}:-unknown}"

    messages {
        Access-Accept = "{\"timestamp\":\"%t\",\"event\":\"8021x_auth\",\"status\":\"ACCEPT\",\"auth_method\":\"%{%{EAP-Type}:-MAB}\",\"user\":\"%{User-Name}\",\"mac\":\"%{%{Calling-Station-Id}:-%{User-Name}}\",\"switch_name\":\"%{client:shortname}\",\"switch_ip\":\"%{%{NAS-IP-Address}:-%{Packet-Src-IP-Address}}\",\"switch_port\":\"%{%{NAS-Port-Id}:-%{NAS-Port}}\",\"vlan\":\"%{%{reply:Tunnel-Private-Group-Id}:-default}\"}"

        Access-Reject = "{\"timestamp\":\"%t\",\"event\":\"8021x_auth\",\"status\":\"REJECT\",\"auth_method\":\"%{%{EAP-Type}:-MAB}\",\"user\":\"%{User-Name}\",\"mac\":\"%{%{Calling-Station-Id}:-%{User-Name}}\",\"switch_name\":\"%{client:shortname}\",\"switch_ip\":\"%{%{NAS-IP-Address}:-%{Packet-Src-IP-Address}}\",\"switch_port\":\"%{%{NAS-Port-Id}:-%{NAS-Port}}\",\"vlan\":\"98_FailSafe\"}"
    }
}
EOF

ln -sf "${FR_CONF_DIR}/mods-available/linelog_nac_json" "${FR_CONF_DIR}/mods-enabled/linelog_nac_json"
chown -h root:freerad "${FR_CONF_DIR}/mods-available/linelog_nac_json" "${FR_CONF_DIR}/mods-enabled/linelog_nac_json"
chmod 640 "${FR_CONF_DIR}/mods-available/linelog_nac_json"

# 預先建立空白日誌檔並賦予正確權限，確保 Wazuh Agent 可立即掛載監控
install -d -m 0750 -o freerad -g freerad "${NAC_AUDIT_LOG_DIR}"
touch "${NAC_AUDIT_JSON_FILE}"
chown freerad:freerad "${NAC_AUDIT_JSON_FILE}"
chmod 0640 "${NAC_AUDIT_JSON_FILE}"
echo "    [OK] linelog_nac_json 模組與日誌檔初始化完成。"

# ── [步驟 3/4] 將 linelog_nac_json 掛載至 default 虛擬伺服器 ──────────────────
echo ""
echo "==> [2/4] 將 linelog_nac_json 掛載至 ${FR_CONF_DIR}/sites-available/default..."

DEFAULT_SITE="${FR_CONF_DIR}/sites-available/default"
if ! grep -q "linelog_nac_json" "${DEFAULT_SITE}"; then
    # 1. 掛載於 post-auth 主區塊 (記錄 Access-Accept)
    sed -i '/apply_vlan_reply/a \        linelog_nac_json' "${DEFAULT_SITE}"
    # 2. 掛載於 Post-Auth-Type REJECT 區塊 (記錄 Access-Reject)
    sed -i '/attr_filter.access_reject/a \            linelog_nac_json' "${DEFAULT_SITE}"
    echo "    [OK] 已成功於 post-auth (Accept 與 REJECT) 掛載 linelog_nac_json。"
else
    echo "    [INFO] default 虛擬伺服器已包含 linelog_nac_json，跳過重複掛載。"
fi

# ── [步驟 4/4] 設定 Logrotate 自動輪替與壓縮規則 ─────────────────────────────
echo ""
echo "==> [3/4] 設定 Logrotate 規則 (/etc/logrotate.d/freeradius-nac-json)..."

cat << EOF > /etc/logrotate.d/freeradius-nac-json
${NAC_AUDIT_JSON_FILE} {
    daily
    rotate ${LOGROTATE_RETENTION_DAYS}
    missingok
    notifempty
    compress
    delaycompress
    create 0640 freerad freerad
    sharedscripts
    postrotate
        if systemctl is-active --quiet freeradius; then
            systemctl reload freeradius >/dev/null 2>&1 || true
        fi
    endscript
}
EOF
chmod 644 /etc/logrotate.d/freeradius-nac-json
echo "    [OK] Logrotate 規則已寫入。"

# ── [語法檢查、重啟服務與驗證] ───────────────────────────────────────────────
echo ""
echo "==> [4/4] 執行 FreeRADIUS 語法檢查與重啟服務..."
freeradius -Cx -l stdout | tail -n 5
systemctl restart freeradius
systemctl status freeradius --no-pager

echo "=============================================================================="
echo " [SUCCESS] NAC JSON 結構化稽核日誌與自動輪替機制已全面啟用！"
echo "   - JSON 日誌路徑  : ${NAC_AUDIT_JSON_FILE}"
echo "   - Logrotate 設定 : /etc/logrotate.d/freeradius-nac-json (保留 ${LOGROTATE_RETENTION_DAYS} 天)"
echo "   - 即時監看日誌   : tail -f ${NAC_AUDIT_JSON_FILE}"
echo "=============================================================================="
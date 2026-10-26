#!/usr/bin/env bash
# ==============================================================================
#  03_setup-crl-sync.sh (v2 集中化設定檔版)
#  自動設定 FreeRADIUS CRL 檢查與每 4 小時自動同步更新機制
#  適用系統：Debian 13 (Trixie) / FreeRADIUS 3.2.7
#  前置條件：同目錄下需存在 config.env，且已完成 01 與 02 腳本部署
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
# ──────────────────────────────────────────────────────────────────────────────

echo "=============================================================================="
echo " 開始設定 FreeRADIUS CRL 自動同步與檢查機制 (v2)"
echo "   - Root CA CRL URL : ${ROOT_CRL_URL}"
echo "   - Sub  CA CRL URL : ${SUB_CRL_URL}"
echo "   - 自動同步頻率    : 每 ${CRL_SYNC_INTERVAL}"
echo "=============================================================================="

# ── [步驟 1/4] 安裝共用設定檔至 /etc/freeradius/3.0 供背景任務讀取 ─────────────
echo ""
echo "==> [1/4] 同步環境設定檔至 ${INSTALLED_ENV_FILE}..."
cp -f "${CONFIG_FILE}" "${INSTALLED_ENV_FILE}"
chown root:freerad "${INSTALLED_ENV_FILE}"
chmod 640 "${INSTALLED_ENV_FILE}"
echo "    [OK] 設定檔已安裝至 ${INSTALLED_ENV_FILE}。"

# ── [步驟 2/4] 建立 CRL 自動更新執行腳本 ───────────────────────────────────────
echo ""
echo "==> [2/4] 建立自動更新腳本 (${SYNC_SCRIPT_PATH})..."

cat << EOF > "${SYNC_SCRIPT_PATH}"
#!/usr/bin/env bash
# 由 03_setup-crl-sync.sh 自動產生，讀取 ${INSTALLED_ENV_FILE} 參數
set -euo pipefail

if [ ! -f "${INSTALLED_ENV_FILE}" ]; then
    echo "[ERROR] 找不到環境設定檔 ${INSTALLED_ENV_FILE}" >&2
    exit 1
fi
source "${INSTALLED_ENV_FILE}"

TEMP_DIR=\$(mktemp -d)
trap 'rm -rf "\${TEMP_DIR}"' EXIT

# 1. 下載最新 CRL 檔案
if ! wget -q "\${ROOT_CRL_URL}" -O "\${TEMP_DIR}/RootCA.crl"; then
    echo "[ERROR] 無法從 \${ROOT_CRL_URL} 下載 RootCA CRL，略過本次更新。" >&2
    exit 1
fi

if ! wget -q "\${SUB_CRL_URL}" -O "\${TEMP_DIR}/SubCA.crl"; then
    echo "[ERROR] 無法從 \${SUB_CRL_URL} 下載 SubCA CRL，略過本次更新。" >&2
    exit 1
fi

if [ ! -s "\${TEMP_DIR}/RootCA.crl" ] || [ ! -s "\${TEMP_DIR}/SubCA.crl" ]; then
    echo "[ERROR] 下載的 CRL 檔案為空，略過本次更新。" >&2
    exit 1
fi

# 2. 將 AD CS 預設的 DER 格式轉為 OpenSSL PEM 格式
for crl in "\${TEMP_DIR}/RootCA.crl" "\${TEMP_DIR}/SubCA.crl"; do
    if ! grep -q "BEGIN X509 CRL" "\${crl}"; then
        openssl crl -inform DER -in "\${crl}" -out "\${crl}.pem"
        mv "\${crl}.pem" "\${crl}"
    fi
done

# 3. 重新合成包含憑證與最新 CRL 的信任鏈
cat "\${LOCAL_SUB_CA_CRT}" \\
    "\${LOCAL_ROOT_CA_CRT}" \\
    "\${TEMP_DIR}/SubCA.crl" \\
    "\${TEMP_DIR}/RootCA.crl" > "\${CORP_CA_CHAIN}"

chown root:freerad "\${CORP_CA_CHAIN}"
chmod 640 "\${CORP_CA_CHAIN}"

# 4. 平滑重載 FreeRADIUS 服務 (若服務正在運行中則 reload)
if systemctl is-active --quiet freeradius; then
    systemctl reload freeradius
fi
echo "[SUCCESS] FreeRADIUS CRL 憑證鏈已成功更新 (\$(date '+%Y-%m-%d %H:%M:%S'))。"
EOF

chmod +x "${SYNC_SCRIPT_PATH}"
echo "    [OK] 自動更新執行腳本已就緒，立即執行首次 CRL 下載與合成..."
"${SYNC_SCRIPT_PATH}"

# ── [步驟 3/4] 建立 systemd service 與 timer (每 4 小時執行一次) ───────────────
echo ""
echo "==> [3/4] 建立 systemd 自動同步定時器 (每 ${CRL_SYNC_INTERVAL})..."

cat << EOF > /etc/systemd/system/freerad-crl.service
[Unit]
Description=Download latest CRL and update FreeRADIUS ca_chain
After=network-online.target

[Service]
Type=oneshot
ExecStart=${SYNC_SCRIPT_PATH}
EOF

cat << EOF > /etc/systemd/system/freerad-crl.timer
[Unit]
Description=Timer to update FreeRADIUS CRL every ${CRL_SYNC_INTERVAL}

[Timer]
OnBootSec=5min
OnUnitActiveSec=${CRL_SYNC_INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now freerad-crl.timer
echo "    [OK] freerad-crl.timer 已啟動並設定每 ${CRL_SYNC_INTERVAL} 執行一次。"

# ── [步驟 4/4] 在 FreeRADIUS EAP 模組中啟用 check_crl = yes ──────────────────
echo ""
echo "==> [4/4] 在 EAP 模組設定檔中啟用 check_crl = yes..."

EAP_MOD_FILE="${FR_CONF_DIR}/mods-available/eap"
if ! grep -q "check_crl = yes" "${EAP_MOD_FILE}"; then
    sed -i '/ca_path =/a \        check_crl = yes' "${EAP_MOD_FILE}"
    echo "    [OK] 已成功在 tls-common 區塊加入 check_crl = yes。"
else
    echo "    [INFO] 該設定已存在，跳過重複加入。"
fi

echo ""
echo "==> 執行 FreeRADIUS 組態語法檢查與重啟服務..."
freeradius -Cx -l stdout | tail -n 5
systemctl restart freeradius
systemctl status freeradius --no-pager

echo "=============================================================================="
echo " [SUCCESS] CRL 自動同步與檢查機制已全面啟用！"
echo "   - 共用設定檔 : ${INSTALLED_ENV_FILE}"
echo "   - 同步頻率   : 每 ${CRL_SYNC_INTERVAL} 自動執行一次"
echo "   - 同步腳本   : ${SYNC_SCRIPT_PATH}"
echo "   - 信任鏈檔   : ${CORP_CA_CHAIN}"
echo "   - 手動更新   : ${SYNC_SCRIPT_PATH}"
echo "   - 定時器狀態 : systemctl list-timers freerad-crl.timer"
echo "=============================================================================="
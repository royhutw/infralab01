#!/usr/bin/env bash
# ==============================================================================
#  03_setup-crl-sync.sh
#  自動設定 FreeRADIUS CRL 檢查與每 4 小時自動同步更新機制
#  適用系統：Debian 13 (Trixie) / FreeRADIUS 3.2.7
# ==============================================================================
set -euo pipefail

DOMAIN="corp.foo.bar.tw"
CRL_BASE_URL="http://crl.${DOMAIN}"
FR_CONF_DIR="/etc/freeradius/3.0"
CORP_CA_CHAIN="${FR_CONF_DIR}/certs/corp_ca_chain.pem"

LOCAL_ROOT_CA_CRT="/usr/local/share/ca-certificates/RootCA.crt"
LOCAL_SUB_CA_CRT="/usr/local/share/ca-certificates/SubCA.crt"

SYNC_SCRIPT_PATH="/usr/local/bin/update-freeradius-crl.sh"

echo "=============================================================================="
echo " 開始設定 FreeRADIUS CRL 自動同步與檢查機制..."
echo "=============================================================================="

# ── [步驟 1/3] 建立 CRL 自動更新執行腳本 ───────────────────────────────────────
echo ""
echo "==> [1/3] 建立自動更新腳本 (${SYNC_SCRIPT_PATH})..."

cat << 'EOF' > "${SYNC_SCRIPT_PATH}"
#!/usr/bin/env bash
set -euo pipefail

DOMAIN="corp.foo.bar.tw"
ROOT_CRL_URL="http://crl.${DOMAIN}/RootCA.crl"
SUB_CRL_URL="http://crl.${DOMAIN}/AIA/corp-foo-bar-tw-SubCA.crl"

FR_CONF_DIR="/etc/freeradius/3.0"
CORP_CA_CHAIN="${FR_CONF_DIR}/certs/corp_ca_chain.pem"
LOCAL_ROOT_CA_CRT="/usr/local/share/ca-certificates/RootCA.crt"
LOCAL_SUB_CA_CRT="/usr/local/share/ca-certificates/SubCA.crt"

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT

# 1. 下載最新 CRL 檔案
wget -q "${ROOT_CRL_URL}" -O "${TEMP_DIR}/RootCA.crl" || true
wget -q "${SUB_CRL_URL}" -O "${TEMP_DIR}/SubCA.crl" || true

if [ ! -f "${TEMP_DIR}/RootCA.crl" ] || [ ! -f "${TEMP_DIR}/SubCA.crl" ]; then
    echo "[ERROR] 無法從 ${DOMAIN} 下載 CRL 檔案，略過本次更新。" >&2
    exit 1
fi

# 2. 將 AD CS 預設的 DER 格式轉為 OpenSSL PEM 格式
for crl in "${TEMP_DIR}/RootCA.crl" "${TEMP_DIR}/SubCA.crl"; do
    if ! grep -q "BEGIN X509 CRL" "${crl}"; then
        openssl crl -inform DER -in "${crl}" -out "${crl}.pem"
        mv "${crl}.pem" "${crl}"
    fi
done

# 3. 重新合成包含憑證與最新 CRL 的信任鏈
cat "${LOCAL_SUB_CA_CRT}" \
    "${LOCAL_ROOT_CA_CRT}" \
    "${TEMP_DIR}/SubCA.crl" \
    "${TEMP_DIR}/RootCA.crl" > "${CORP_CA_CHAIN}"

chown root:freerad "${CORP_CA_CHAIN}"
chmod 640 "${CORP_CA_CHAIN}"

# 4. 平滑重載 FreeRADIUS 服務 (不中斷現有連線)
systemctl reload freeradius
echo "[SUCCESS] FreeRADIUS CRL 憑證鏈已成功更新並重載服務。"
EOF

chmod +x "${SYNC_SCRIPT_PATH}"
echo "    [OK] 自動更新執行腳本已就緒。"

# ── [步驟 2/3] 建立 systemd service 與 timer (每 4 小時執行一次) ───────────────
echo ""
echo "==> [2/3] 建立 systemd 自動同步定時器 (每 4 小時)..."

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
Description=Timer to update FreeRADIUS CRL every 4 hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now freerad-crl.timer
echo "    [OK] freerad-crl.timer 已啟動並設定每 4 小時執行一次。"

# ── [步驟 3/3] 在 FreeRADIUS EAP 模組中啟用 check_crl = yes ──────────────────
echo ""
echo "==> [3/3] 在 EAP 模組設定檔中啟用 check_crl = yes..."

EAP_MOD_FILE="${FR_CONF_DIR}/mods-available/eap"
if ! grep -q "check_crl = yes" "${EAP_MOD_FILE}"; then
    # 在 ca_path = ... 的下一行自動插入 check_crl = yes
    sed -i '/ca_path =/a \        check_crl = yes' "${EAP_MOD_FILE}"
    echo "    [OK] 已成功在 tls-common 區塊加入 check_crl = yes。"
else
    echo "    [INFO] 該設定已存在，跳過重複加入。"
fi

# 執行語法檢查並重啟 FreeRADIUS 驗證
echo ""
echo "==> 執行 FreeRADIUS 組態語法檢查與重啟服務..."
freeradius -Cx -l stdout | tail -n 5
systemctl restart freeradius
systemctl status freeradius --no-pager

echo "=============================================================================="
echo " [SUCCESS] CRL 自動同步與檢查機制已全面啟用！"
echo "   - 同步頻率 : 每 4 小時自動執行一次"
echo "   - 同步腳本 : ${SYNC_SCRIPT_PATH}"
echo "   - 信任鏈檔 : ${CORP_CA_CHAIN}"
echo "   - FreeRADIUS 服務已重載，並啟用 check_crl = yes"
echo "   - 若要立即手動更新 CRL，可執行：sudo ${SYNC_SCRIPT_PATH}"
echo "   - 若要查看定時器狀態，可執行：systemctl list-timers freerad-crl.timer"
echo "=============================================================================="
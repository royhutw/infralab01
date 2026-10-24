#!/usr/bin/env bash
# ==============================================================================
#  01_setup-certmonger-cepces.sh (v2 完整整合版)
#  自動化部署 AD 網域加入 (Samba/Winbind)、CA 憑證鏈信任、
#  以及 certmonger + cepces (v0.5.0) 自動申請與續約 AD CS EAP-TLS 憑證腳本
#
#  適用系統：Debian 13 (Python 3.13)
#  使用方式：
#    chmod +x 01_setup-certmonger-cepces-v2.sh
#    ./01_setup-certmonger-cepces-v2.sh
# ==============================================================================
set -euo pipefail

# ── [1. 網域與主機基本參數設定區] ─────────────────────────────────────────────
DOMAIN="corp.foo.bar.tw"
REALM="CORP.FOO.BAR.TW"
NETBIOS="CORP"

SHORT_HOSTNAME="radius3"
HOSTNAME_FQDN="${SHORT_HOSTNAME}.${DOMAIN}"
# 自動轉大寫並加上 $ 號 (例如 RADIUS3$)
MACHINE_ACCOUNT="${SHORT_HOSTNAME^^}$"

# 本機 IP 位址 (若留空，腳本會自動偵測預設網卡 IPv4 位址以寫入 /etc/hosts)
HOST_IP=""

# 加入 AD 網域使用的管理員帳號 (執行至 net ads join 時將提示輸入密碼)
AD_ADMIN_USER="Administrator"
KEYTAB_PATH="/etc/krb5.keytab"

# ── [2. PKI 憑證信任鏈 (Root CA / Sub CA) 下載 URL 參數區] ────────────────────
CRL_BASE_URL="http://crl.${DOMAIN}"
SUBCA_HOSTNAME="adcs.${DOMAIN}"
SUBCA_COMMON_NAME="corp-foo-bar-tw-SubCA"

ROOT_CA_CRT_URL="${CRL_BASE_URL}/RootCA.crt"
SUB_CA_CRT_URL="${CRL_BASE_URL}/AIA/${SUBCA_HOSTNAME}_${SUBCA_COMMON_NAME}.crt"

LOCAL_ROOT_CA_CRT="/usr/local/share/ca-certificates/RootCA.crt"
LOCAL_SUB_CA_CRT="/usr/local/share/ca-certificates/SubCA.crt"

# ── [3. CEP/CES 與 Certmonger 憑證申請參數區] ────────────────────────────────
CEPCES_SERVER="cepces1.${DOMAIN}"
CEP_ENDPOINT="https://${CEPCES_SERVER}/ADPolicyProvider_CEP_Kerberos/service.svc/CEP"

CEPCES_GIT_URL="https://github.com/openSUSE/cepces.git"
CEPCES_VENV_DIR="/opt/cepces"
CEPCES_SRC_DIR="/opt/cepces-src"
CEPCES_SUBMIT_BIN="/usr/local/bin/cepces-submit"

CA_NAME="CEP-CES"
REQUEST_ID="RADIUS-EAP-TLS"
PROFILE_NAME="EAP-TLS-NPS-Server"
KEY_SIZE="4096"

CERT_PATH="/etc/ssl/certs/${SHORT_HOSTNAME}.crt"
KEY_PATH="/etc/ssl/private/${SHORT_HOSTNAME}.key"

# 憑證核發或自動續約後的自動化處理腳本 (修正私鑰權限並重載 FreeRADIUS)
POST_SAVE_CMD="/bin/chown root:freerad ${KEY_PATH} ${CERT_PATH} 2>/dev/null || true; /bin/chmod 640 ${KEY_PATH}; /bin/systemctl reload freeradius 2>/dev/null || true"
# ──────────────────────────────────────────────────────────────────────────────

echo "=============================================================================="
echo " 開始執行 RADIUS 伺服器 AD 整合與 CEP/CES 憑證自動化部署"
echo " 主機 FQDN : ${HOSTNAME_FQDN}"
echo " 機器帳號  : ${MACHINE_ACCOUNT}@${REALM}"
echo "=============================================================================="

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 1/8] 設定主機名稱 (Hostname) 與 /etc/hosts
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [1/8] 設定 Hostname 與 /etc/hosts..."
hostnamectl set-hostname "${HOSTNAME_FQDN}"

if [ -z "${HOST_IP}" ]; then
    HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n 1)
fi

if [ -n "${HOST_IP}" ]; then
    # 移除舊的同名紀錄並寫入最新設定
    sed -i "/[[:space:]]${HOSTNAME_FQDN}/d" /etc/hosts
    echo "${HOST_IP}     ${HOSTNAME_FQDN} ${SHORT_HOSTNAME}" >> /etc/hosts
    echo "    [OK] 已寫入 /etc/hosts: ${HOST_IP} -> ${HOSTNAME_FQDN} ${SHORT_HOSTNAME}"
else
    echo "    [WARNING] 無法自動偵測本機 IP，請手動確認 /etc/hosts 是否包含 ${HOSTNAME_FQDN}"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 2/8] 嚴格的時間同步 (Chrony NTP)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [2/8] 安裝並設定 Chrony 時間同步 (確保 Kerberos 時間誤差小於 5 分鐘)..."
apt-get update
apt-get install -y chrony wget ca-certificates
systemctl enable --now chrony
systemctl restart chrony
sleep 2
chronyc tracking || true

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 3/8] 下載 Root CA 與 Sub CA 憑證並更新系統信任庫
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [3/8] 下載 Root CA 與 Sub CA 憑證並更新系統信任庫..."
wget -q "${ROOT_CA_CRT_URL}" -O "${LOCAL_ROOT_CA_CRT}"
wget -q "${SUB_CA_CRT_URL}" -O "${LOCAL_SUB_CA_CRT}"

# 若下載下來的憑證為 DER (二進位) 格式，自動轉換為 PEM 格式以確保 update-ca-certificates 正確識別
for crt_file in "${LOCAL_ROOT_CA_CRT}" "${LOCAL_SUB_CA_CRT}"; do
    if ! grep -q "BEGIN CERTIFICATE" "${crt_file}"; then
        echo "    [INFO] 偵測到 ${crt_file} 為 DER 格式，自動轉換為 PEM 格式..."
        openssl x509 -inform DER -in "${crt_file}" -out "${crt_file}.pem"
        mv "${crt_file}.pem" "${crt_file}"
    fi
done

update-ca-certificates
echo "    [OK] Root CA 與 Sub CA 憑證已成功匯入系統信任存放區。"

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 4/8] 安裝與設定 Samba / Winbind / Kerberos 並加入 AD 網域
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [4/8] 安裝 Samba / Winbind 與 Kerberos 套件並設定組態..."
DEBIAN_FRONTEND=noninteractive apt-get install -y samba winbind libpam-winbind libnss-winbind krb5-user smbclient

# 備份原始設定檔
[ -f /etc/samba/smb.conf ] && [ ! -f /etc/samba/smb.conf.bak ] && cp -a /etc/samba/smb.conf /etc/samba/smb.conf.bak
[ -f /etc/krb5.conf ] && [ ! -f /etc/krb5.conf.bak ] && cp -a /etc/krb5.conf /etc/krb5.conf.bak

# 建立精簡且專為 RADIUS 驗證與自動 Keytab 維護最佳化的 Samba 設定
cat << EOF > /etc/samba/smb.conf
[global]
    workgroup = ${NETBIOS}
    realm = ${REALM}
    security = ads
    dns proxy = no

    # 強制 Samba 使用並同步更新外部的 /etc/krb5.keytab (避免 30 天機器密碼換新後 CEP/CES 續約失敗)
    kerberos method = secrets and keytab
    sync machine password to keytab = ${KEYTAB_PATH}:sync_spns:sync_kvno:machine_password

    # 停用印表機分享 (RADIUS 伺服器不需要)
    load printers = no
    printing = bsd
    printcap name = /dev/null
    disable spoolss = yes

    # Winbind 核心設定 (供 RADIUS mschap 模組呼叫)
    winbind use default domain = yes
    winbind enum users = yes
    winbind enum groups = yes
    winbind refresh tickets = yes

    # ID 對應設定 (將 AD SID 映射為 Linux 本機 UID/GID)
    idmap config * : backend = tdb
    idmap config * : range = 3000-7999
    idmap config ${NETBIOS} : backend = rid
    idmap config ${NETBIOS} : range = 10000-999999

    # 允許使用離線登入快取
    winbind offline logon = yes
EOF

# 建立 Kerberos 設定檔
cat << EOF > /etc/krb5.conf
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true
EOF

systemctl stop smbd nmbd winbind || true

# 檢查是否已經加入網域，若未加入則執行互動式 net ads join
if ! net ads testjoin -P >/dev/null 2>&1; then
    echo "    [ACTION] 請輸入網域管理員 (${AD_ADMIN_USER}@${REALM}) 密碼以加入 AD 網域："
    net ads join -U "${AD_ADMIN_USER}"
else
    echo "    [SKIP] 主機已加入 ${REALM} 網域且信任關係正常。"
fi

systemctl enable smbd nmbd winbind
systemctl restart smbd nmbd winbind

echo "    [INFO] 產生並驗證 ${KEYTAB_PATH}..."
net ads keytab create -P
chmod 600 "${KEYTAB_PATH}"

wbinfo -t
echo "    [INFO] 測試讀取前 5 筆 AD 使用者與群組："
wbinfo -u | head -n 5 || true
wbinfo -g | head -n 5 || true
klist -k "${KEYTAB_PATH}"

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 5/8] 建立 Python 虛擬環境並從 GitHub 安裝 cepces 與包裝腳本
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [5/8] 安裝 certmonger、Python 編譯環境與 cepces (v0.5.0)..."
apt-get install -y certmonger python3-pip python3-venv build-essential libkrb5-dev git gss-ntlmssp

rm -rf "${CEPCES_VENV_DIR}" "${CEPCES_SRC_DIR}"
python3 -m venv "${CEPCES_VENV_DIR}"
"${CEPCES_VENV_DIR}/bin/pip" install --upgrade pip setuptools wheel

# 從官方 GitHub 安裝 cepces 與 requests-gssapi
"${CEPCES_VENV_DIR}/bin/pip" install "git+${CEPCES_GIT_URL}" requests-gssapi
git clone "${CEPCES_GIT_URL}" "${CEPCES_SRC_DIR}"

# 建立包裝腳本 (強制導入系統 CA 信任存放區並呼叫虛擬環境 Python)
cat << EOF > "${CEPCES_SUBMIT_BIN}"
#!/usr/bin/env bash
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
exec ${CEPCES_VENV_DIR}/bin/python3 ${CEPCES_SRC_DIR}/bin/cepces-submit "\$@"
EOF
chmod +x "${CEPCES_SUBMIT_BIN}"

echo -n "    [OK] cepces-submit 版本驗證："
CERTMONGER_OPERATION=IDENTIFY "${CEPCES_SUBMIT_BIN}"

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 6/8] 設定 /etc/cepces/cepces.conf (相容 v0.5.0 新版結構)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [6/8] 寫入 /etc/cepces/cepces.conf (避開 v0.5.0 解析 Bug)..."
mkdir -p /etc/cepces
cat << EOF > /etc/cepces/cepces.conf
[global]
endpoint = ${CEP_ENDPOINT}
auth = Kerberos
type = Policy
poll_interval = 60
openssl_ciphers = DEFAULT:@SECLEVEL=2

[kerberos]
keytab = ${KEYTAB_PATH}
principals = ${MACHINE_ACCOUNT}@${REALM}
enctypes = aes256-cts-hmac-sha1-96
delegate = True
EOF
chmod 600 /etc/cepces/cepces.conf

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 7/8] 註冊 Certmonger CA 並發起 4096-bit 憑證申請與自動續約追蹤
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [7/8] 註冊 Certmonger CA (${CA_NAME}) 並申請 ${KEY_SIZE}-bit 憑證..."
systemctl restart certmonger

# 清除舊請求與舊 CA 設定以確保冪等性
getcert stop-tracking -i "${REQUEST_ID}" 2>/dev/null || true
getcert remove-ca -c "${CA_NAME}" 2>/dev/null || true
rm -f "${KEY_PATH}" "${CERT_PATH}"

# 註冊自訂 CA，明確傳遞電腦帳號 Principal
getcert add-ca -c "${CA_NAME}" -e "${CEPCES_SUBMIT_BIN} --principals ${MACHINE_ACCOUNT}@${REALM}"

# 發起憑證申請 (含 -g 4096 最小金鑰長度要求與自動續約後置腳本 -C)
getcert request -c "${CA_NAME}" \
  -I "${REQUEST_ID}" \
  -T "${PROFILE_NAME}" \
  -g "${KEY_SIZE}" \
  -k "${KEY_PATH}" \
  -f "${CERT_PATH}" \
  -N "CN=${HOSTNAME_FQDN}" \
  -D "${HOSTNAME_FQDN}" \
  -K "host/${HOSTNAME_FQDN}@${REALM}" \
  -u digitalSignature -u keyEncipherment \
  -U 1.3.6.1.5.5.7.3.1 \
  -C "${POST_SAVE_CMD}"

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 8/8] 等待憑證核發並輸出驗證結果
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [8/8] 等待 5 秒讓 Certmonger 完成金鑰生成與憑證核發..."
sleep 5
getcert list -i "${REQUEST_ID}"

echo "=============================================================================="
echo " 部署腳本執行完畢！"
echo " 確認上方 status: MONITORING 且 stuck: no 即代表憑證已成功簽發並啟用自動續約。"
echo "=============================================================================="
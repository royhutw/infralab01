#!/usr/bin/env bash
# ==============================================================================
#  01_setup-certmonger-cepces.sh
#  自動化部署 certmonger + cepces (v0.5.0) 申請 AD CS 憑證腳本
#  適用系統：Debian 13 (Python 3.13)
#  使用方式：
#    chmod +x 01_setup-certmonger-cepces.sh
#    ./01_setup-certmonger-cepces.sh
# ==============================================================================
set -e

# ── [可調參數設定區] ────────────────────────────────────────────────────────
DOMAIN="corp.foo.bar.tw"
REALM="CORP.FOO.BAR.TW"
NETBIOS="CORP"
HOSTNAME_FQDN="radius3.${DOMAIN}"
SHORT_HOSTNAME="radius3"
MACHINE_ACCOUNT="RADIUS3$"                                    # 包含 $ 符號的電腦帳號
KEYTAB_PATH="/etc/krb5.keytab"
CEP_ENDPOINT="https://cepces1.${DOMAIN}/ADPolicyProvider_CEP_Kerberos/service.svc/CEP"

CERT_PATH="/etc/ssl/certs/${SHORT_HOSTNAME}.crt"
KEY_PATH="/etc/ssl/private/${SHORT_HOSTNAME}.key"
CA_NAME="CEP-CES"
PROFILE_NAME="EAP-TLS-NPS-Server"
# ──────────────────────────────────────────────────────────────────────────────

echo "==> [1/6] 安裝系統必要相依套件 (certmonger, python3-pip, python3-venv, gss-ntlmssp)..."
apt-get update
apt-get install -y certmonger python3-pip python3-venv krb5-user gss-ntlmssp

echo "==> [2/6] 建立 /opt/cepces Python 3.13 虛擬環境並安裝 cepces v0.5.0..."
rm -rf /opt/cepces /opt/cepces-src
python3 -m venv /opt/cepces
/opt/cepces/bin/pip install --upgrade pip setuptools wheel

# 複製或下載 cepces 原始碼並安裝
# 假設您已將源碼放於 /opt/cepces-src 或透過 pip 安裝線上版本
if [ -d "/opt/cepces-src" ]; then
    /opt/cepces/bin/pip install /opt/cepces-src
else
    /opt/cepces/bin/pip install git+https://pagure.io/cepces.git || /opt/cepces/bin/pip install cepces
fi

echo "==> [3/6] 建立符合 v0.5.0 規範的 /etc/cepces/cepces.conf 設定檔..."
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

echo "==> [4/6] 驗證 Kerberos 金鑰與 keytab 狀態..."
if ! klist -k ${KEYTAB_PATH} | grep -q "${MACHINE_ACCOUNT}"; then
    echo "[WARNING] 在 ${KEYTAB_PATH} 中未精準找到 ${MACHINE_ACCOUNT}，請確保已透過 adcli 或 net ads join 正常加入網域。"
fi

echo "==> [5/6] 註冊 Certmonger CA 並發起 4096-bit 憑證申請..."
# 若舊的 CA 存在先移除
getcert remove-ca -c ${CA_NAME} 2>/dev/null || true

# 新增 CA 並指定 wrapper 呼叫路徑與主機身分
getcert add-ca -c ${CA_NAME} -e "/usr/local/bin/cepces-submit --principals ${MACHINE_ACCOUNT}@${REALM}"

# 如果已有舊請求先停止追蹤
getcert stop-tracking -i RADIUS-EAP-TLS 2>/dev/null || true
rm -f ${KEY_PATH} ${CERT_PATH}

# 發起憑證要求 (-g 4096 符合 Active Directory EAP-TLS 範本最小金鑰長度要求)
getcert request -c ${CA_NAME} \
  -I RADIUS-EAP-TLS \
  -T ${PROFILE_NAME} \
  -g 4096 \
  -k ${KEY_PATH} \
  -f ${CERT_PATH} \
  -N "CN=${HOSTNAME_FQDN}" \
  -D ${HOSTNAME_FQDN} \
  -K host/${HOSTNAME_FQDN}@${REALM} \
  -u digitalSignature -u keyEncipherment \
  -U 1.3.6.1.5.5.7.3.1

echo "==> [6/6] 重啟 certmonger 服務並等待憑證狀態生效..."
systemctl restart certmonger

echo "=============================================================================="
echo " 部署腳本執行完成！請稍候 3~5 秒後執行以下指令檢查憑證狀態："
echo "   getcert list -i RADIUS-EAP-TLS"
echo " 當 status 轉為 MONITORING 即代表成功取得憑證！"
echo "=============================================================================="
#!/usr/bin/env bash
# ==============================================================================
#  02_setup-freeradius.sh (v4 實機驗證完畢・零修補終極正式版)
#  適用系統：Debian 13 (Trixie) / FreeRADIUS 3.2.7
#  前置條件：已執行 01_setup-certmonger-cepces.sh 完成 AD 加域與 CEP/CES 憑證簽發
#
#  功能摘要：
#    1. 安裝 FreeRADIUS、LDAP、Kerberos 與 SASL GSSAPI 模組
#    2. 合成內部專屬 PKI 信任鏈 (SubCA + RootCA)，防止公有 CA 塞爆 C2960X EAP 封包
#    3. 自動偵測 AD DC FQDN，設定 Kerberos rdns=false、SASL_NOCANON 與 TGT 自動續約
#    4. 配置 EAP-TEAP (Phase 2 雙階段 EAP-TLS 憑證驗證，fragment_size=1024)
#    5. 實作五段式 AD 群組動態 VLAN 派發與帳號啟用狀態 (`userAccountControl`) 檢查：
#       - MachineAuth : SG-HQ-8021X-VLAN([0-9]+)-[^,]+-Computers
#       - UserAuth    : SG-HQ-8021X-VLAN([0-9]+)-[^,]+-Users (優先權高於 MachineAuth)
#       - MAB (啟用)  : SG-HQ-8021X-VLAN([0-9]+)-[^,]+-MAB
#       - MAB (停用/移出群組) : Access-Reject (觸發交換器 event fail 進 VLAN 98)
#       - MAB (未知 MAC)      : AD 查無帳號時自動放行至 Guest VLAN 90
# ==============================================================================
set -euo pipefail

# ── [1. 網域與 AD LDAP 參數設定區] ───────────────────────────────────────────
DOMAIN="corp.foo.bar.tw"
REALM="CORP.FOO.BAR.TW"
SHORT_HOSTNAME="radius3"
HOSTNAME_FQDN="${SHORT_HOSTNAME}.${DOMAIN}"
MACHINE_PRINCIPAL="${SHORT_HOSTNAME^^}\$@${REALM}"

# AD 搜尋根目錄與 802.1X 群組專用 OU (對應 sg-hq-8021x-vlan.ps1)
BASE_DN="DC=corp,DC=foo,DC=bar,DC=tw"
HQ_GROUP_OU="OU=8021X-HQ,OU=HQ,${BASE_DN}"

# 自動透過 DNS SRV 紀錄偵測 AD Domain Controller FQDN (若偵測失敗則預設使用 dc01)
DETECTED_DC=$(host -t SRV "_ldap._tcp.dc._msdcs.${DOMAIN}" 2>/dev/null | awk '{print $NF}' | sed 's/\.$//' | head -n 1 || true)
DC_FQDN="${DETECTED_DC:-dc01.${DOMAIN}}"
LDAP_SERVER="ldap://${DC_FQDN}"

# ── [2. 交換器 (RADIUS Clients) 與 VLAN / 計時器參數區] ──────────────────────
SW_SUBNET="192.168.10.0/24"
SW_SECRET="P@ssw0rd"
SW_SHORTNAME="SW-HQ-Edge"

GUEST_VLAN="90"
REAUTH_TIMEOUT="86400"

# 針對 Cisco WS-C2960X-24TS-L 與 4096-bit 憑證最佳化的 EAP 分片大小
EAP_FRAGMENT_SIZE="1024"

# ── [3. 憑證與 Keytab 路徑參數區 (無縫銜接 01 腳本)] ─────────────────────────
LOCAL_ROOT_CA_CRT="/usr/local/share/ca-certificates/RootCA.crt"
LOCAL_SUB_CA_CRT="/usr/local/share/ca-certificates/SubCA.crt"

FR_CONF_DIR="/etc/freeradius/3.0"
CORP_CA_CHAIN="${FR_CONF_DIR}/certs/corp_ca_chain.pem"

CERT_PATH="/etc/ssl/certs/${SHORT_HOSTNAME}.crt"
KEY_PATH="/etc/ssl/private/${SHORT_HOSTNAME}.key"
KEYTAB_PATH="/etc/krb5.keytab"
KRB5_CCACHE_DIR="/var/lib/freeradius"
KRB5_CCACHE="${KRB5_CCACHE_DIR}/krb5cc_freerad"
# ──────────────────────────────────────────────────────────────────────────────

echo "=============================================================================="
echo " 開始執行 FreeRADIUS 802.1X (EAP-TEAP / MAB / Dynamic VLAN) 自動化部署 (v4)"
echo " 主機 FQDN  : ${HOSTNAME_FQDN}"
echo " 目標 AD DC : ${LDAP_SERVER}"
echo " 目標群組 OU: ${HQ_GROUP_OU}"
echo " 交換器網段 : ${SW_SUBNET}"
echo "=============================================================================="

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 1/7] 安裝 FreeRADIUS 與相關模組套件
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [1/7] 安裝 FreeRADIUS、LDAP、SASL GSSAPI 與 ACL 工具..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    freeradius \
    freeradius-ldap \
    freeradius-krb5 \
    freeradius-utils \
    libsasl2-modules-gssapi-mit \
    ldap-utils \
    acl

systemctl stop freeradius || true

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 2/7] 合成專屬內部 CA 憑證鏈並配置私鑰與 Keytab 權限
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [2/7] 合成專屬內部 CA 憑證鏈 (${CORP_CA_CHAIN}) 並修正權限..."
for f in "${LOCAL_ROOT_CA_CRT}" "${LOCAL_SUB_CA_CRT}" "${CERT_PATH}" "${KEY_PATH}" "${KEYTAB_PATH}"; do
    if [ ! -f "${f}" ]; then
        echo "    [ERROR] 找不到必要檔案: ${f}，請確認 01_setup-certmonger-cepces.sh 已執行成功！"
        exit 1
    fi
done

# 合成內部專屬 CA Chain (SubCA + RootCA)，避免公有 CA 塞爆 EAP-TEAP 握手封包
cat "${LOCAL_SUB_CA_CRT}" "${LOCAL_ROOT_CA_CRT}" > "${CORP_CA_CHAIN}"
chown root:freerad "${CORP_CA_CHAIN}"
chmod 640 "${CORP_CA_CHAIN}"

# 將 freerad 加入 ssl-cert 與 winbindd_priv 群組，並確保憑證私鑰可被 freerad 讀取
usermod -aG ssl-cert freerad || true
if getent group winbindd_priv >/dev/null; then
    usermod -aG winbindd_priv freerad || true
fi

chown root:freerad "${KEY_PATH}" "${CERT_PATH}"
chmod 640 "${KEY_PATH}"
chmod 644 "${CERT_PATH}"

# 透過 POSIX ACL 賦予 freerad 讀取 /etc/krb5.keytab 權限 (維持原本 0600 安全性)
setfacl -m u:freerad:r "${KEYTAB_PATH}"
echo "    [OK] 內部 CA 憑證鏈與私鑰/Keytab 權限配置完成。"

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 3/7] 配置 Kerberos Ticket 自動維護機制 (供 rlm_ldap GSSAPI 使用)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [3/7] 配置 Kerberos/SASL 參數與 TGT 自動續約服務 (freerad-kinit.timer)..."

# 關閉 Kerberos 與 OpenLDAP SASL 的反向 DNS 猜測，防止發生 Server not found in Kerberos database
if ! grep -q "rdns = false" /etc/krb5.conf; then
    sed -i '/\[libdefaults\]/a \    rdns = false' /etc/krb5.conf
fi
if ! grep -q "SASL_NOCANON" /etc/ldap/ldap.conf; then
    echo "SASL_NOCANON on" >> /etc/ldap/ldap.conf
fi

# 建立不受 systemd PrivateTmp 影響的專屬票證快取目錄
install -d -m 0750 -o freerad -g freerad "${KRB5_CCACHE_DIR}"

# 立即為 freerad 取得初始 Kerberos Ticket
runuser -u freerad -- kinit -k -t "${KEYTAB_PATH}" -c "${KRB5_CCACHE}" "${MACHINE_PRINCIPAL}"

cat << EOF > /etc/systemd/system/freerad-kinit.service
[Unit]
Description=Refresh Kerberos TGT for FreeRADIUS LDAP GSSAPI
After=network-online.target winbind.service

[Service]
Type=oneshot
User=freerad
Group=freerad
ExecStart=/usr/bin/kinit -k -t ${KEYTAB_PATH} -c ${KRB5_CCACHE} ${MACHINE_PRINCIPAL}
EOF

cat << EOF > /etc/systemd/system/freerad-kinit.timer
[Unit]
Description=Timer to refresh Kerberos TGT for FreeRADIUS every 4 hours

[Timer]
OnBootSec=1min
OnUnitActiveSec=4h
Persistent=true

[Install]
WantedBy=timers.target
EOF

mkdir -p /etc/systemd/system/freeradius.service.d
cat << EOF > /etc/systemd/system/freeradius.service.d/override.conf
[Unit]
After=network-online.target winbind.service freerad-kinit.service
Wants=freerad-kinit.service

[Service]
Environment="KRB5CCNAME=FILE:${KRB5_CCACHE}"
Environment="KRB5_CLIENT_KTNAME=${KEYTAB_PATH}"
EOF

systemctl daemon-reload
systemctl enable --now freerad-kinit.timer
echo "    [OK] Kerberos Ticket 自動維護服務已啟動。"

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 4/7] 設定 RADIUS Clients (Cisco C2960X 交換器網段)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [4/7] 設定交換器連線授權 (${FR_CONF_DIR}/clients.conf)..."
[ ! -f "${FR_CONF_DIR}/clients.conf.bak" ] && cp -a "${FR_CONF_DIR}/clients.conf" "${FR_CONF_DIR}/clients.conf.bak"

cat << EOF > "${FR_CONF_DIR}/clients.conf"
client localhost {
    ipaddr = 127.0.0.1
    secret = testing123
    require_message_authenticator = no
    nas_type = other
}

client ${SW_SHORTNAME} {
    ipaddr = ${SW_SUBNET}
    secret = "${SW_SECRET}"
    shortname = ${SW_SHORTNAME}
    nas_type = cisco
    require_message_authenticator = auto
}
EOF
chown root:freerad "${FR_CONF_DIR}/clients.conf"
chmod 640 "${FR_CONF_DIR}/clients.conf"

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 5/7] 設定 LDAP 模組 (讀取 memberOf 與 userAccountControl 帳號狀態)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [5/7] 設定 LDAP 模組 (${FR_CONF_DIR}/mods-available/ldap)..."
[ -f "${FR_CONF_DIR}/mods-available/ldap" ] && [ ! -f "${FR_CONF_DIR}/mods-available/ldap.bak" ] && \
    cp -a "${FR_CONF_DIR}/mods-available/ldap" "${FR_CONF_DIR}/mods-available/ldap.bak"

cat << 'EOF' > "${FR_CONF_DIR}/mods-available/ldap"
ldap {
    server = '__LDAP_SERVER__'
    base_dn = '__BASE_DN__'

    sasl {
        mech = 'GSSAPI'
        realm = '__REALM__'
    }

    # 將 AD 的 memberOf 映射到 control:LDAP-Group，並將 userAccountControl 抓回至 Tmp-Integer-0
    update {
        control:LDAP-Group += 'memberOf'
        control:Tmp-Integer-0 := 'userAccountControl'
    }

    user {
        base_dn = "${..base_dn}"
        scope = 'sub'
        filter = "(|(sAMAccountName=%{%{Stripped-User-Name}:-%{User-Name}})(userPrincipalName=%{User-Name}))"
        sasl {
            mech = 'GSSAPI'
            realm = '__REALM__'
        }
    }

    group {
        base_dn = '__HQ_GROUP_OU__'
        scope = 'sub'
        name_attribute = cn
        membership_filter = "(member:1.2.840.113556.1.4.1941:=%{control:Ldap-UserDn})"
        membership_attribute = 'memberOf'
    }

    options {
        # 關閉 AD 跨區 Referral 追蹤 (避免卡在 ForestDnsZones / DomainDnsZones)
        chase_referrals = no
        rebind = no
        res_timeout = 10
        srv_timelimit = 3
        net_timeout = 1
        idle = 60
        probes = 3
        interval = 3
        ldap_debug = 0x0000
    }

    pool {
        start = ${thread[pool].start_servers}
        min = ${thread[pool].min_spare_servers}
        max = ${thread[pool].max_servers}
        spare = ${thread[pool].max_spare_servers}
        uses = 0
        retry_delay = 30
        lifetime = 0
        idle_timeout = 60
    }
}
EOF

sed -i "s|__LDAP_SERVER__|${LDAP_SERVER}|g" "${FR_CONF_DIR}/mods-available/ldap"
sed -i "s|__BASE_DN__|${BASE_DN}|g" "${FR_CONF_DIR}/mods-available/ldap"
sed -i "s|__HQ_GROUP_OU__|${HQ_GROUP_OU}|g" "${FR_CONF_DIR}/mods-available/ldap"
sed -i "s|__REALM__|${REALM}|g" "${FR_CONF_DIR}/mods-available/ldap"

ln -sf "${FR_CONF_DIR}/mods-available/ldap" "${FR_CONF_DIR}/mods-enabled/ldap"
chown -h root:freerad "${FR_CONF_DIR}/mods-available/ldap" "${FR_CONF_DIR}/mods-enabled/ldap"
chmod 640 "${FR_CONF_DIR}/mods-available/ldap"

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 6/7] 設定 EAP 模組 (EAP-TEAP 內外層皆使用憑證驗證 + 分片最佳化)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [6/7] 設定 EAP 模組 (${FR_CONF_DIR}/mods-available/eap)..."
[ ! -f "${FR_CONF_DIR}/mods-available/eap.bak" ] && cp -a "${FR_CONF_DIR}/mods-available/eap" "${FR_CONF_DIR}/mods-available/eap.bak"

cat << EOF > "${FR_CONF_DIR}/mods-available/eap"
eap {
    default_eap_type = teap
    timer_expire = 60
    ignore_unknown_eap_types = no
    cisco_accounting_username_bug = no
    max_sessions = \${max_requests}

    tls-config tls-common {
        private_key_file = ${KEY_PATH}
        certificate_file = ${CERT_PATH}
        ca_file = ${CORP_CA_CHAIN}
        ca_path = ${FR_CONF_DIR}/certs

        # 針對 Cisco WS-C2960X-24TS-L 與 4096-bit 憑證鏈最佳化分片大小
        fragment_size = ${EAP_FRAGMENT_SIZE}
        include_length = yes

        cipher_list = "DEFAULT"
        cipher_server_preference = no
        tls_min_version = "1.2"
        tls_max_version = "1.2"

        ecdh_curve = "prime256v1"

        cache {
            enable = no
            lifetime = 24
        }

        verify {
        }

        ocsp {
            enable = no
        }
    }

    # 供 EAP-TEAP Phase 2 內層憑證驗證呼叫
    tls {
        tls = tls-common
        virtual_server = check-eap-tls
    }

    # EAP-TEAP (RFC 7170) 主設定
    teap {
        tls = tls-common
        authority_identity = "${HOSTNAME_FQDN}"
        default_method = tls
        virtual_server = "inner-tunnel"
        include_length = yes
        auto_chain = yes
    }
}
EOF
chown root:freerad "${FR_CONF_DIR}/mods-available/eap"
chmod 640 "${FR_CONF_DIR}/mods-available/eap"

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 7/7] 設定動態 VLAN 判斷策略與虛擬伺服器 (Policy + Sites)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [7/7] 寫入五段式群組動態 VLAN 策略與虛擬伺服器組態..."

cat << 'EOF' > "${FR_CONF_DIR}/policy.d/corp_8021x_vlan"
# ==============================================================================
#  CORP.FOO.BAR.TW 802.1X 動態 VLAN 指派核心邏輯 (對齊五段式群組命名)
#    - 電腦驗證群組: SG-HQ-8021X-VLAN<ID>-<Name>-Computers
#    - 人員驗證群組: SG-HQ-8021X-VLAN<ID>-<Name>-Users
#    - 設備驗證群組: SG-HQ-8021X-VLAN<ID>-<Name>-MAB
# ==============================================================================

# [A] 正規化 AD 查詢名稱 (支援從內層憑證 CN 或 User-Name 提取 sAMAccountName)
normalize_ad_identity {
    if (&TLS-Client-Cert-Common-Name && (&TLS-Client-Cert-Common-Name =~ /^([a-zA-Z0-9_-]+)\.__DOMAIN_REGEX__$/i)) {
        update request {
            &Stripped-User-Name := "%{1}$"
        }
    }
    elsif (&User-Name =~ /^host\/([a-zA-Z0-9_-]+)\.__DOMAIN_REGEX__$/i) {
        update request {
            &Stripped-User-Name := "%{1}$"
        }
    }
    elsif (&User-Name =~ /^([^@]+)@__DOMAIN_REGEX__$/i) {
        update request {
            &Stripped-User-Name := "%{1}"
        }
    }
}

# [B] EAP-TEAP 內層憑證授權與動態 VLAN 計算
evaluate_eap_vlan {
    normalize_ad_identity

    ldap
    if (notfound) {
        reject
    }

    # 檢查 AD 帳號是否被停用 (userAccountControl Bit 2: ACCOUNTDISABLE = 2)
    if (&control:Tmp-Integer-0 && ("%{expr:%{control:Tmp-Integer-0} & 2}" == "2")) {
        reject
    }

    # 1. 判斷是否為電腦驗證 (MachineAuth: host/... 或以 $ 結尾)
    if ((&User-Name =~ /^host\//i) || (&Stripped-User-Name && (&Stripped-User-Name =~ /\$$/))) {
        foreach &control:LDAP-Group {
            if ("%{Foreach-Variable-0}" =~ /^CN=SG-HQ-8021X-VLAN([0-9]+)-[^,]+-Computers,/i) {
                if (!&session-state:Tmp-String-1 || (&session-state:Tmp-String-1 != "USER_AUTH_DONE")) {
                    update session-state {
                        &Tmp-String-0 := "%{1}"
                        &Tmp-String-1 := "MACHINE_AUTH_DONE"
                    }
                }
                break
            }
        }
        if (!&session-state:Tmp-String-1) {
            reject
        }
    }
    # 2. 否則為使用者驗證 (UserAuth)
    else {
        foreach &control:LDAP-Group {
            if ("%{Foreach-Variable-0}" =~ /^CN=SG-HQ-8021X-VLAN([0-9]+)-[^,]+-Users,/i) {
                update session-state {
                    &Tmp-String-0 := "%{1}"
                    &Tmp-String-1 := "USER_AUTH_DONE"
                }
                break
            }
        }
        if (!&session-state:Tmp-String-1 || (&session-state:Tmp-String-1 != "USER_AUTH_DONE")) {
            reject
        }
    }
}

# [C] MAB 驗證與設備/訪客動態 VLAN 計算
evaluate_mab_vlan {
    update request {
        &Stripped-User-Name := "%{tolower:%{User-Name}}"
    }

    ldap
    # 情況 1：AD 中存在此 MAC 帳號
    if (ok || updated) {
        # 若該 MAC 帳號在 AD 被停用 (例如 514, 66050 -> Bit 2 = 2) -> 直接拒絕 (交換器導向 VLAN 98)
        if (&control:Tmp-Integer-0 && ("%{expr:%{control:Tmp-Integer-0} & 2}" == "2")) {
            reject
        }

        # 尋找所屬的 SG-HQ-8021X-VLAN<ID>-<Name>-MAB 群組
        foreach &control:LDAP-Group {
            if ("%{Foreach-Variable-0}" =~ /^CN=SG-HQ-8021X-VLAN([0-9]+)-[^,]+-MAB,/i) {
                update session-state {
                    &Tmp-String-0 := "%{1}"
                }
                break
            }
        }

        # 若未加入任何 -MAB 群組 -> 直接拒絕 (交換器導向 VLAN 98)
        if (!&session-state:Tmp-String-0) {
            reject
        }
    }
    # 情況 2：AD 中查無此 MAC 帳號 -> 視為未知訪客設備，放行至 Guest VLAN 90
    elsif (notfound) {
        update session-state {
            &Tmp-String-0 := "__GUEST_VLAN__"
        }
    }
    else {
        reject
    }
}

# [D] 掛載最終 VLAN 與重新驗證計時器屬性回傳給 Cisco C2960X
apply_vlan_reply {
    if (&session-state:Tmp-String-0) {
        update reply {
            &Tunnel-Type := VLAN
            &Tunnel-Medium-Type := IEEE-802
            &Tunnel-Private-Group-Id := &session-state:Tmp-String-0
            &Session-Timeout := __REAUTH_TIMEOUT__
            &Termination-Action := RADIUS-Request
        }
    }
}
EOF

DOMAIN_REGEX=$(echo "${DOMAIN}" | sed 's/\./\\./g')
sed -i "s|__DOMAIN_REGEX__|${DOMAIN_REGEX}|g" "${FR_CONF_DIR}/policy.d/corp_8021x_vlan"
sed -i "s|__GUEST_VLAN__|${GUEST_VLAN}|g" "${FR_CONF_DIR}/policy.d/corp_8021x_vlan"
sed -i "s|__REAUTH_TIMEOUT__|${REAUTH_TIMEOUT}|g" "${FR_CONF_DIR}/policy.d/corp_8021x_vlan"

# 7.2 設定 check-eap-tls 虛擬伺服器
cat << 'EOF' > "${FR_CONF_DIR}/sites-available/check-eap-tls"
server check-eap-tls {
    authorize {
        evaluate_eap_vlan
        update config {
            &Auth-Type := Accept
        }
    }
}
EOF
ln -sf "${FR_CONF_DIR}/sites-available/check-eap-tls" "${FR_CONF_DIR}/sites-enabled/check-eap-tls"

# 7.3 設定 inner-tunnel 虛擬伺服器
[ ! -f "${FR_CONF_DIR}/sites-available/inner-tunnel.bak" ] && \
    cp -a "${FR_CONF_DIR}/sites-available/inner-tunnel" "${FR_CONF_DIR}/sites-available/inner-tunnel.bak"

cat << 'EOF' > "${FR_CONF_DIR}/sites-available/inner-tunnel"
server inner-tunnel {
    listen {
        ipaddr = 127.0.0.1
        port = 18120
        type = auth
    }

    authorize {
        filter_username
        eap {
            ok = return
        }
    }

    authenticate {
        eap
    }

    post-auth {
        if (&session-state:Tmp-String-0) {
            update outer.session-state {
                &Tmp-String-0 := &session-state:Tmp-String-0
                &Tmp-String-1 := &session-state:Tmp-String-1
            }
        }
        Post-Auth-Type REJECT {
            attr_filter.access_reject
        }
    }
}
EOF

# 7.4 設定 default 主虛擬伺服器
[ ! -f "${FR_CONF_DIR}/sites-available/default.bak" ] && \
    cp -a "${FR_CONF_DIR}/sites-available/default" "${FR_CONF_DIR}/sites-available/default.bak"

cat << 'EOF' > "${FR_CONF_DIR}/sites-available/default"
server default {
    listen {
        type = auth
        ipaddr = *
        port = 0
        limit {
            max_connections = 16
            lifetime = 0
            idle_timeout = 30
        }
    }

    listen {
        ipaddr = *
        port = 0
        type = acct
    }

    authorize {
        filter_username
        preprocess

        # 1. 帶有 EAP-Message -> 進入 EAP-TEAP 驗證流程
        if (&EAP-Message) {
            eap {
                ok = return
                updated = return
            }
        }
        # 2. 無 EAP-Message 且 User-Name 為 12 碼 Hex -> 進入 Cisco C2960X MAB 驗證流程
        elsif (&User-Name =~ /^[0-9a-fA-F]{12}$/) {
            evaluate_mab_vlan
            update control {
                &Auth-Type := Accept
            }
        }
        else {
            reject
        }
    }

    authenticate {
        Auth-Type Accept {
            ok
        }
        eap
    }

    preacct {
        preprocess
        acct_unique
    }

    accounting {
        detail
        exec
        attr_filter.accounting_response
    }

    post-auth {
        apply_vlan_reply
        exec
        remove_reply_message_if_eap

        Post-Auth-Type REJECT {
            attr_filter.access_reject
            eap
            remove_reply_message_if_eap
        }
    }
}
EOF

chown -R root:freerad "${FR_CONF_DIR}/policy.d" "${FR_CONF_DIR}/sites-available" "${FR_CONF_DIR}/sites-enabled"

# ══════════════════════════════════════════════════════════════════════════════
#  [語法檢查與服務啟動]
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> 執行 FreeRADIUS 組態語法檢查 (freeradius -Cx)..."
freeradius -Cx -l stdout | tail -n 10

echo ""
echo "==> 啟動並啟用 FreeRADIUS 服務..."
systemctl enable freeradius
systemctl restart freeradius
systemctl status freeradius --no-pager

echo "=============================================================================="
echo " [SUCCESS] FreeRADIUS 802.1X 動態 VLAN 伺服器部署完成 (v4)！"
echo "   - 專屬內部 CA 鏈 : ${CORP_CA_CHAIN}"
echo "   - 交換器允許網段 : ${SW_SUBNET}"
echo "   - MachineAuth    : SG-HQ-8021X-VLAN<ID>-*-Computers"
echo "   - UserAuth       : SG-HQ-8021X-VLAN<ID>-*-Users (覆寫 Machine VLAN)"
echo "   - MAB (納管啟用) : SG-HQ-8021X-VLAN<ID>-*-MAB"
echo "   - MAB (停用/移出): Access-Reject (由交換器導向 Critical VLAN 98)"
echo "   - MAB (未知設備) : Access-Accept -> Guest VLAN ${GUEST_VLAN}"
echo "=============================================================================="
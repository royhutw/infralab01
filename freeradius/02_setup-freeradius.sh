#!/usr/bin/env bash
# ==============================================================================
#  02_setup-freeradius.sh (v7.1 終極實戰驗收版・支援 EAP-TEAP / EAP-TLS / MAB / VoIP OUI)
#  適用系統：Debian 13 (Trixie) / FreeRADIUS 3.2.7
#  前置條件：
#    1. 同目錄下需存在 config.env
#    2. 已執行 01_setup-certmonger-cepces.sh 完成 AD 加域與 CEP/CES 憑證簽發
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

VOICE_VLAN="${VOICE_VLAN:-38}"
VOIP_OUI_REGEX="${VOIP_OUI_REGEX:-^(0c383e|0001e3|00036b|001243|00096e|00040d|001b4f|000fe2|0060b9|00d01e|00e075|0004f2|0011a6|00e0bb|000b82|001565)}"
# ──────────────────────────────────────────────────────────────────────────────

echo "=============================================================================="
echo " 開始執行 FreeRADIUS 802.1X (EAP-TEAP / EAP-TLS / MAB / VoIP) 自動化部署 (v7.1)"
echo " 主機 FQDN  : ${HOSTNAME_FQDN}"
echo " 目標 AD DC : ${LDAP_SERVER}"
echo " 目標群組 OU: ${HQ_GROUP_OU}"
echo " 交換器網段 : ${SW_SUBNET}"
echo " 語音 VLAN  : ${VOICE_VLAN} (OUI Match: ${VOIP_OUI_REGEX})"
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

cat "${LOCAL_SUB_CA_CRT}" "${LOCAL_ROOT_CA_CRT}" > "${CORP_CA_CHAIN}"
chown root:freerad "${CORP_CA_CHAIN}"
chmod 640 "${CORP_CA_CHAIN}"

usermod -aG ssl-cert freerad || true
if getent group winbindd_priv >/dev/null; then
    usermod -aG winbindd_priv freerad || true
fi

chown root:freerad "${KEY_PATH}" "${CERT_PATH}"
chmod 640 "${KEY_PATH}"
chmod 644 "${CERT_PATH}"

setfacl -m u:freerad:r "${KEYTAB_PATH}"
echo "    [OK] 內部 CA 憑證鏈與私鑰/Keytab 權限配置完成。"

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 3/7] 配置 Kerberos Ticket 自動維護機制 (供 rlm_ldap GSSAPI 使用)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [3/7] 配置 Kerberos/SASL 參數與 TGT 自動續約服務 (freerad-kinit.timer)..."

if ! grep -q "rdns = false" /etc/krb5.conf; then
    sed -i '/\[libdefaults\]/a \    rdns = false' /etc/krb5.conf
fi
if ! grep -q "SASL_NOCANON" /etc/ldap/ldap.conf; then
    echo "SASL_NOCANON on" >> /etc/ldap/ldap.conf
fi

install -d -m 0750 -o freerad -g freerad "${KRB5_CCACHE_DIR}"

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
#  [步驟 6/7] 設定 EAP 模組 (EAP-TEAP / EAP-TLS + 分片最佳化)
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

    tls {
        tls = tls-common
        virtual_server = check-eap-tls
    }

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

# 若已執行過 03_setup-crl-sync.sh，自動保留 check_crl = yes 並重新合成含 CRL 的憑證鏈
if [ -x "${SYNC_SCRIPT_PATH:-/usr/local/bin/update-freeradius-crl.sh}" ]; then
    echo "    [INFO] 偵測到已部署 03 CRL 同步腳本，自動保留 check_crl = yes 並同步 CRL..."
    cp -f "${CONFIG_FILE}" "${INSTALLED_ENV_FILE}"
    chmod 640 "${INSTALLED_ENV_FILE}"
    sed -i '/ca_path =/a \        check_crl = yes' "${FR_CONF_DIR}/mods-available/eap"
    "${SYNC_SCRIPT_PATH}" || true
fi

# ══════════════════════════════════════════════════════════════════════════════
#  [步驟 7/7] 設定動態 VLAN 判斷策略與虛擬伺服器 (Policy + Sites)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "==> [7/7] 寫入五段式群組動態 VLAN 與多廠牌 VoIP OUI 策略組態..."

cat << 'EOF' > "${FR_CONF_DIR}/policy.d/corp_8021x_vlan"
# ==============================================================================
#  CORP.FOO.BAR.TW 802.1X 動態 VLAN 指派核心邏輯
#  支援：EAP-TEAP / EAP-TLS / AD MAB / 多廠牌 VoIP OUI 自動派發 Voice Domain
# ==============================================================================

normalize_ad_identity {
    if (&User-Name =~ /^host\/([a-zA-Z0-9_-]+)\.__DOMAIN_REGEX__$/i) {
        update request {
            &Stripped-User-Name := "%{1}$"
        }
    }
    elsif (&TLS-Client-Cert-Common-Name && (&TLS-Client-Cert-Common-Name =~ /^([a-zA-Z0-9_-]+)\.__DOMAIN_REGEX__$/i)) {
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

evaluate_eap_vlan {
    normalize_ad_identity

    ldap.authorize
    if (notfound) {
        reject
    }

    if (&control:Tmp-Integer-0 && ("%{expr:%{control:Tmp-Integer-0} & 2}" == "2")) {
        reject
    }

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

evaluate_mab_vlan {
    update request {
        &Stripped-User-Name := "%{tolower:%{User-Name}}"
    }

    ldap.authorize
    # 情況 1：AD 中已建檔納管的 MAC 帳號
    if (ok || updated) {
        # 若帳號被停用 -> 立即拒絕 (交換器導向隔離區 VLAN 98)
        if (&control:Tmp-Integer-0 && ("%{expr:%{control:Tmp-Integer-0} & 2}" == "2")) {
            reject
        }

        foreach &control:LDAP-Group {
            if ("%{Foreach-Variable-0}" =~ /^CN=SG-HQ-8021X-VLAN([0-9]+)-([^,]+)-MAB,/i) {
                update session-state {
                    &Tmp-String-0 := "%{1}"
                    &Tmp-String-2 := "%{2}"
                }
                break
            }
        }

        if (!&session-state:Tmp-String-0) {
            reject
        }
    }
    # 情況 2：AD 中查無此 MAC -> 先檢查是否屬於已知廠牌 VoIP 話機 OUI
    elsif (notfound) {
        if (&Stripped-User-Name =~ /__VOIP_OUI_REGEX__/i) {
            update session-state {
                &Tmp-String-0 := "__VOICE_VLAN__"
                &Tmp-String-2 := "VOICE_OUI_AUTO"
            }
        }
        else {
            update session-state {
                &Tmp-String-0 := "__GUEST_VLAN__"
            }
        }
    }
    else {
        reject
    }
}

apply_vlan_reply {
    # 若為單層 EAP-TLS (外層尚未填入 Tmp-String-0)，在此處透過 ldap.authorize 計算並檢查群組
    if (!&session-state:Tmp-String-0 && &EAP-Message) {
        evaluate_eap_vlan
    }

    if (&session-state:Tmp-String-0) {
        # 若判定為語音 VLAN (38) 或 VoIP 設備，回傳 Cisco 專屬語音域屬性 (進入 Domain: VOICE)
        if ((&session-state:Tmp-String-0 == "__VOICE_VLAN__") || (&session-state:Tmp-String-2 && (&session-state:Tmp-String-2 =~ /VOICE|IPPhone|Phone/i))) {
            update reply {
                &Cisco-AVPair := "device-traffic-class=voice"
                &Tunnel-Type := VLAN
                &Tunnel-Medium-Type := IEEE-802
                &Tunnel-Private-Group-Id := &session-state:Tmp-String-0
                &Session-Timeout := __REAUTH_TIMEOUT__
                &Termination-Action := RADIUS-Request
            }
        }
        # 一般資料域設備 (進入 Domain: DATA)
        else {
            update reply {
                &Tunnel-Type := VLAN
                &Tunnel-Medium-Type := IEEE-802
                &Tunnel-Private-Group-Id := &session-state:Tmp-String-0
                &Session-Timeout := __REAUTH_TIMEOUT__
                &Termination-Action := RADIUS-Request
            }
        }
    }
}
EOF

DOMAIN_REGEX=$(echo "${DOMAIN}" | sed 's/\./\\./g')
sed -i "s|__DOMAIN_REGEX__|${DOMAIN_REGEX}|g" "${FR_CONF_DIR}/policy.d/corp_8021x_vlan"
sed -i "s|__GUEST_VLAN__|${GUEST_VLAN}|g" "${FR_CONF_DIR}/policy.d/corp_8021x_vlan"
sed -i "s|__VOICE_VLAN__|${VOICE_VLAN}|g" "${FR_CONF_DIR}/policy.d/corp_8021x_vlan"
sed -i "s@__VOIP_OUI_REGEX__@${VOIP_OUI_REGEX}@g" "${FR_CONF_DIR}/policy.d/corp_8021x_vlan"
sed -i "s|__REAUTH_TIMEOUT__|${REAUTH_TIMEOUT}|g" "${FR_CONF_DIR}/policy.d/corp_8021x_vlan"

cat << 'EOF' > "${FR_CONF_DIR}/sites-available/check-eap-tls"
server check-eap-tls {
    authorize {
        update config {
            &Auth-Type := Accept
        }
    }
}
EOF
ln -sf "${FR_CONF_DIR}/sites-available/check-eap-tls" "${FR_CONF_DIR}/sites-enabled/check-eap-tls"

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
        evaluate_eap_vlan
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

        if (&EAP-Message) {
            eap {
                ok = return
                updated = return
            }
        }
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

# 若已執行過 04_setup-nac-json-log.sh，自動保留 linelog_nac_json 掛載
if [ -f "${FR_CONF_DIR}/mods-enabled/linelog_nac_json" ]; then
    echo "    [INFO] 偵測到已啟用 linelog_nac_json，自動掛載至 default 虛擬伺服器..."
    sed -i '/apply_vlan_reply/a \        linelog_nac_json' "${FR_CONF_DIR}/sites-available/default"
    sed -i '/attr_filter.access_reject/a \            linelog_nac_json' "${FR_CONF_DIR}/sites-available/default"
fi

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
echo " [SUCCESS] FreeRADIUS 802.1X 動態 VLAN 伺服器部署完成 (v7.1)！"
echo "   - 語音設備 OUI 自動放行 : VLAN ${VOICE_VLAN} (Cisco-AVPair = device-traffic-class=voice)"
echo "   - 未知訪客設備自動放行 : Guest VLAN ${GUEST_VLAN}"
echo "=============================================================================="
# ============================================================
#  PowerShell - 設定 Domain Controllers OU 安全性 GPO
#  適用網域：corp.foo.bar.tw
#  套用 OU ：Domain Controllers
#  適用作業系統：Windows Server 2012 R2 及以後版本
#
#  設定項目：
#    1. 停用 SMBv1
#    2. 停用 LLMNR
#    3. NTLM 限制（LmCompatibilityLevel）
#    4. LDAP Signing（LDAPServerIntegrity）
#
#  需求模組：GroupPolicy（RSAT-AD-Tools 已內含，DC 上預設已安裝）
# ============================================================

#region ── 參數區（請依實際環境修改） ────────────────────────
$GPOParams = @{
    DomainName  = 'corp.foo.bar.tw'                       # 網域 FQDN
    TargetOU    = 'OU=Domain Controllers,DC=corp,DC=foo,DC=bar,DC=tw'  # 套用的 OU DistinguishedName
    GPOName     = 'DC Security Baseline - SMB-LLMNR-NTLM-LDAP'         # 此 GPO 的名稱
    GPOComment  = '安全性基準設定：停用SMBv1/LLMNR、限制NTLM、強制LDAP簽章'
}
#endregion

# ── 確認 GroupPolicy 模組已載入 ─────────────────────────────
Import-Module GroupPolicy -ErrorAction Stop

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  建立/更新 GPO：$($GPOParams.GPOName)"               -ForegroundColor Cyan
Write-Host "  套用 OU       ：$($GPOParams.TargetOU)"             -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

# ── Step 1：建立 GPO（若已存在則直接取用） ───────────────────
$ExistingGPO = Get-GPO -Name $GPOParams.GPOName -Domain $GPOParams.DomainName -ErrorAction SilentlyContinue

if ($null -eq $ExistingGPO) {
    Write-Host "[1/3] 建立新 GPO：$($GPOParams.GPOName) ..." -ForegroundColor Yellow
    $GPO = New-GPO -Name $GPOParams.GPOName `
                    -Comment $GPOParams.GPOComment `
                    -Domain $GPOParams.DomainName
} else {
    Write-Host "[1/3] GPO 已存在，將直接更新設定值 ..." -ForegroundColor Yellow
    $GPO = $ExistingGPO
}

# ── Step 2：連結（Link）GPO 到 Domain Controllers OU ─────────
Write-Host "[2/3] 連結 GPO 到目標 OU ..." -ForegroundColor Yellow
$ExistingLink = Get-GPInheritance -Target $GPOParams.TargetOU -Domain $GPOParams.DomainName |
                Select-Object -ExpandProperty GpoLinks |
                Where-Object { $_.DisplayName -eq $GPOParams.GPOName }

if ($null -eq $ExistingLink) {
    New-GPLink -Guid $GPO.Id `
               -Target $GPOParams.TargetOU `
               -Domain $GPOParams.DomainName `
               -LinkEnabled Yes `
               -Enforced Yes | Out-Null
    Write-Host "       已建立連結（Enforced = Yes）。" -ForegroundColor Gray
} else {
    Write-Host "       GPO 已連結至此 OU，略過建立連結步驟。" -ForegroundColor Gray
}

# ── Step 3：設定登錄檔（Registry.pol）各項安全性設定 ─────────
Write-Host "[3/3] 套用安全性設定值 ..." -ForegroundColor Yellow
Write-Host ""


# ════════════════════════════════════════════════════════════
#  1. 停用 SMBv1
# ════════════════════════════════════════════════════════════
#
#  用途：
#    SMBv1 是已知具有重大安全漏洞的舊版通訊協定（如 EternalBlue /
#    WannaCry 即透過 SMBv1 漏洞傳播），自 Windows Server 2016 起
#    已預設停用，但 2012 R2 仍預設啟用，故需透過 GPO 強制停用。
#
#  登錄檔路徑：
#    HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters
#    值名稱：SMB1（DWORD）
#    0 = 停用 SMBv1　／　1 = 啟用 SMBv1
#
#  各版本作業系統預設值：
#    ┌─────────────────────────────┬──────────────┐
#    │ 作業系統                       │ SMBv1 預設值   │
#    ├─────────────────────────────┼──────────────┤
#    │ Windows Server 2012 R2        │ 1（啟用）      │
#    │ Windows Server 2016           │ 0（停用，可選用元件）│
#    │ Windows Server 2019           │ 0（停用，可選用元件）│
#    │ Windows Server 2022           │ 0（停用，可選用元件）│
#    └─────────────────────────────┴──────────────┘
#
#  本設定強制設為 0（停用），確保所有版本一致。
#
Write-Host "      [1] 停用 SMBv1 ..." -ForegroundColor Gray
Set-GPRegistryValue -Name $GPOParams.GPOName `
    -Key 'HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' `
    -ValueName 'SMB1' `
    -Type DWord `
    -Value 0 | Out-Null


# ════════════════════════════════════════════════════════════
#  2. 停用 LLMNR（Link-Local Multicast Name Resolution）
# ════════════════════════════════════════════════════════════
#
#  用途：
#    LLMNR 用於本機網段內無 DNS 時的名稱解析廣播，常被用於
#    LLMNR/NBT-NS Poisoning 攻擊（如 Responder 工具）來竊取
#    NTLM Hash。DC 環境應完全依賴 DNS，故建議停用。
#
#  登錄檔路徑：
#    HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient
#    值名稱：EnableMulticast（DWORD）
#    0 = 停用 LLMNR　／　1 = 啟用 LLMNR
#
#  各版本作業系統預設值：
#    ┌─────────────────────────────┬──────────────────┐
#    │ 作業系統                       │ LLMNR 預設值        │
#    ├─────────────────────────────┼──────────────────┤
#    │ Windows Server 2012 R2        │ 1（啟用，無原生策略項）│
#    │ Windows Server 2016 / 2019    │ 1（啟用，無原生策略項）│
#    │ Windows Server 2022           │ 1（啟用，無原生策略項）│
#    └─────────────────────────────┴──────────────────┘
#
#  註：此登錄機碼路徑對應 GPO 中「電腦設定 → 系統管理範本 →
#      網路 → DNS 用戶端 → 關閉多播名稱解析」原則，所有版本
#      皆預設未設定（等同啟用 LLMNR），需手動停用。
#
Write-Host "      [2] 停用 LLMNR ..." -ForegroundColor Gray
Set-GPRegistryValue -Name $GPOParams.GPOName `
    -Key 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' `
    -ValueName 'EnableMulticast' `
    -Type DWord `
    -Value 0 | Out-Null


# ════════════════════════════════════════════════════════════
#  3. NTLM 限制（LmCompatibilityLevel）
# ════════════════════════════════════════════════════════════
#
#  用途：
#    控制 NTLM 驗證等級，數值越高代表安全性越高、相容性越低。
#    設定為 5 表示「僅傳送 NTLMv2 回應，拒絕 LM 與 NTLM」，
#    可避免使用較弱、已被破解的 LM / NTLMv1 雜湊進行驗證。
#
#  登錄檔路徑：
#    HKLM\SYSTEM\CurrentControlSet\Control\Lsa
#    值名稱：LmCompatibilityLevel（DWORD）
#
#  數值對照表：
#    0 = 傳送 LM 與 NTLM 回應，永不使用 NTLMv2 Session Security
#    1 = 傳送 LM 與 NTLM 回應，若協商支援則使用 NTLMv2 Session Security
#    2 = 僅傳送 NTLM 回應
#    3 = 僅傳送 NTLMv2 回應
#    4 = 僅傳送 NTLMv2 回應，拒絕 LM（DC 拒絕 LM 驗證）
#    5 = 僅傳送 NTLMv2 回應，拒絕 LM 與 NTLM（DC 拒絕 LM 與 NTLM 驗證）★ 本次設定值
#
#  各版本作業系統預設值（獨立伺服器，未加入網域 / 未套用GPO前）：
#    ┌─────────────────────────────┬──────────────────────────┐
#    │ 作業系統                       │ LmCompatibilityLevel 預設值  │
#    ├─────────────────────────────┼──────────────────────────┤
#    │ Windows Server 2012 R2        │ 3（僅傳送 NTLMv2 回應）       │
#    │ Windows Server 2016           │ 3（僅傳送 NTLMv2 回應）       │
#    │ Windows Server 2019           │ 3（僅傳送 NTLMv2 回應）       │
#    │ Windows Server 2022           │ 3（僅傳送 NTLMv2 回應）       │
#    └─────────────────────────────┴──────────────────────────┘
#
#  註：上述為作業系統登錄檔的「本機原始預設值」；但網域控制站
#      一旦加入網域，實際生效值會受「預設網域控制站原則」
#      （Default Domain Controllers Policy）影響。若該原則未
#      設定此項，則沿用本機預設值 3。本次將其提升為 5，限制
#      更為嚴格，避免 NTLM / NTLMv1 被用於驗證。
#
#  相容性注意事項：
#    設定為 5 後，仍依賴 NTLMv1 或 LM 驗證的舊系統
#    （如極舊版印表機、第三方應用程式、Windows XP 之前的用戶端）
#    將無法完成驗證，請先確認環境內無此類舊系統依賴。
#
Write-Host "      [3] 設定 NTLM 限制（LmCompatibilityLevel = 5）..." -ForegroundColor Gray
Set-GPRegistryValue -Name $GPOParams.GPOName `
    -Key 'HKLM\SYSTEM\CurrentControlSet\Control\Lsa' `
    -ValueName 'LmCompatibilityLevel' `
    -Type DWord `
    -Value 5 | Out-Null


# ════════════════════════════════════════════════════════════
#  4. LDAP Signing（LDAPServerIntegrity）
# ════════════════════════════════════════════════════════════
#
#  用途：
#    控制網域控制站對 LDAP 用戶端連線是否要求簽章，可防止
#    LDAP Relay / Man-in-the-Middle 攻擊竄改未簽章的 LDAP 流量。
#    此設定僅作用於 DC 角色的伺服器（套用在 Domain Controllers OU）。
#
#  登錄檔路徑：
#    HKLM\SYSTEM\CurrentControlSet\Services\NTDS\Parameters
#    值名稱：LDAPServerIntegrity（DWORD）
#
#  數值對照表：
#    1 = 無須簽章（用戶端可協商是否簽章，未簽章連線仍可成功）
#    2 = 要求簽章（拒絕未簽章或未使用 SSL/TLS 加密的 LDAP 連線）★ 本次設定值
#
#  各版本作業系統預設值（DC 角色，未套用GPO前的原生預設）：
#    ┌─────────────────────────────┬──────────────────────────┐
#    │ 作業系統                       │ LDAPServerIntegrity 預設值   │
#    ├─────────────────────────────┼──────────────────────────┤
#    │ Windows Server 2012 R2        │ 1（無須簽章）                │
#    │ Windows Server 2016           │ 1（無須簽章）                │
#    │ Windows Server 2019           │ 1（無須簽章）                │
#    │ Windows Server 2022 (含KB更新後)│ 2（要求簽章，視累積更新而定）  │
#    └─────────────────────────────┴──────────────────────────┘
#
#  註：微軟自 2020 年起透過累積更新（KB4520412 等）逐步調整
#      Windows Server 2019 / 2022 的安全基準建議值為 2（要求簽章），
#      但「登錄檔原生預設值」在多數版本仍為 1，必須透過 GPO 或
#      手動設定才能強制為 2。本次明確設定為 2，確保所有版本一致。
#
#  相容性注意事項：
#    設定為 2 後，所有透過 LDAP 連線且未啟用 LDAPS（636 埠）或
#    未支援 LDAP 簽章的應用程式 / 裝置（如部分 NAS、舊版 LDAP
#    瀏覽工具）將連線失敗，建議先盤點環境內 LDAP 用戶端後再套用。
#
Write-Host "      [4] 設定 LDAP Signing（LDAPServerIntegrity = 2）..." -ForegroundColor Gray
Set-GPRegistryValue -Name $GPOParams.GPOName `
    -Key 'HKLM\SYSTEM\CurrentControlSet\Services\NTDS\Parameters' `
    -ValueName 'LDAPServerIntegrity' `
    -Type DWord `
    -Value 2 | Out-Null


# ── 完成訊息 ─────────────────────────────────────────────────
Write-Host ""
Write-Host "=================================================="  -ForegroundColor Green
Write-Host "  GPO 設定完成！"                                    -ForegroundColor Green
Write-Host "=================================================="  -ForegroundColor Green
Write-Host ""
Write-Host "設定摘要："
Write-Host "  GPO 名稱     : $($GPOParams.GPOName)"
Write-Host "  套用 OU      : $($GPOParams.TargetOU)"
Write-Host "  SMBv1        : 停用 (0)"
Write-Host "  LLMNR        : 停用 (0)"
Write-Host "  NTLM 限制    : 5（僅 NTLMv2，拒絕 LM 與 NTLM）"
Write-Host "  LDAP Signing : 2（要求簽章）"
Write-Host ""

# ── 後續驗證指令 ─────────────────────────────────────────────
Write-Host "後續可用以下指令驗證設定："
Write-Host '  Get-GPO -Name "' $GPOParams.GPOName '" -Domain "' $GPOParams.DomainName '"'
Write-Host '  Get-GPOReport -Name "' $GPOParams.GPOName '" -ReportType Html -Path .\GPOReport.html'
Write-Host '  gpupdate /force          # 在 DC 上手動立即更新原則'
Write-Host '  gpresult /r /scope:computer   # 確認原則是否已生效'
Write-Host ""
Write-Host "[提醒] LmCompatibilityLevel 與 LDAPServerIntegrity 設定" -ForegroundColor Yellow
Write-Host "       屬於需要 gpupdate /force 或重新開機才會完全生效的設定，" -ForegroundColor Yellow
Write-Host "       套用後建議排程重新啟動受影響的網域控制站。" -ForegroundColor Yellow
Write-Host ""
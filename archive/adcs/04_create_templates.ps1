# ============================================================
#  04_create_templates.ps1
#  建立 802.1x EAP-TLS 用途的憑證範本
#  範本一：EAP-TLS Computer（電腦憑證，有效期 1 年）
#  範本二：EAP-TLS User    （使用者憑證，有效期 2 年）
#  範本三：NPS Server      （RADIUS/NPS 伺服器憑證，有效期 2 年）
#
#  所有範本設定：
#    - RSA 4096 金鑰
#    - SHA256 雜湊
#    - 自動核准（不需 CA Manager 審核）
#    - 支援 Auto-Enrollment
# ============================================================

#region ── 參數區 ────────────────────────────────────────────
$Params = @{
    DomainName      = 'corp.foo.bar.tw'
    DomainDN        = 'DC=corp,DC=foo,DC=bar,DC=tw'

    # ── 範本名稱 ─────────────────────────────────────────────
    ComputerTemplateName = 'EAP-TLS-Computer'
    UserTemplateName     = 'EAP-TLS-User'
    NPSTemplateName      = 'EAP-TLS-NPS-Server'

    # ── 憑證有效期（秒數）────────────────────────────────────
    # Computer：1 年 = 365 × 24 × 3600 = 31536000 秒
    ComputerValidity     = '31536000'
    # User / NPS：2 年 = 730 × 24 × 3600 = 63072000 秒
    UserValidity         = '63072000'
    NPSValidity          = '63072000'

    # ── 金鑰設定 ─────────────────────────────────────────────
    KeyLength            = 4096
    HashAlgorithm        = 'sha256'
}
#endregion

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  建立 802.1x EAP-TLS 憑證範本"                    -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

# ── 載入 AD 相關模組 ─────────────────────────────────────────
Import-Module ActiveDirectory -ErrorAction Stop

# ── 取得 CA 設定路徑 ─────────────────────────────────────────
$ConfigContext = (Get-ADRootDSE).configurationNamingContext
$TemplateContainer = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigContext"

# ── 函式：複製內建範本並修改屬性 ────────────────────────────
function New-CertificateTemplate {
    param (
        [string] $NewTemplateName,
        [string] $SourceTemplateName,   # 複製來源（內建範本）
        [string] $DisplayName,
        [string] $ValiditySeconds,
        [string] $Description,
        [int]    $KeyUsage,             # 金鑰用途旗標
        [array]  $EKU,                  # 延伸金鑰用途 OID
        [bool]   $ClientAuth = $true,
        [bool]   $ServerAuth = $false,
        [int]    $SchemaVersion = 2     # Schema 2 = Windows Server 2003 相容，支援 Auto-Enrollment
    )

    Write-Host "  建立範本：$DisplayName ..." -ForegroundColor Gray

    # 取得來源範本
    $SourceTemplate = Get-ADObject `
        -SearchBase $TemplateContainer `
        -Filter { Name -eq $SourceTemplateName } `
        -Properties * `
        -ErrorAction SilentlyContinue

    if ($null -eq $SourceTemplate) {
        Write-Host "  [ERROR] 找不到來源範本：$SourceTemplateName" -ForegroundColor Red
        return $false
    }

    # 確認目標範本是否已存在
    $ExistingTemplate = Get-ADObject `
        -SearchBase $TemplateContainer `
        -Filter { Name -eq $NewTemplateName } `
        -ErrorAction SilentlyContinue

    if ($null -ne $ExistingTemplate) {
        Write-Host "  [SKIP] 範本已存在：$NewTemplateName（略過建立）" -ForegroundColor Yellow
        return $true
    }

    # 複製來源範本物件
    $NewTemplate = $SourceTemplate | Select-Object -Property *
    $NewOID = New-TemplateOID -Server (Get-ADDomainController).HostName -ConfigContext $ConfigContext

    # 使用 ADSI 建立新範本（直接操作 AD Schema）
    $ADSI = [ADSI]"LDAP://$TemplateContainer"
    $NewTemplateObj = $ADSI.Create('pKICertificateTemplate', "CN=$NewTemplateName")

    # 設定必要屬性
    $NewTemplateObj.Put('displayName',           $DisplayName)
    $NewTemplateObj.Put('distinguishedName',     "CN=$NewTemplateName,$TemplateContainer")
    $NewTemplateObj.Put('flags',                 131680)       # Auto-Enrollment 旗標
    $NewTemplateObj.Put('revision',              '100')
    $NewTemplateObj.Put('pKIDefaultKeySpec',     1)            # AT_KEYEXCHANGE
    $NewTemplateObj.Put('pKIMaxIssuingDepth',    0)
    $NewTemplateObj.Put('msPKI-Cert-Template-OID', $NewOID)
    $NewTemplateObj.Put('msPKI-Certificate-Application-Policy', $EKU)
    $NewTemplateObj.Put('msPKI-Certificate-Name-Flag', 1)     # Subject from AD（CN = 帳號名稱）
    $NewTemplateObj.Put('msPKI-Enrollment-Flag', 0x20)        # Auto-Enrollment 啟用旗標
    $NewTemplateObj.Put('msPKI-Minimal-Key-Size', $Params.KeyLength)
    $NewTemplateObj.Put('msPKI-Private-Key-Flag', 0x101)      # 允許匯出私鑰（EAP-TLS 不需要，設為不可匯出請改 0x100）
    $NewTemplateObj.Put('msPKI-RA-Signature',    0)           # 0 = 不需 RA 簽章（自動核准）
    $NewTemplateObj.Put('msPKI-Template-Minor-Revision', 1)
    $NewTemplateObj.Put('msPKI-Template-Schema-Version', $SchemaVersion)
    $NewTemplateObj.Put('pKICriticalExtensions', @('2.5.29.15', '2.5.29.19'))  # KeyUsage, BasicConstraints
    $NewTemplateObj.Put('pKIDefaultCSPs',        @("1,Microsoft RSA SChannel Cryptographic Provider"))
    $NewTemplateObj.Put('pKIExpirationPeriod',   [System.Text.Encoding]::ASCII.GetBytes('') )
    $NewTemplateObj.Put('pKIKeyUsage',           [byte[]]@($KeyUsage, 0))
    $NewTemplateObj.Put('pKIExtendedKeyUsage',   $EKU)

    # 有效期（以負100奈秒為單位的二進位大端序）
    # 使用 certutil 計算方式：-ValidityPeriod 以秒換算
    $ValidityBytes = [System.BitConverter]::GetBytes([long](-[long]$ValiditySeconds * 10000000))
    [Array]::Reverse($ValidityBytes)
    $NewTemplateObj.Put('pKIExpirationPeriod', $ValidityBytes)

    # 更新期（有效期的 80%，提早更新）
    $RenewalBytes = [System.BitConverter]::GetBytes([long](-[long]([math]::Round([long]$ValiditySeconds * 0.8)) * 10000000))
    [Array]::Reverse($RenewalBytes)
    $NewTemplateObj.Put('pKIOverlapPeriod', $RenewalBytes)

    $NewTemplateObj.SetInfo()
    Write-Host "  [OK] 範本建立成功：$DisplayName" -ForegroundColor Green
    return $true
}

# ── 函式：產生唯一 OID ────────────────────────────────────────
function New-TemplateOID {
    param ([string]$Server, [string]$ConfigContext)
    $OIDPath = "CN=OID,CN=Public Key Services,CN=Services,$ConfigContext"
    $ForestOID = (Get-ADObject -Identity $OIDPath -Properties msPKI-Cert-Template-OID).'msPKI-Cert-Template-OID'
    $OIDSuffix = (Get-Random -Minimum 10000000 -Maximum 99999999)
    return "$ForestOID.$OIDSuffix"
}

# ════════════════════════════════════════════════════════════
#  建立範本一：EAP-TLS Computer（電腦憑證，有效期 1 年）
# ════════════════════════════════════════════════════════════
#
#  用途：
#    已加入網域的電腦在使用者尚未登入前進行 802.1x 機器認證
#    （Machine Authentication），適用 EAP-TLS PEAP 或純 TLS。
#
#  EKU OID：
#    1.3.6.1.5.5.7.3.2 = Client Authentication（用戶端驗證）
#    1.3.6.1.5.5.7.3.1 = Server Authentication（此範本不需要，僅 Client）
#
#  KeyUsage：
#    0x80 = Digital Signature
#    0x20 = Key Encipherment（RSA 金鑰交換需要）
#    合計 = 0xA0 = 160（十進位）
#
Write-Host ""
Write-Host "[1/3] 建立 EAP-TLS Computer 範本（1年）..." -ForegroundColor Yellow

# 直接使用 certutil 複製內建 Computer 範本並修改
certutil -dstemplate Computer | Out-Null  # 確認來源範本存在

$ComputerTemplateScript = @"
# 使用 AD LDAP 直接建立範本（certreq / certutil 方式）
`$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
`$DC = `$Domain.FindDomainController().Name
`$ConfigNC = ([ADSI]"LDAP://RootDSE").configurationNamingContext
`$TemplatePath = "LDAP://CN=Certificate Templates,CN=Public Key Services,CN=Services,`$ConfigNC"
`$TemplatesContainer = [ADSI]"`$TemplatePath"

# 複製來源範本：Workstation Authentication（適合 Computer 802.1x）
`$SourceName   = 'WorkstationAuthentication'
`$NewName      = '$($Params.ComputerTemplateName)'
`$Source = [ADSI]"LDAP://CN=`$SourceName,CN=Certificate Templates,CN=Public Key Services,CN=Services,`$ConfigNC"

if (`$Source.Name -eq `$null) {
    Write-Host "[WARN] WorkstationAuthentication 範本不存在，改用 Computer 範本" -ForegroundColor Yellow
    `$SourceName = 'Computer'
    `$Source = [ADSI]"LDAP://CN=`$SourceName,CN=Certificate Templates,CN=Public Key Services,CN=Services,`$ConfigNC"
}

`$New = `$TemplatesContainer.Create('pKICertificateTemplate', "CN=`$NewName")
`$New.Put('displayName', 'EAP-TLS Computer Certificate')
`$New.Put('flags', 131680)
`$New.Put('revision', '100')
`$New.Put('msPKI-Certificate-Name-Flag', 8)        # 使用電腦的 DNS 名稱作為 SAN
`$New.Put('msPKI-Enrollment-Flag', 32)             # 0x20 = Auto-Enrollment 啟用
`$New.Put('msPKI-Minimal-Key-Size', 4096)
`$New.Put('msPKI-RA-Signature', 0)                 # 0 = 自動核准，不需 CA Manager 審核
`$New.Put('msPKI-Template-Schema-Version', 2)
`$New.Put('pKIDefaultKeySpec', 1)
`$New.Put('pKIKeyUsage', [byte[]](0xA0, 0))        # Digital Signature + Key Encipherment
`$New.Put('pKIExtendedKeyUsage', @('1.3.6.1.5.5.7.3.2'))  # Client Authentication
`$New.Put('msPKI-Certificate-Application-Policy', @('1.3.6.1.5.5.7.3.2'))

# 有效期 1 年（以負100奈秒為單位）
`$ValidSecs = 31536000
`$ValidBytes = [BitConverter]::GetBytes([long](-`$ValidSecs * 10000000L))
[Array]::Reverse(`$ValidBytes)
`$New.Put('pKIExpirationPeriod', `$ValidBytes)

# 更新期（有效期 80%，即約 292 天前開始更新）
`$RenewBytes = [BitConverter]::GetBytes([long](-([math]::Round(`$ValidSecs * 0.8)) * 10000000L))
[Array]::Reverse(`$RenewBytes)
`$New.Put('pKIOverlapPeriod', `$RenewBytes)

`$New.SetInfo()
Write-Host '[OK] EAP-TLS Computer 範本建立完成' -ForegroundColor Green
"@

Invoke-Expression $ComputerTemplateScript

# ════════════════════════════════════════════════════════════
#  建立範本二：EAP-TLS User（使用者憑證，有效期 2 年）
# ════════════════════════════════════════════════════════════
#
#  用途：
#    AD 網域使用者登入後進行 802.1x 使用者身份認證（User Authentication）
#    Subject Name 使用 UPN（User Principal Name）格式。
#
#  EKU OID：
#    1.3.6.1.5.5.7.3.2 = Client Authentication
#
Write-Host ""
Write-Host "[2/3] 建立 EAP-TLS User 範本（2年）..." -ForegroundColor Yellow

$UserTemplateScript = @"
`$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
`$ConfigNC = ([ADSI]"LDAP://RootDSE").configurationNamingContext
`$TemplatePath = "LDAP://CN=Certificate Templates,CN=Public Key Services,CN=Services,`$ConfigNC"
`$TemplatesContainer = [ADSI]"`$TemplatePath"

`$NewName = '$($Params.UserTemplateName)'
`$New = `$TemplatesContainer.Create('pKICertificateTemplate', "CN=`$NewName")
`$New.Put('displayName', 'EAP-TLS User Certificate')
`$New.Put('flags', 131648)
`$New.Put('revision', '100')
`$New.Put('msPKI-Certificate-Name-Flag', 1)        # Subject = AD 帳號 CN
`$New.Put('msPKI-Enrollment-Flag', 32)             # 0x20 = Auto-Enrollment 啟用
`$New.Put('msPKI-Minimal-Key-Size', 4096)
`$New.Put('msPKI-RA-Signature', 0)                 # 0 = 自動核准
`$New.Put('msPKI-Template-Schema-Version', 2)
`$New.Put('pKIDefaultKeySpec', 1)
`$New.Put('pKIKeyUsage', [byte[]](0xA0, 0))        # Digital Signature + Key Encipherment
`$New.Put('pKIExtendedKeyUsage', @('1.3.6.1.5.5.7.3.2'))  # Client Authentication

# 有效期 2 年
`$ValidSecs = 63072000
`$ValidBytes = [BitConverter]::GetBytes([long](-`$ValidSecs * 10000000L))
[Array]::Reverse(`$ValidBytes)
`$New.Put('pKIExpirationPeriod', `$ValidBytes)

`$RenewBytes = [BitConverter]::GetBytes([long](-([math]::Round(`$ValidSecs * 0.8)) * 10000000L))
[Array]::Reverse(`$RenewBytes)
`$New.Put('pKIOverlapPeriod', `$RenewBytes)

`$New.SetInfo()
Write-Host '[OK] EAP-TLS User 範本建立完成' -ForegroundColor Green
"@

Invoke-Expression $UserTemplateScript

# ════════════════════════════════════════════════════════════
#  建立範本三：NPS Server（RADIUS 伺服器憑證，有效期 2 年）
# ════════════════════════════════════════════════════════════
#
#  用途：
#    NPS（RADIUS）伺服器向 802.1x 用戶端出示的伺服器憑證
#    EAP-TLS 交握時，用戶端會驗證此憑證以確認 RADIUS 伺服器身份。
#
#  EKU OID：
#    1.3.6.1.5.5.7.3.1 = Server Authentication（必要）
#    1.3.6.1.5.5.7.3.2 = Client Authentication（部分 NPS 情境需要）
#
Write-Host ""
Write-Host "[3/3] 建立 NPS Server 範本（2年）..." -ForegroundColor Yellow

$NPSTemplateScript = @"
`$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
`$ConfigNC = ([ADSI]"LDAP://RootDSE").configurationNamingContext
`$TemplatePath = "LDAP://CN=Certificate Templates,CN=Public Key Services,CN=Services,`$ConfigNC"
`$TemplatesContainer = [ADSI]"`$TemplatePath"

`$NewName = '$($Params.NPSTemplateName)'
`$New = `$TemplatesContainer.Create('pKICertificateTemplate', "CN=`$NewName")
`$New.Put('displayName', 'EAP-TLS NPS Server Certificate')
`$New.Put('flags', 131680)
`$New.Put('revision', '100')
`$New.Put('msPKI-Certificate-Name-Flag', 8)        # DNS 名稱作為 SAN
`$New.Put('msPKI-Enrollment-Flag', 32)             # Auto-Enrollment 啟用
`$New.Put('msPKI-Minimal-Key-Size', 4096)
`$New.Put('msPKI-RA-Signature', 0)                 # 自動核准
`$New.Put('msPKI-Template-Schema-Version', 2)
`$New.Put('pKIDefaultKeySpec', 1)
`$New.Put('pKIKeyUsage', [byte[]](0xA0, 0))
`$New.Put('pKIExtendedKeyUsage', @(
    '1.3.6.1.5.5.7.3.1',   # Server Authentication（NPS 必要）
    '1.3.6.1.5.5.7.3.2'    # Client Authentication
))
`$New.Put('msPKI-Certificate-Application-Policy', @(
    '1.3.6.1.5.5.7.3.1',
    '1.3.6.1.5.5.7.3.2'
))

# 有效期 2 年
`$ValidSecs = 63072000
`$ValidBytes = [BitConverter]::GetBytes([long](-`$ValidSecs * 10000000L))
[Array]::Reverse(`$ValidBytes)
`$New.Put('pKIExpirationPeriod', `$ValidBytes)

`$RenewBytes = [BitConverter]::GetBytes([long](-([math]::Round(`$ValidSecs * 0.8)) * 10000000L))
[Array]::Reverse(`$RenewBytes)
`$New.Put('pKIOverlapPeriod', `$RenewBytes)

`$New.SetInfo()
Write-Host '[OK] NPS Server 範本建立完成' -ForegroundColor Green
"@

Invoke-Expression $NPSTemplateScript

# ── Step 4：將範本發布至 CA（讓 CA 可以使用這些範本簽發） ───
Write-Host ""
Write-Host "[發布] 將範本加入 CA 發布清單..." -ForegroundColor Yellow

$CAName = (certutil -getconfig 2>$null | Select-String 'Config:').ToString().Split('"')[1]

foreach ($Template in @($Params.ComputerTemplateName, $Params.UserTemplateName, $Params.NPSTemplateName)) {
    certutil -setcatemplates "+$Template" | Out-Null
    Write-Host "      [OK] 已發布：$Template" -ForegroundColor Green
}

# ── 設定範本 ACL：允許 Domain Computers 與 Domain Users 自動申請 ──
Write-Host ""
Write-Host "[ACL] 設定範本存取權限..." -ForegroundColor Yellow

$ConfigNC = ([ADSI]"LDAP://RootDSE").configurationNamingContext

# Computer 範本：允許 Domain Computers 群組 Enroll + Auto-Enroll
$ComputerTemplate = [ADSI]"LDAP://CN=$($Params.ComputerTemplateName),CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNC"
$DomainComputers  = New-Object System.Security.Principal.NTAccount("Domain Computers")
$ACE = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $DomainComputers,
    [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
    [System.Security.AccessControl.AccessControlType]::Allow,
    [GUID]'0e10c968-78fb-11d2-90d4-00c04f79dc55'  # Certificate-Enrollment OID
)
$ComputerTemplate.ObjectSecurity.AddAccessRule($ACE)
$ComputerTemplate.CommitChanges()
Write-Host "      [OK] Computer 範本：Domain Computers 已獲得 Enroll 權限" -ForegroundColor Green

# User 範本：允許 Domain Users 群組 Enroll + Auto-Enroll
$UserTemplate = [ADSI]"LDAP://CN=$($Params.UserTemplateName),CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNC"
$DomainUsers  = New-Object System.Security.Principal.NTAccount("Domain Users")
$ACE2 = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    $DomainUsers,
    [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
    [System.Security.AccessControl.AccessControlType]::Allow,
    [GUID]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
)
$UserTemplate.ObjectSecurity.AddAccessRule($ACE2)
$UserTemplate.CommitChanges()
Write-Host "      [OK] User 範本：Domain Users 已獲得 Enroll 權限" -ForegroundColor Green

Write-Host @"

==================================================
  憑證範本建立完成！
  已建立範本：
    - $($Params.ComputerTemplateName)（1年，電腦 Auto-Enrollment）
    - $($Params.UserTemplateName)    （2年，使用者 Auto-Enrollment）
    - $($Params.NPSTemplateName)     （2年，NPS 伺服器）

  下一步：執行 05_configure_autoenrollment_gpo.ps1 設定 GPO
==================================================
"@ -ForegroundColor Green

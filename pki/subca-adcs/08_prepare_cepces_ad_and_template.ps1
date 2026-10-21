# ============================================================
#  08_prepare_cepces_ad_and_template.ps1
#  於 Enterprise Sub CA 伺服器上執行（需具備 Domain/Enterprise Admin 權限）
#
#  執行內容：
#    1. 建立 CEP/CES 專屬 OU，並將 CEP/CES 電腦物件移入該 OU
#    2. 建立 CEP/CES 專屬安全群組，將電腦物件加入群組
#    3. 設定 CEP/CES 電腦物件對 Sub CA 的 Kerberos 限制委派 (HOST / rpcss)
#    4. 建立 CEP-CES-WebServer 憑證範本（含 Auto-Enrollment 與現有憑證續約旗標）
#    5. 套用 dsacls.exe Hardened ACL（停用繼承，僅授權專屬安全群組）與發布至 CA
#    6. 建立並連結專屬 Auto-Enrollment GPO 至 CEP/CES OU
# ============================================================

#region ── 參數區（統一從 CAConfig.psd1 讀取）──────────────────
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
$Params = Merge-CAConfig -Sections 'Global','CepCes'

$Params.ValidityTicks = [long]$Params.ValidityTicks
$Params.RenewalTicks  = [long]$Params.RenewalTicks
#endregion

# ── 確認並安裝必要 RSAT 模組（AD 與 GPO 管理）─────────────────
foreach ($Feature in @('RSAT-AD-PowerShell', 'GPMC')) {
    if (-not (Get-WindowsFeature -Name $Feature).Installed) {
        Write-Host "[前置] 安裝 $Feature..." -ForegroundColor Yellow
        Install-WindowsFeature -Name $Feature -IncludeAllSubFeature | Out-Null
    }
}

Import-Module ActiveDirectory -ErrorAction Stop
Import-Module GroupPolicy     -ErrorAction Stop

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  準備 CEP/CES 獨立主機之 AD 架構、憑證範本與 GPO"    -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

$ConfigNC       = ([ADSI]"LDAP://RootDSE").configurationNamingContext
$TemplateBaseDN = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNC"
$TargetOUDN     = "OU=$($Params.OUName),$($Params.DomainDN)"

# ── 取得 CA Config ────────────────────────────────────────────
$CAConfig = (certutil -getconfig) |
    Where-Object { $_ -match '"(.+\\.+)"' } |
    ForEach-Object { $_ -replace '.*"(.+)".*', '$1' } |
    Select-Object -First 1
$CAConfig = $CAConfig.Trim()

if ([string]::IsNullOrWhiteSpace($CAConfig)) {
    Write-Host "[ERROR] 無法取得 CA Config，請確認在本機 Sub CA 上執行且 CertSvc 已啟動。" -ForegroundColor Red
    exit 1
}
Write-Host "[INFO] CA Config：$CAConfig" -ForegroundColor Gray
Write-Host ""

# ════════════════════════════════════════════════════════════
#  [1/6] 建立專屬 OU 並將 CEP/CES 電腦物件移入
# ════════════════════════════════════════════════════════════
Write-Host "[1/6] 檢查並建立專屬 OU ($TargetOUDN)..." -ForegroundColor Yellow

$ExistingOU = Get-ADOrganizationalUnit -Filter "distinguishedName -eq '$TargetOUDN'" -ErrorAction SilentlyContinue
if ($null -eq $ExistingOU) {
    New-ADOrganizationalUnit -Name $Params.OUName `
                             -Path $Params.DomainDN `
                             -Description $Params.OUDescription `
                             -ProtectedFromAccidentalDeletion $true `
                             -ErrorAction Stop
    Write-Host "      [OK] 已建立 OU：$TargetOUDN" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] OU 已存在：$TargetOUDN" -ForegroundColor DarkGray
}

foreach ($CompName in $Params.ServerComputerNames) {
    try {
        $CompObj = Get-ADComputer -Identity $CompName -ErrorAction Stop
        if ($CompObj.DistinguishedName -notmatch "OU=$($Params.OUName),") {
            Move-ADObject -Identity $CompObj.DistinguishedName -TargetPath $TargetOUDN -ErrorAction Stop
            Write-Host "      [OK] 已將電腦帳號 $CompName 移入 $TargetOUDN" -ForegroundColor Green
        } else {
            Write-Host "      [SKIP] 電腦帳號 $CompName 已位於目標 OU 中" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "      [ERROR] 找不到或無法移動電腦帳號 $CompName ：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "      [提醒] 請先將獨立 CEP/CES 主機加入網域，並確認 CAConfig.psd1 的 ServerComputerNames 正確。" -ForegroundColor Yellow
        exit 1
    }
}

# ════════════════════════════════════════════════════════════
#  [2/6] 建立專屬安全群組並加入 CEP/CES 電腦帳號
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[2/6] 檢查並建立專屬安全群組 ($($Params.GroupName))..." -ForegroundColor Yellow

$ExistingGroup = Get-ADGroup -Filter "Name -eq '$($Params.GroupName)'" -ErrorAction SilentlyContinue
if ($null -eq $ExistingGroup) {
    New-ADGroup -Name $Params.GroupName `
                -SamAccountName $Params.GroupName `
                -GroupCategory Security `
                -GroupScope Global `
                -Path $TargetOUDN `
                -Description 'AD CS CEP/CES 伺服器電腦帳號群組 - 僅此群組可自動申請 CEP-CES-WebServer 憑證' `
                -ErrorAction Stop
    Write-Host "      [OK] 群組已建立：$($Params.GroupName)" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] 群組已存在：$($Params.GroupName)" -ForegroundColor DarkGray
}

foreach ($CompName in $Params.ServerComputerNames) {
    $CompObj  = Get-ADComputer -Identity $CompName -ErrorAction Stop
    $IsMember = Get-ADGroupMember -Identity $Params.GroupName -ErrorAction SilentlyContinue |
                    Where-Object { $_.SamAccountName -eq $CompObj.SamAccountName }
    if ($null -eq $IsMember) {
        Add-ADGroupMember -Identity $Params.GroupName -Members $CompObj -ErrorAction Stop
        Write-Host "      [OK] 已將 $CompName 加入群組 $($Params.GroupName)" -ForegroundColor Green
    } else {
        Write-Host "      [SKIP] $CompName 已是群組成員" -ForegroundColor DarkGray
    }
}

# ════════════════════════════════════════════════════════════
#  [3/6] 設定 Kerberos 限制委派 (Constrained Delegation)
#        允許 CEP/CES 電腦帳號代理用戶端向 Sub CA 的 HOST 與 rpcss 請求服務
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[3/6] 設定 CEP/CES 電腦物件對 Sub CA ($($Params.SubCAComputerName)) 的 Kerberos 限制委派..." -ForegroundColor Yellow

try {
    $SubCAObj  = Get-ADComputer -Identity $Params.SubCAComputerName -Properties dNSHostName -ErrorAction Stop
    $SubCAName = $SubCAObj.Name
    $SubCAFQDN = $SubCAObj.dNSHostName

    # 組合需要委派的 SPN 清單（同時涵蓋 NetBIOS 名稱與 FQDN 的 HOST 及 rpcss 服務）
    $AllowedSPNs = @(
        "HOST/$SubCAName",
        "HOST/$SubCAFQDN",
        "rpcss/$SubCAName",
        "rpcss/$SubCAFQDN"
    )

    foreach ($CompName in $Params.ServerComputerNames) {
        # 設定 msDS-AllowedToDelegateTo 屬性，並開啟 TRUSTED_TO_AUTH_FOR_DELEGATION (Protocol Transition)
        Set-ADComputer -Identity $CompName `
                       -Add @{'msDS-AllowedToDelegateTo' = $AllowedSPNs} `
                       -TrustedForDelegation $false `
                       -TrustedToAuthForDelegation $true `
                       -ErrorAction SilentlyContinue

        # 確保屬性精準覆寫（冪等）
        Set-ADComputer -Identity $CompName `
                       -Replace @{'msDS-AllowedToDelegateTo' = $AllowedSPNs} `
                       -TrustedToAuthForDelegation $true `
                       -ErrorAction Stop

        Write-Host "      [OK] 已完成 $CompName ->$SubCAFQDN (HOST, rpcss) 的 Kerberos 限制委派" -ForegroundColor Green
    }
}
catch {
    Write-Host "      [ERROR] 設定 Kerberos 限制委派失敗：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "      [提醒] 請確認 CAConfig.psd1 內的 SubCAComputerName ($($Params.SubCAComputerName)) 與實際 Sub CA 電腦名稱相符。" -ForegroundColor Yellow
    exit 1
}

# ════════════════════════════════════════════════════════════
#  [4/6] 建立 CEP-CES-WebServer 憑證範本
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[4/6] 建立與檢查憑證範本 ($($Params.WebTemplateName))..." -ForegroundColor Yellow

$ExistingTemplateDN = "CN=$($Params.WebTemplateName),$TemplateBaseDN"
$ExistingTemplate   = Get-ADObject -Filter { distinguishedName -eq$ExistingTemplateDN } `
                          -SearchBase $TemplateBaseDN -ErrorAction SilentlyContinue

if ($null -ne $ExistingTemplate) {
    Write-Host "      [SKIP] 範本 $($Params.WebTemplateName) 已存在，略過重建以保持冪等。" -ForegroundColor DarkGray
} else {
    $SourceDN = "CN=$($Params.SourceTemplate),$TemplateBaseDN"
    $Source   = Get-ADObject -Identity $SourceDN -Properties * -ErrorAction Stop

    $ValidityBytes = [System.BitConverter]::GetBytes($Params.ValidityTicks)
    $RenewalBytes  = [System.BitConverter]::GetBytes($Params.RenewalTicks)
    $KeyUsageBytes = [byte[]](0xA0, 0x00) # Digital Signature + Key Encipherment

    # EnrollmentFlag:
    #   0x20 = CT_FLAG_AUTO_ENROLLMENT (允許自動註冊)
    #   0x80 = CT_FLAG_USER_INTERACTION_REQUIRED 未設定
    # NameFlag:
    #   0x08000000 = CT_FLAG_SUBJECT_ALT_REQUIRE_DNS (SAN 填入電腦 FQDN)
    #   0x10000000 = CT_FLAG_SUBJECT_REQUIRE_DNS_AS_CN (CN 填入電腦 FQDN)
    #   合計 = 0x18000000 (由 AD 資訊自動建置，支援 Auto-Enrollment 與 IIS 自動續約重新繫結)
    $FinalEnrollFlag = 0x20
    $NameFlag        = 0x18000000
    $FinalFlags      = 0x00000020 -bor 0x00000200 -bor 0x00020000 -bor 0x00000040 # 含 CT_FLAG_MACHINE_TYPE (0x40)

    $NewOIDSuffix = Get-Random -Minimum 1000000 -Maximum 9999999
    $NewOID       = "$($Source.'msPKI-Cert-Template-OID').$NewOIDSuffix"

    $NewAttributes = @{
        'displayName'                          = $Params.WebTemplateDisplay
        'revision'                             = '100'
        'flags'                                = [int]$FinalFlags
        'msPKI-Cert-Template-OID'              = $NewOID
        'msPKI-Minimal-Key-Size'               = $Params.KeyLength
        'pKIDefaultKeySpec'                    = 1
        'msPKI-Certificate-Name-Flag'          = $NameFlag
        'msPKI-Enrollment-Flag'                = $FinalEnrollFlag
        'msPKI-RA-Signature'                   = 0
        'msPKI-Template-Schema-Version'        = 2
        'msPKI-Template-Minor-Revision'        = 1
        'pKIExpirationPeriod'                  = $ValidityBytes
        'pKIOverlapPeriod'                     = $RenewalBytes
        'pKIKeyUsage'                          = $KeyUsageBytes
        'pKICriticalExtensions'                = @('2.5.29.15', '2.5.29.19')
        'pKIExtendedKeyUsage'                  = @('1.3.6.1.5.5.7.3.1') # Server Authentication
        'msPKI-Certificate-Application-Policy' = @('1.3.6.1.5.5.7.3.1')
        'pKIDefaultCSPs'                       = @(
            '1,Microsoft RSA SChannel Cryptographic Provider',
            '2,Microsoft Strong Cryptographic Provider'
        )
        'msPKI-Private-Key-Flag'               = 0x00000100 # 私鑰不可匯出
    }

    New-ADObject -Name            $Params.WebTemplateName `
                 -Type            'pKICertificateTemplate' `
                 -Path            $TemplateBaseDN `
                 -OtherAttributes $NewAttributes `
                 -ErrorAction     Stop

    Write-Host "      [OK] 範本建立成功：$($Params.WebTemplateDisplay)" -ForegroundColor Green
    Start-Sleep -Seconds 3
}

# ════════════════════════════════════════════════════════════
#  [5/6] 套用 dsacls Hardened ACL 並發布範本至 Sub CA
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[5/6] 設定範本 Hardened ACL 並發布至 CA..." -ForegroundColor Yellow

dsacls "$ExistingTemplateDN" /P:Y 2>&1 | Out-Null
dsacls "$ExistingTemplateDN" /R "NT AUTHORITY\SYSTEM" 2>&1 | Out-Null
dsacls "$ExistingTemplateDN" /R "NT AUTHORITY\Authenticated Users" 2>&1 | Out-Null

foreach ($AdminGroup in @('Domain Admins','Enterprise Admins')) {
    dsacls "$ExistingTemplateDN" /G "$($Params.NetBIOSDomainName)\${AdminGroup}:GA" 2>&1 | Out-Null
}

# 保留 Authenticated Users 的 Read 權限供 CA 服務本身讀取範本
dsacls "$ExistingTemplateDN" /G "Authenticated Users:GR" 2>&1 | Out-Null

# 僅授權 CEP-CES-Servers-Group 擁有 Read + Enroll + AutoEnrollment
dsacls "$ExistingTemplateDN" /G "$($Params.NetBIOSDomainName)\$($Params.GroupName):GR" 2>&1 | Out-Null
dsacls "$ExistingTemplateDN" /G "$($Params.NetBIOSDomainName)\$($Params.GroupName):CA;Enroll" 2>&1 | Out-Null
dsacls "$ExistingTemplateDN" /G "$($Params.NetBIOSDomainName)\$($Params.GroupName):CA;AutoEnrollment" 2>&1 | Out-Null

Write-Host "      [OK] 已透過 dsacls 停用繼承並僅授權 $($Params.GroupName) 自動註冊" -ForegroundColor Green

# 發布至 CA
certutil -config $CAConfig -setcatemplates "+$($Params.WebTemplateName)" | Out-Null
Write-Host "      [OK] 已將範本 $($Params.WebTemplateName) 發布至 CA" -ForegroundColor Green

# ════════════════════════════════════════════════════════════
#  [6/6] 建立並連結 Auto-Enrollment GPO 至 CEP-CES-Servers OU
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[6/6] 建立並設定專屬 GPO ($($Params.GPOName))..." -ForegroundColor Yellow

$GPO = Get-GPO -Name $Params.GPOName -ErrorAction SilentlyContinue
if ($null -eq $GPO) {
    $GPO = New-GPO -Name $Params.GPOName -Comment '啟用 CEP/CES 伺服器電腦憑證自動申請與續約' -ErrorAction Stop
    Write-Host "      [OK] 已建立 GPO：$($Params.GPOName)" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] GPO 已存在：$($Params.GPOName)" -ForegroundColor DarkGray
}

# 寫入電腦設定之憑證自動註冊登錄值 (AEPolicy = 7：啟用自動註冊 + 自動更新到期憑證 + 更新範本憑證)
Set-GPRegistryValue -Name $Params.GPOName `
                    -Key 'HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment' `
                    -ValueName 'AEPolicy' `
                    -Type DWord `
                    -Value 7 `
                    -ErrorAction Stop | Out-Null
Write-Host "      [OK] 已寫入電腦憑證 Auto-Enrollment 原則 (AEPolicy = 7)" -ForegroundColor Green

# 檢查並連結 GPO 至 OU
$Inheritance = Get-GPInheritance -Target$TargetOUDN
$IsLinked    =$Inheritance.GpoLinks | Where-Object { $_.DisplayName -eq$Params.GPOName }
if ($null -eq$IsLinked) {
    New-GPLink -Name $Params.GPOName -Target$TargetOUDN -LinkEnabled Yes -ErrorAction Stop | Out-Null
    Write-Host "      [OK] 已將 GPO 連結至 $TargetOUDN" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] GPO 已連結至目標 OU" -ForegroundColor DarkGray
}

Write-Host @"

==================================================
  08 前置準備完成！
  請接續登入獨立的 CEP/CES 伺服器 ($($Params.ServerComputerNames -join ', '))，
  執行 09_install_cepces_server.ps1 完成憑證自動領取、IIS 自動重新繫結與服務安裝。
==================================================
"@ -ForegroundColor Cyan
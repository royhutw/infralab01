# ============================================================
#  08_prepare_cepces_ad_and_template.ps1 (全篇零反引號防沾黏版)
#  於 Enterprise Sub CA 伺服器上執行（需具備 Domain/Enterprise Admin 權限）
# ============================================================

#region ── 參數區（統一從 CAConfig.psd1 讀取：Global、Templates、CepCes）──
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
$Params = Merge-CAConfig -Sections 'Global','Templates','CepCes'

$Params.ValidityTicks = [long]$Params.ValidityTicks
$Params.RenewalTicks  = [long]$Params.RenewalTicks
#endregion

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
    $OUParams = @{
        Name                            = $Params.OUName
        Path                            = $Params.DomainDN
        Description                     = $Params.OUDescription
        ProtectedFromAccidentalDeletion = $true
        ErrorAction                     = 'Stop'
    }
    New-ADOrganizationalUnit @OUParams
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
        exit 1
    }
}

# ════════════════════════════════════════════════════════════
#  [2/6] 建立專屬安全群組並加入 CEP/CES 及 NPS/RADIUS 電腦帳號
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[2/6] 檢查並建立安全群組 ($($Params.GroupName) 與 $($Params.NPSServersGroupName))..." -ForegroundColor Yellow

# 1. 處理 CEP-CES-Servers-Group 群組
$ExistingGroup = Get-ADGroup -Filter "Name -eq '$($Params.GroupName)'" -ErrorAction SilentlyContinue
if ($null -eq $ExistingGroup) {
    $GrpParams = @{
        Name           = $Params.GroupName
        SamAccountName = $Params.GroupName
        GroupCategory  = 'Security'
        GroupScope     = 'Global'
        Path           = $TargetOUDN
        Description    = 'AD CS CEP/CES 伺服器電腦帳號群組 - 僅此群組可自動申請 CEP-CES-WebServer 憑證'
        ErrorAction    = 'Stop'
    }
    New-ADGroup @GrpParams
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
        Write-Host "      [SKIP] $CompName 已是群組 $($Params.GroupName) 成員" -ForegroundColor DarkGray
    }
}

# 2. 同步檢查並將 NPSServerComputerNames (如 RADIUS1, RADIUS3) 加入 NPS-Servers 群組
if (-not [string]::IsNullOrWhiteSpace($Params.NPSServersGroupName)) {
    $ExistingNPSGroup = Get-ADGroup -Filter "Name -eq '$($Params.NPSServersGroupName)'" -ErrorAction SilentlyContinue
    if ($null -eq $ExistingNPSGroup) {
        $NPSGrpParams = @{
            Name           = $Params.NPSServersGroupName
            SamAccountName = $Params.NPSServersGroupName
            GroupCategory  = 'Security'
            GroupScope     = 'Global'
            Path           = "CN=Users,$($Params.DomainDN)"
            Description    = 'NPS 與 RADIUS 伺服器電腦帳號群組 - 授權申請 EAP-TLS-NPS-Server 憑證'
            ErrorAction    = 'Stop'
        }
        New-ADGroup @NPSGrpParams
        Write-Host "      [OK] 群組已建立：$($Params.NPSServersGroupName)" -ForegroundColor Green
    } else {
        Write-Host "      [SKIP] 群組已存在：$($Params.NPSServersGroupName)" -ForegroundColor DarkGray
    }

    foreach ($NPSCompName in $Params.NPSServerComputerNames) {
        try {
            $NPSCompObj = Get-ADComputer -Identity $NPSCompName -ErrorAction Stop
            $IsNPSMember = Get-ADGroupMember -Identity $Params.NPSServersGroupName -ErrorAction SilentlyContinue |
                               Where-Object { $_.SamAccountName -eq $NPSCompObj.SamAccountName }
            if ($null -eq $IsNPSMember) {
                Add-ADGroupMember -Identity $Params.NPSServersGroupName -Members $NPSCompObj -ErrorAction Stop
                Write-Host "      [OK] 已將 $NPSCompName 加入群組 $($Params.NPSServersGroupName)" -ForegroundColor Green
            } else {
                Write-Host "      [SKIP] $NPSCompName 已是群組 $($Params.NPSServersGroupName) 成員" -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host "      [WARNING] 找不到電腦帳號 $NPSCompName，略過加入群組：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# ════════════════════════════════════════════════════════════
#  [3/6] 設定 Kerberos 限制委派 (Constrained Delegation)
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[3/6] 設定 CEP/CES 電腦物件對 Sub CA ($($Params.SubCAComputerName)) 的 Kerberos 限制委派..." -ForegroundColor Yellow

try {
    $SubCAObj  = Get-ADComputer -Identity $Params.SubCAComputerName -Properties dNSHostName -ErrorAction Stop
    $SubCAName = $SubCAObj.Name
    $SubCAFQDN = $SubCAObj.dNSHostName

    $AllowedSPNs = [string[]]@(
        "HOST/$SubCAName",
        "HOST/$SubCAFQDN",
        "rpcss/$SubCAName",
        "rpcss/$SubCAFQDN"
    )

    foreach ($CompName in $Params.ServerComputerNames) {
        $CompObj = Get-ADComputer -Identity $CompName -ErrorAction Stop

        $DelegateParams = @{
            Identity             = $CompObj.DistinguishedName
            TrustedForDelegation = $false
            Replace              = @{ 'msDS-AllowedToDelegateTo' = $AllowedSPNs }
            ErrorAction          = 'Stop'
        }
        Set-ADComputer @DelegateParams

        $VerifyComp = Get-ADComputer -Identity $CompObj.DistinguishedName -Properties 'msDS-AllowedToDelegateTo' -ErrorAction Stop
        if ($VerifyComp.'msDS-AllowedToDelegateTo'.Count -ge 4) {
            Write-Host "      [OK] 已完成 $CompName -> $SubCAFQDN (HOST, rpcss) 的純 Kerberos 限制委派" -ForegroundColor Green
        } else {
            throw "msDS-AllowedToDelegateTo 屬性寫入後驗證數量不符！"
        }
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
$ExistingTemplate   = Get-ADObject -Filter "distinguishedName -eq '$ExistingTemplateDN'" -SearchBase $TemplateBaseDN -ErrorAction SilentlyContinue

if ($null -ne $ExistingTemplate) {
    Write-Host "      [SKIP] 範本 $($Params.WebTemplateName) 已存在，略過重建以保持冪等。" -ForegroundColor DarkGray
} else {
    $SourceDN = "CN=$($Params.SourceTemplate),$TemplateBaseDN"
    $Source   = Get-ADObject -Identity $SourceDN -Properties * -ErrorAction Stop

    $ValidityBytes = [System.BitConverter]::GetBytes($Params.ValidityTicks)
    $RenewalBytes  = [System.BitConverter]::GetBytes($Params.RenewalTicks)
    $KeyUsageBytes = [byte[]](0xA0, 0x00)

    $FinalEnrollFlag = 0x20
    $NameFlag        = 0x18000000
    $FinalFlags      = 0x00000020 -bor 0x00000200 -bor 0x00020000 -bor 0x00000040

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
        'pKIExtendedKeyUsage'                  = @('1.3.6.1.5.5.7.3.1')
        'msPKI-Certificate-Application-Policy' = @('1.3.6.1.5.5.7.3.1')
        'pKIDefaultCSPs'                       = @(
            '1,Microsoft RSA SChannel Cryptographic Provider',
            '2,Microsoft Strong Cryptographic Provider'
        )
        'msPKI-Private-Key-Flag'               = 0x00000100
    }

    $NewObjParams = @{
        Name            = $Params.WebTemplateName
        Type            = 'pKICertificateTemplate'
        Path            = $TemplateBaseDN
        OtherAttributes = $NewAttributes
        ErrorAction     = 'Stop'
    }
    New-ADObject @NewObjParams

    Write-Host "      [OK] 範本建立成功：$($Params.WebTemplateDisplay)" -ForegroundColor Green
    Start-Sleep -Seconds 3
}

# ════════════════════════════════════════════════════════════
#  [5/6] 套用 dsacls Hardened ACL 並發布範本至 Sub CA
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[5/6] 設定範本 Hardened ACL 並發布至 CA..." -ForegroundColor Yellow

# 1. 處理 CEP-CES 專屬網頁伺服器範本 ($Params.WebTemplateName)
dsacls "$ExistingTemplateDN" /P:Y 2>&1 | Out-Null
dsacls "$ExistingTemplateDN" /R "NT AUTHORITY\SYSTEM" 2>&1 | Out-Null
dsacls "$ExistingTemplateDN" /R "NT AUTHORITY\Authenticated Users" 2>&1 | Out-Null

foreach ($AdminGroup in @('Domain Admins','Enterprise Admins')) {
    dsacls "$ExistingTemplateDN" /G "$($Params.NetBIOSDomainName)\${AdminGroup}:GA" 2>&1 | Out-Null
}

dsacls "$ExistingTemplateDN" /G "Authenticated Users:GR" 2>&1 | Out-Null
dsacls "$ExistingTemplateDN" /G "$($Params.NetBIOSDomainName)\$($Params.GroupName):GR" 2>&1 | Out-Null
dsacls "$ExistingTemplateDN" /G "$($Params.NetBIOSDomainName)\$($Params.GroupName):CA;Enroll" 2>&1 | Out-Null
dsacls "$ExistingTemplateDN" /G "$($Params.NetBIOSDomainName)\$($Params.GroupName):CA;AutoEnrollment" 2>&1 | Out-Null

Write-Host "      [OK] 已透過 dsacls 停用繼承並僅授權 $($Params.GroupName) 自動註冊 $($Params.WebTemplateName)" -ForegroundColor Green

certutil -config $CAConfig -setcatemplates "+$($Params.WebTemplateName)" | Out-Null
Write-Host "      [OK] 已將範本 $($Params.WebTemplateName) 發布至 CA" -ForegroundColor Green

# 2. 處理 NPS / RADIUS 伺服器憑證範本 ($Params.NPSTemplateName) ACL 授權
#    同時授權 NPSServersGroupName 群組與個別電腦帳號 (SamAccountName 含 $)，
#    避免 Linux 主機剛加入群組時因 Kerberos 票證 PAC 尚未更新而遭 CA 拒絕 (0x80094012)。
$NPSTemplateDN  = "CN=$($Params.NPSTemplateName),$TemplateBaseDN"
$NPSTemplateObj = Get-ADObject -Filter "distinguishedName -eq '$NPSTemplateDN'" -SearchBase $TemplateBaseDN -ErrorAction SilentlyContinue

if ($null -ne $NPSTemplateObj) {
    if (-not [string]::IsNullOrWhiteSpace($Params.NPSServersGroupName)) {
        dsacls "$NPSTemplateDN" /G "$($Params.NetBIOSDomainName)\$($Params.NPSServersGroupName):GR" 2>&1 | Out-Null
        dsacls "$NPSTemplateDN" /G "$($Params.NetBIOSDomainName)\$($Params.NPSServersGroupName):CA;Enroll" 2>&1 | Out-Null
        dsacls "$NPSTemplateDN" /G "$($Params.NetBIOSDomainName)\$($Params.NPSServersGroupName):CA;AutoEnrollment" 2>&1 | Out-Null
        Write-Host "      [OK] 已確保群組 $($Params.NetBIOSDomainName)\$($Params.NPSServersGroupName) 具備 $($Params.NPSTemplateName) 註冊權限" -ForegroundColor Green
    }

    foreach ($NPSCompName in $Params.NPSServerComputerNames) {
        try {
            $NPSCompObj = Get-ADComputer -Identity $NPSCompName -ErrorAction Stop
            $NPSSamName = $NPSCompObj.SamAccountName  # 自動帶有結尾 $ 號 (例如 RADIUS3$)

            dsacls "$NPSTemplateDN" /G "$($Params.NetBIOSDomainName)\${NPSSamName}:GR" 2>&1 | Out-Null
            dsacls "$NPSTemplateDN" /G "$($Params.NetBIOSDomainName)\${NPSSamName}:CA;Enroll" 2>&1 | Out-Null
            dsacls "$NPSTemplateDN" /G "$($Params.NetBIOSDomainName)\${NPSSamName}:CA;AutoEnrollment" 2>&1 | Out-Null
            Write-Host "      [OK] 已直接賦予電腦帳號 $($Params.NetBIOSDomainName)\$NPSSamName 對 $($Params.NPSTemplateName) 的讀取與註冊權限" -ForegroundColor Green
        }
        catch {
            Write-Host "      [WARNING] 找不到電腦帳號 $NPSCompName，略過個別授權：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    certutil -config $CAConfig -setcatemplates "+$($Params.NPSTemplateName)" | Out-Null
    Write-Host "      [OK] 已確認範本 $($Params.NPSTemplateName) 發布至 CA" -ForegroundColor Green
} else {
    Write-Host "      [WARNING] 找不到憑證範本 $($Params.NPSTemplateName)，請確認是否已先執行 04_create_templates.ps1。" -ForegroundColor Yellow
}

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

$GPRegParams = @{
    Name        = $Params.GPOName
    Key         = 'HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment'
    ValueName   = 'AEPolicy'
    Type        = 'DWord'
    Value       = 7
    ErrorAction = 'Stop'
}
Set-GPRegistryValue @GPRegParams | Out-Null
Write-Host "      [OK] 已寫入電腦憑證 Auto-Enrollment 原則 (AEPolicy = 7)" -ForegroundColor Green

$Inheritance = Get-GPInheritance -Target $TargetOUDN
$IsLinked    = $Inheritance.GpoLinks | Where-Object { $_.DisplayName -eq $Params.GPOName }
if ($null -eq $IsLinked) {
    New-GPLink -Name $Params.GPOName -Target $TargetOUDN -LinkEnabled Yes -ErrorAction Stop | Out-Null
    Write-Host "      [OK] 已將 GPO 連結至 $TargetOUDN" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] GPO 已連結至目標 OU" -ForegroundColor DarkGray
}

Write-Host @"

==================================================
  08 前置準備完成！
  請將獨立的 CEP/CES 伺服器 ($($Params.ServerComputerNames -join ', ')) 重新開機一次，
  再執行 09_install_cepces_server.ps1。
==================================================
"@ -ForegroundColor Cyan
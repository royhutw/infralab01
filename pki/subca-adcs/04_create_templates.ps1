# ============================================================
#  04_create_templates.ps1
#  建立 802.1x EAP-TLS 用途的憑證範本
#    EAP-TLS-Computer   電腦憑證，有效期 1 年，Domain Computers 可 Enroll/Autoenroll
#    EAP-TLS-User       使用者憑證，有效期 2 年，Domain Users 可 Enroll/Autoenroll
#    EAP-TLS-NPS-Server NPS 伺服器憑證，有效期 2 年，僅 NPS-Servers 群組可 Enroll/Autoenroll
#
#  建立方式：複製內建範本（Machine / User / WebServer）的概念，以 schema v2 建立新範本。
#  共同設定：RSA 4096、自動核准、支援 Auto-Enrollment、私鑰不可匯出。
#
#  用法：.\04_create_templates.ps1            範本已存在則略過建立（保留既有 ACL 與 OID）
#        .\04_create_templates.ps1 -Recreate  刪除既有範本後重建（OID 會改變，用戶端將重新申請憑證）
#
#  重要設計說明（歷次修正的結論，詳細過程見 git 歷史）：
#    1. Subject / SAN 旗標（msPKI-Certificate-Name-Flag，MS-CRTD）：
#         User     0x42000000 = SUBJECT_REQUIRE_COMMON_NAME(0x40000000) + SUBJECT_ALT_REQUIRE_UPN(0x02000000)
#         Computer 0x18000000 = SUBJECT_ALT_REQUIRE_DNS(0x08000000) + SUBJECT_REQUIRE_DNS_AS_CN(0x10000000)
#         NPS      0x18000000（同 Computer）
#       User 範本絕不可含 0x00000001（ENROLLEE_SUPPLIES_SUBJECT）：搭配 Client Authentication
#       EKU 與 Domain Users Enroll 會構成 ESC1（申請者自訂 Subject/SAN 冒充他人）。
#    2. flags 屬性：Computer / NPS 含 CT_FLAG_MACHINE_TYPE(0x40)，User 不可含，
#       否則 CA 會以申請者的「電腦物件」建構 Subject（症狀：User 憑證核發給電腦）。
#    3. 更新期（pKIOverlapPeriod）不得超過有效期的 75%，否則 certtmpl.msc 會報錯。
#       pKIExpirationPeriod / pKIOverlapPeriod 為小端序負值 FILETIME，不可 Reverse。
#    4. 範本容器預設繼承 SYSTEM = GenericAll，CA 本機的 Autoenrollment 會以 SYSTEM 命中而繞過
#       Enroll 限制。User 與 NPS 範本因此使用 Set-CertTemplateAcl -Harden（停用繼承，僅保留
#       明確清單）。ACL 一律以 dsacls 寫入並驗證：[ADSI]+ObjectSecurity、Get-Acl/Set-Acl、
#       DirectoryEntry.Options.SecurityMasks 實測都無法可靠地停用繼承。
#       Authenticated Users 必須保留 Read，否則 CA 讀不到範本（certutil -SetCATemplates:
#       Element not found）；真正收斂的是 Enroll，不是 Read。
#    5. 範本先設定並驗證 ACL，通過後才發布至 CA。
#
#  需求：以系統管理員身分在 Sub CA 上執行，登入帳號需能寫入 Certificate Templates 容器
#        （Enterprise Admins）。
# ============================================================
#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch] $Recreate
)

#region ── 參數區（統一從 CAConfig.psd1 讀取，請至該檔案修改參數）──
# 本腳本用到的區塊：Global（網域名稱 / NetBIOS 名稱 / 記錄目錄）、
# Templates（範本名稱、金鑰長度、NPS 群組、有效期 / 更新期 Ticks）
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
$Params = Merge-CAConfig -Sections 'Global','Templates'

# Import-PowerShellDataFile 讀入的數字預設為 [int]，Ticks 超出 Int32 範圍，故顯式轉為 [long]
foreach ($Key in 'ComputerValidityTicks','ComputerRenewalTicks','UserValidityTicks',
                 'UserRenewalTicks','NPSValidityTicks','NPSRenewalTicks') {
    $Params[$Key] = [long]$Params[$Key]
}
#endregion

$ErrorActionPreference = 'Stop'
$LogFile = Start-CATranscript -Name '04_create_templates' -Params $Params
trap {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkRed
    Write-Host "        詳細記錄：$LogFile" -ForegroundColor Red
    Stop-CATranscript
    exit 1
}

# ── 確認並安裝 RSAT-AD-PowerShell ────────────────────────────
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Host "[前置] 安裝 RSAT-AD-PowerShell..." -ForegroundColor Yellow
    Install-WindowsFeature -Name 'RSAT-AD-PowerShell' -IncludeAllSubFeature | Out-Null
}
Import-Module ActiveDirectory

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  建立 802.1x EAP-TLS 憑證範本"                      -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  記錄檔：$LogFile" -ForegroundColor Gray
Write-Host ""

# ── AD 設定 NC 與 CA Config ──────────────────────────────────
$ConfigNC       = ([ADSI]"LDAP://RootDSE").configurationNamingContext
$TemplateBaseDN = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNC"
$CAConfig       = Get-LocalCAConfigString
Write-Host "[INFO] CA Config：$CAConfig" -ForegroundColor Gray
Write-Host ""

#region ── 輔助函式 ──────────────────────────────────────────
function ConvertFrom-FileTimeTicks {
    param([long]$Ticks)
    $Days  = [Math]::Round([Math]::Abs($Ticks) / 10000000 / 86400, 2)
    $Years = [Math]::Round($Days / 365, 2)
    return "$Days 天（約 $Years 年）"
}

function Copy-CertificateTemplate {
    <# 在 AD 建立範本；成功（或已存在而略過）回傳 $true，失敗回傳 $false。 #>
    param(
        [string] $SourceTemplateName,     # 來源內建範本名稱（取得其 OID 基底）
        [string] $NewTemplateName,        # 新範本名稱（CN）
        [string] $NewDisplayName,         # 新範本顯示名稱
        [long]   $ValidityTicks,          # 有效期（負值 FILETIME Ticks，小端序）
        [long]   $RenewalTicks,           # 更新期（負值 FILETIME Ticks，小端序）
        [int]    $KeyLength,              # 最小金鑰長度
        [array]  $EKUList,                # 延伸金鑰用途 OID 清單
        [int]    $EnrollmentFlag,         # msPKI-Enrollment-Flag 基底值
        [int]    $NameFlag,               # msPKI-Certificate-Name-Flag
        [bool]   $AutoEnroll = $true,     # 是否啟用 Auto-Enrollment
        [bool]   $IsMachineType = $false  # 電腦類型範本（Computer / NPS）才為 $true
    )

    Write-Host "  處理範本：$NewDisplayName" -ForegroundColor Gray
    Write-Host "    有效期：$(ConvertFrom-FileTimeTicks $ValidityTicks)" -ForegroundColor Gray
    Write-Host "    更新期：$(ConvertFrom-FileTimeTicks $RenewalTicks)" -ForegroundColor Gray

    # ── 已存在：預設略過，保留既有 ACL 與 OID；-Recreate 才刪除重建 ──
    $ExistingDN = "CN=$NewTemplateName,$TemplateBaseDN"
    $Existing   = Get-ADObject -Filter "distinguishedName -eq '$ExistingDN'" `
                      -SearchBase $TemplateBaseDN -ErrorAction SilentlyContinue
    if ($Existing) {
        if (-not $Recreate) {
            Write-Host "    [SKIP] 範本已存在，保留既有設定（需要重建請加 -Recreate）。" -ForegroundColor DarkGray
            return $true
        }
        Write-Host "    [WARN] -Recreate：刪除既有範本後重建（OID 將改變）..." -ForegroundColor Yellow
        Remove-ADObject -Identity $ExistingDN -Confirm:$false
        Start-Sleep -Seconds 2
    }

    # ── 來源範本（取得 OID 基底）─────────────────────────────
    $SourceDN = "CN=$SourceTemplateName,$TemplateBaseDN"
    $Source   = Get-ADObject -Identity $SourceDN -Properties * -ErrorAction SilentlyContinue
    if ($null -eq $Source) {
        Write-Host "    [ERROR] 找不到來源範本：$SourceTemplateName" -ForegroundColor Red
        return $false
    }

    # BitConverter 在 Windows 產生小端序，與 AD 儲存格式一致，不可 Reverse
    $ValidityBytes = [System.BitConverter]::GetBytes($ValidityTicks)
    $RenewalBytes  = [System.BitConverter]::GetBytes($RenewalTicks)

    # 金鑰用途：Digital Signature (0x80) + Key Encipherment (0x20) = 0xA0
    $KeyUsageBytes = [byte[]](0xA0, 0x00)

    # msPKI-Enrollment-Flag：0x20 = CT_FLAG_AUTO_ENROLLMENT
    # （0x10 = AUTO_ENROLLMENT_CHECK_USER_DS_CERTIFICATE，本設計不使用）
    $FinalEnrollFlag = if ($AutoEnroll) { $EnrollmentFlag -bor 0x20 } else { $EnrollmentFlag }

    # OID：來源 OID 加隨機後綴（唯一即可，CA 以此識別範本）
    $NewOID = "$($Source.'msPKI-Cert-Template-OID').$(Get-Random -Minimum 1000000 -Maximum 9999999)"

    # flags 屬性（見檔頭說明 2）：
    #   0x20 = AUTO_ENROLLMENT、0x200 = ADD_TEMPLATE_NAME、0x20000 = IS_MODIFIED、0x40 = MACHINE_TYPE
    $FinalFlags = 0x00000020 -bor 0x00000200 -bor 0x00020000
    if ($IsMachineType) { $FinalFlags = $FinalFlags -bor 0x00000040 }

    $NewAttributes = @{
        'displayName'                          = $NewDisplayName
        'revision'                             = '100'
        'flags'                                = [int]$FinalFlags
        'msPKI-Cert-Template-OID'              = $NewOID
        'msPKI-Minimal-Key-Size'               = $KeyLength

        # 1 = AT_KEYEXCHANGE，2 = AT_SIGNATURE
        'pKIDefaultKeySpec'                    = 1
        'msPKI-Certificate-Name-Flag'          = $NameFlag
        'msPKI-Enrollment-Flag'                = $FinalEnrollFlag

        # msPKI-RA-Signature = 0：不需要 RA 簽章，自動核准
        'msPKI-RA-Signature'                   = 0

        # Schema v2（Windows Server 2003）：支援 Auto-Enrollment
        'msPKI-Template-Schema-Version'        = 2
        'msPKI-Template-Minor-Revision'        = 1
        'pKIExpirationPeriod'                  = $ValidityBytes
        'pKIOverlapPeriod'                     = $RenewalBytes
        'pKIKeyUsage'                          = $KeyUsageBytes
        'pKICriticalExtensions'                = @('2.5.29.15', '2.5.29.19')
        'pKIExtendedKeyUsage'                  = $EKUList
        'msPKI-Certificate-Application-Policy' = $EKUList
        'pKIDefaultCSPs'                       = @(
            '1,Microsoft RSA SChannel Cryptographic Provider',
            '2,Microsoft Strong Cryptographic Provider'
        )

        # 0x100 = CT_FLAG_USE_LEGACY_PROVIDER（配合上方 pKIDefaultCSPs）；
        # 未設定 0x10（CT_FLAG_EXPORTABLE_KEY），私鑰不可匯出。
        'msPKI-Private-Key-Flag'               = 0x00000100
    }

    try {
        New-ADObject -Name            $NewTemplateName `
                     -Type            'pKICertificateTemplate' `
                     -Path            $TemplateBaseDN `
                     -OtherAttributes $NewAttributes `
                     -ErrorAction     Stop
        Write-Host "    [OK] 範本建立成功：$NewDisplayName" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "    [ERROR] 範本建立失敗：$($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}
#endregion

$AllOk = $true

# ════════════════════════════════════════════════════════════
#  建立三個範本
# ════════════════════════════════════════════════════════════
Write-Host "[1/3] 建立 EAP-TLS-Computer 範本（Client Authentication，1 年）..." -ForegroundColor Yellow
if (-not (Copy-CertificateTemplate `
        -SourceTemplateName $Params.SourceComputer `
        -NewTemplateName    $Params.ComputerTemplateName `
        -NewDisplayName     $Params.ComputerTemplateDisplay `
        -ValidityTicks      $Params.ComputerValidityTicks `
        -RenewalTicks       $Params.ComputerRenewalTicks `
        -KeyLength          $Params.KeyLength `
        -EKUList            @('1.3.6.1.5.5.7.3.2') `
        -EnrollmentFlag     0x00 `
        -NameFlag           0x18000000 `
        -AutoEnroll         $true `
        -IsMachineType      $true)) { $AllOk = $false }

Write-Host ""
Write-Host "[2/3] 建立 EAP-TLS-User 範本（Client Authentication，2 年）..." -ForegroundColor Yellow
if (-not (Copy-CertificateTemplate `
        -SourceTemplateName $Params.SourceUser `
        -NewTemplateName    $Params.UserTemplateName `
        -NewDisplayName     $Params.UserTemplateDisplay `
        -ValidityTicks      $Params.UserValidityTicks `
        -RenewalTicks       $Params.UserRenewalTicks `
        -KeyLength          $Params.KeyLength `
        -EKUList            @('1.3.6.1.5.5.7.3.2') `
        -EnrollmentFlag     0x00 `
        -NameFlag           0x42000000 `
        -AutoEnroll         $true `
        -IsMachineType      $false)) { $AllOk = $false }

Write-Host ""
Write-Host "[3/3] 建立 EAP-TLS-NPS-Server 範本（Server + Client Authentication，2 年）..." -ForegroundColor Yellow
if (-not (Copy-CertificateTemplate `
        -SourceTemplateName $Params.SourceNPS `
        -NewTemplateName    $Params.NPSTemplateName `
        -NewDisplayName     $Params.NPSTemplateDisplay `
        -ValidityTicks      $Params.NPSValidityTicks `
        -RenewalTicks       $Params.NPSRenewalTicks `
        -KeyLength          $Params.KeyLength `
        -EKUList            @('1.3.6.1.5.5.7.3.1', '1.3.6.1.5.5.7.3.2') `
        -EnrollmentFlag     0x00 `
        -NameFlag           0x18000000 `
        -AutoEnroll         $true `
        -IsMachineType      $true)) { $AllOk = $false }

Write-Host ""
Write-Host "[等待] 等待 AD 複寫完成（5 秒）..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# ════════════════════════════════════════════════════════════
#  驗證範本屬性（以原始 Ticks 精確比對，不經四捨五入）
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[確認] 驗證範本屬性..." -ForegroundColor Yellow

$Expected = @(
    @{ Name = $Params.ComputerTemplateName; Validity = $Params.ComputerValidityTicks; Renewal = $Params.ComputerRenewalTicks; Type = 'Computer' },
    @{ Name = $Params.UserTemplateName;     Validity = $Params.UserValidityTicks;     Renewal = $Params.UserRenewalTicks;     Type = 'User'     },
    @{ Name = $Params.NPSTemplateName;      Validity = $Params.NPSValidityTicks;      Renewal = $Params.NPSRenewalTicks;      Type = 'NPS'      }
)

foreach ($Item in $Expected) {
    $DN  = "CN=$($Item.Name),$TemplateBaseDN"
    $Obj = Get-ADObject -Filter "distinguishedName -eq '$DN'" -SearchBase $TemplateBaseDN `
               -Properties 'pKIExpirationPeriod','pKIOverlapPeriod','msPKI-Minimal-Key-Size',
                           'msPKI-Enrollment-Flag','msPKI-Certificate-Name-Flag','flags' `
               -ErrorAction SilentlyContinue

    if (-not $Obj) {
        Write-Host "  [ERROR] 找不到範本：$($Item.Name)" -ForegroundColor Red
        $AllOk = $false
        continue
    }

    $ExpiryTicks  = [System.BitConverter]::ToInt64($Obj.'pKIExpirationPeriod', 0)
    $RenewalTicks = [System.BitConverter]::ToInt64($Obj.'pKIOverlapPeriod', 0)
    $RenewRatio   = [Math]::Round(([Math]::Abs($RenewalTicks) / [Math]::Abs($ExpiryTicks)) * 100, 2)
    $Flags        = [int]$Obj.'flags'

    Write-Host ""
    Write-Host "  [$($Item.Name)]" -ForegroundColor Cyan
    Write-Host "    有效期       ：$(ConvertFrom-FileTimeTicks $ExpiryTicks)" -ForegroundColor Gray
    Write-Host "    更新期       ：$(ConvertFrom-FileTimeTicks $RenewalTicks)（佔有效期 $RenewRatio%）" -ForegroundColor Gray
    Write-Host "    最小金鑰長度 ：$($Obj.'msPKI-Minimal-Key-Size') bits" -ForegroundColor Gray
    Write-Host "    申請旗標     ：0x$(([int]$Obj.'msPKI-Enrollment-Flag').ToString('X'))" -ForegroundColor Gray
    Write-Host "    主體名稱旗標 ：0x$(([int]$Obj.'msPKI-Certificate-Name-Flag').ToString('X'))" -ForegroundColor Gray
    Write-Host "    flags        ：$Flags（0x$($Flags.ToString('X'))）" -ForegroundColor Gray

    if ($ExpiryTicks -ne $Item.Validity -or $RenewalTicks -ne $Item.Renewal) {
        Write-Host "    [ERROR] 有效期 / 更新期與 CAConfig.psd1 不符（範本可能是舊版建立；可加 -Recreate 重建）。" -ForegroundColor Red
        $AllOk = $false
    }
    if ($RenewRatio -gt 75.01) {
        Write-Host "    [ERROR] 更新期超過有效期的 75% 上限，certtmpl.msc 編輯時會被強制修正。" -ForegroundColor Red
        $AllOk = $false
    }
    if ($Obj.'msPKI-Minimal-Key-Size' -ne $Params.KeyLength) {
        Write-Host "    [ERROR] 最小金鑰長度與 CAConfig.psd1 的 KeyLength（$($Params.KeyLength)）不符。" -ForegroundColor Red
        $AllOk = $false
    }

    if ($Item.Type -eq 'User') {
        if ([int]$Obj.'msPKI-Certificate-Name-Flag' -band 0x00000001) {
            Write-Host "    [ERROR] 偵測到 ENROLLEE_SUPPLIES_SUBJECT！這是 ESC1 風險，請立即檢查。" -ForegroundColor Red
            $AllOk = $false
        } else {
            Write-Host "    [OK] 無 ENROLLEE_SUPPLIES_SUBJECT，Subject 由 CA 依 AD 資訊建構。" -ForegroundColor Green
        }
        if ($Flags -band 0x00000040) {
            Write-Host "    [ERROR] User 範本含 MACHINE_TYPE，會導致 User 憑證核發給電腦身分。" -ForegroundColor Red
            $AllOk = $false
        } else {
            Write-Host "    [OK] 無 MACHINE_TYPE，為正確的使用者類型範本。" -ForegroundColor Green
        }
    } else {
        if ($Flags -band 0x00000040) {
            Write-Host "    [OK] 已包含 MACHINE_TYPE。" -ForegroundColor Green
        } else {
            Write-Host "    [ERROR] 電腦類型範本缺少 MACHINE_TYPE。" -ForegroundColor Red
            $AllOk = $false
        }
    }
}

# ════════════════════════════════════════════════════════════
#  NPS 伺服器專屬安全群組（最小權限）
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[群組] 建立 NPS 伺服器專屬安全群組..." -ForegroundColor Yellow

$ExistingGroup = Get-ADGroup -Filter "Name -eq '$($Params.NPSServersGroupName)'" -ErrorAction SilentlyContinue
if ($null -eq $ExistingGroup) {
    New-ADGroup -Name $Params.NPSServersGroupName `
                -SamAccountName $Params.NPSServersGroupName `
                -GroupCategory Security `
                -GroupScope Global `
                -Description 'NPS RADIUS 伺服器電腦帳號 - 僅此群組可申請 EAP-TLS-NPS-Server 憑證'
    Write-Host "      [OK] 群組已建立：$($Params.NPSServersGroupName)" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] 群組已存在：$($Params.NPSServersGroupName)" -ForegroundColor DarkGray
}

foreach ($ComputerName in $Params.NPSServerComputerNames) {
    try {
        $ComputerObj = Get-ADComputer -Identity $ComputerName -ErrorAction Stop
        $IsMember = Get-ADGroupMember -Identity $Params.NPSServersGroupName -ErrorAction SilentlyContinue |
                        Where-Object { $_.SamAccountName -eq $ComputerObj.SamAccountName }
        if ($null -eq $IsMember) {
            Add-ADGroupMember -Identity $Params.NPSServersGroupName -Members $ComputerObj -ErrorAction Stop
            Write-Host "      [OK] 已加入群組：$ComputerName" -ForegroundColor Green
        } else {
            Write-Host "      [SKIP] 已是群組成員：$ComputerName" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "      [WARN] 找不到電腦帳號或加入失敗：$ComputerName - $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "      [提醒] 請確認 CAConfig.psd1 Templates.NPSServerComputerNames 與實際 AD 電腦帳號名稱相符" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "[等待] 等待 AD 群組成員複寫完成（5 秒）..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# ════════════════════════════════════════════════════════════
#  設定範本 ACL（通過驗證後才發布至 CA）
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[ACL] 設定範本存取權限（dsacls，寫入後驗證）..." -ForegroundColor Yellow

$NetBIOS = $Params.NetBIOSDomainName
$AdminGroups = @('Domain Admins', 'Enterprise Admins')

# Computer：本來就開放給所有網域電腦，維持繼承，只新增 Domain Computers 的 Enroll/Autoenroll
# User / NPS：停用繼承，僅保留明確清單
$AclPlan = @(
    @{ Name = $Params.ComputerTemplateName; Splat = @{ EnrollPrincipals = @('Domain Computers') };
       Desc = 'Domain Computers → Read + Enroll + Auto-Enroll（維持繼承）' },
    @{ Name = $Params.UserTemplateName;     Splat = @{ EnrollPrincipals = @('Domain Users'); FullControlPrincipals = $AdminGroups; Harden = $true };
       Desc = 'Domain Users → Read + Enroll + Auto-Enroll（已停用繼承）' },
    @{ Name = $Params.NPSTemplateName;      Splat = @{ EnrollPrincipals = @($Params.NPSServersGroupName); FullControlPrincipals = $AdminGroups; Harden = $true };
       Desc = "$($Params.NPSServersGroupName) → Read + Enroll + Auto-Enroll（已停用繼承）" }
)

$ReadyToPublish = @()
foreach ($Plan in $AclPlan) {
    $Splat = $Plan.Splat
    $Ok = Set-CertTemplateAcl -TemplateDN "CN=$($Plan.Name),$TemplateBaseDN" -NetBIOSDomain $NetBIOS @Splat
    if ($Ok) {
        Write-Host "      [OK] $($Plan.Name)：$($Plan.Desc)" -ForegroundColor Green
        $ReadyToPublish += $Plan.Name
    } else {
        Write-Host "      [ERROR] $($Plan.Name) 的 ACL 設定或驗證失敗，不發布此範本，請手動檢查！" -ForegroundColor Red
        $AllOk = $false
    }
}

# ════════════════════════════════════════════════════════════
#  發布範本至 CA
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[發布] 將範本加入 CA 發布清單..." -ForegroundColor Yellow
foreach ($Name in $ReadyToPublish) {
    try {
        Invoke-CertutilChecked -Arguments @('-config', $CAConfig, '-setcatemplates', "+$Name") `
            -SuccessMessage "已發布：$Name" -FailureMessage "發布失敗：$Name" -Indent '      '
    }
    catch {
        $AllOk = $false
    }
}

Write-Host ""
Write-Host "[最終確認] CA 目前已發布的範本清單：" -ForegroundColor Yellow
certutil -config $CAConfig -catemplates

if (-not $AllOk) {
    Write-Host ""
    Write-Host "[ERROR] 部分範本建立、驗證、ACL 或發布失敗，請檢查上方訊息。記錄檔：$LogFile" -ForegroundColor Red
    Stop-CATranscript
    exit 1
}

Write-Host @"

==================================================
  憑證範本建立完成！
    - $($Params.ComputerTemplateName)：1 年，更新期 75%，Domain Computers，維持繼承
    - $($Params.UserTemplateName)：2 年，更新期 75%，Domain Users，已停用繼承
      （Subject/SAN 一律由 CA 依申請者 AD 物件建構）
    - $($Params.NPSTemplateName)：2 年，更新期 75%，僅 $($Params.NPSServersGroupName) 群組，已停用繼承

  【建議驗證】
    1. 在 CA 本機執行 gpupdate /force + certutil -pulse，
       確認 CA「不會」取得 EAP-TLS-User / EAP-TLS-NPS-Server（EAP-TLS-Computer 應正常取得）
    2. 在 NPS / RADIUS 伺服器執行 gpupdate /force + certutil -pulse，
       確認取得 EAP-TLS-NPS-Server，且 Subject/SAN 為該主機 FQDN
    3. 若先前版本曾核發過異常憑證（User 憑證核發給電腦、非 NPS 主機取得 NPS 憑證），
       請至 CA「Issued Certificates」檢視並撤銷

  若 certtmpl.msc / certsrv.msc 看不到範本，請在 MMC 中 Refresh。
  Renewal Period 在 MMC 可能因單位換算顯示為取整後的天數，屬正常現象。

  下一步：執行 05_configure_autoenrollment_gpo.ps1 設定 GPO
==================================================
"@ -ForegroundColor Green

Stop-CATranscript

# ============================================================
#  PowerShell DSC - 建立第一座 AD Forest
#  使用本機 Self-Signed Certificate 加密 Administrator Credential
#  密碼透過 Get-Credential 於執行時互動輸入，不儲存於腳本中
#  需求模組：ActiveDirectoryDsc, xPSDesiredStateConfiguration
# ============================================================

#region ── 前置作業說明 ──────────────────────────────────────
# 執行前請確認以下事項：
#   1. 已安裝 DSC 模組：
#        Install-Module -Name ActiveDirectoryDsc -Force
#        Install-Module -Name xPSDesiredStateConfiguration -Force
#
#   2. 本機已有 Self-Signed Certificate 可供加密 Credential
#      若尚未建立，可用下列指令產生（請在目標伺服器執行）：
#
#        $cert = New-SelfSignedCertificate `
#                    -Subject 'CN=DSC_Credential_Encryption' `
#                    -CertStoreLocation 'Cert:\LocalMachine\My' `
#                    -KeyUsage KeyEncipherment, DataEncipherment `
#                    -Type DocumentEncryptionCert `
#                    -HashAlgorithm SHA256
#
#        # 匯出公鑰憑證（.cer）供 DSC 編譯時加密
#        Export-Certificate -Cert $cert `
#            -FilePath 'C:\DSC\DSC_Credential_Encryption.cer'
#
#        # 記下憑證指紋（Thumbprint），填入下方參數
#        $cert.Thumbprint
#endregion

#region ── 參數區（請依實際環境修改） ────────────────────────
$ADForestParams = @{
    # ── 網域設定 ───────────────────────────────────────────
    DomainName          = 'corp.contoso.com'   # FQDN 網域名稱
    DomainNetbiosName   = 'CORP'               # NetBIOS 名稱（15字元以內）
    DomainMode          = 'WinThreshold'       # 網域功能等級（WinThreshold = Windows Server 2016+）
    ForestMode          = 'WinThreshold'       # 樹系功能等級

    # ── Self-Signed Certificate 資訊 ────────────────────────
    # 請填入您本機憑證的指紋（Thumbprint）
    CertificateThumbprint = 'YOUR_CERTIFICATE_THUMBPRINT_HERE'  # ← 請修改

    # 匯出的公鑰憑證路徑（.cer 檔），供 DSC 編譯時使用
    CertificatePath     = 'C:\DSC\DSC_Credential_Encryption.cer'

    # ── 資料庫與記錄檔路徑（可保留預設值） ────────────────
    DatabasePath        = 'C:\Windows\NTDS'
    LogPath             = 'C:\Windows\NTDS'
    SysvolPath          = 'C:\Windows\SYSVOL'
}
# 注意：AdminPassword 與 SafeModeAdminPassword 已移除，
#       改為執行時透過 Get-Credential 互動輸入，不儲存於腳本中。
#endregion

#region ── LCM 設定（啟用 Credential 加密）──────────────────
[DSCLocalConfigurationManager()]
Configuration LCM_CertConfig {
    Node 'localhost' {
        Settings {
            RebootNodeIfNeeded             = $true
            ActionAfterReboot              = 'ContinueConfiguration'
            ConfigurationMode              = 'ApplyAndAutoCorrect'
            ConfigurationModeFrequencyMins = 15

            # 指定用來解密 Credential 的憑證指紋
            CertificateID                  = $ADForestParams.CertificateThumbprint
        }
    }
}
#endregion

#region ── DSC 主設定：建立 AD Forest ───────────────────────
Configuration NewADForest {

    param (
        [Parameter(Mandatory)]
        [string] $NodeName,

        [Parameter(Mandatory)]
        [PSCredential] $DomainAdminCredential,

        [Parameter(Mandatory)]
        [PSCredential] $SafeModeCredential
    )

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'ActiveDirectoryDsc'

    Node $NodeName {

        # ── 1. 確保 AD-Domain-Services 角色已安裝 ─────────
        WindowsFeature ADDSInstall {
            Name   = 'AD-Domain-Services'
            Ensure = 'Present'
        }

        # ── 2. 確保 DNS 服務已安裝（AD 需要） ─────────────
        WindowsFeature DNSInstall {
            Name      = 'DNS'
            Ensure    = 'Present'
            DependsOn = '[WindowsFeature]ADDSInstall'
        }

        # ── 3. 安裝 RSAT AD 管理工具（選用，方便管理） ────
        WindowsFeature RSATADTools {
            Name      = 'RSAT-AD-Tools'
            Ensure    = 'Present'
            DependsOn = '[WindowsFeature]ADDSInstall'
        }

        # ── 4. 建立第一座 AD Forest ────────────────────────
        ADDomain CreateForest {
            DomainName                    = $ADForestParams.DomainName
            DomainNetBiosName             = $ADForestParams.DomainNetbiosName
            DomainMode                    = $ADForestParams.DomainMode
            ForestMode                    = $ADForestParams.ForestMode
            DatabasePath                  = $ADForestParams.DatabasePath
            LogPath                       = $ADForestParams.LogPath
            SysvolPath                    = $ADForestParams.SysvolPath
            Credential                    = $DomainAdminCredential   # 以 Certificate 加密儲存
            SafemodeAdministratorPassword = $SafeModeCredential      # 以 Certificate 加密儲存
            DependsOn                     = @(
                '[WindowsFeature]ADDSInstall',
                '[WindowsFeature]DNSInstall',
                '[WindowsFeature]RSATADTools'
            )
        }

        # ── 5. 等待 AD 服務就緒後確認網域控制站狀態 ───────
        ADDomainController VerifyDC {
            DomainName                    = $ADForestParams.DomainName
            Credential                    = $DomainAdminCredential
            SafemodeAdministratorPassword = $SafeModeCredential
            DependsOn                     = '[ADDomain]CreateForest'
        }
    }
}
#endregion

#region ── 互動式 Credential 輸入 ────────────────────────────

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  AD Forest 建置 - 密碼輸入"                        -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan

# ── Credential 1：Domain Administrator ───────────────────────
# UserName 預填 'Administrator'，使用者可直接輸入密碼
Write-Host ""
Write-Host "[密碼輸入 1/2] Domain Administrator 帳號密碼" -ForegroundColor Yellow
Write-Host "  此密碼將用於建立 AD Forest 及 Domain Administrator 帳號" -ForegroundColor Gray
Write-Host ""
$DomainAdminCred = Get-Credential `
    -UserName 'Administrator' `
    -Message  '請輸入 Domain Administrator 密碼（建立 AD Forest 使用）'

# 確認使用者未取消輸入
if ($null -eq $DomainAdminCred) {
    Write-Host "[ERROR] 未輸入 Domain Administrator Credential，作業中止。" -ForegroundColor Red
    exit 1
}

# ── Credential 2：DSRM 安全模式密碼 ──────────────────────────
# DSRM 帳號固定為本機 Administrator，UserName 僅為說明用途
Write-Host ""
Write-Host "[密碼輸入 2/2] DSRM 目錄服務還原模式密碼" -ForegroundColor Yellow
Write-Host "  此密碼用於 AD 進入安全模式（Directory Services Restore Mode）時登入" -ForegroundColor Gray
Write-Host "  建議與 Domain Administrator 密碼不同，並妥善離線保存" -ForegroundColor Gray
Write-Host ""
$SafeModeCred = Get-Credential `
    -UserName 'DSRM\Administrator' `
    -Message  '請輸入 DSRM 安全模式密碼（Directory Services Restore Mode）'

# 確認使用者未取消輸入
if ($null -eq $SafeModeCred) {
    Write-Host "[ERROR] 未輸入 DSRM Credential，作業中止。" -ForegroundColor Red
    exit 1
}

# ── 密碼強度基本檢查 ─────────────────────────────────────────
function Test-PasswordComplexity {
    param([SecureString]$SecurePassword, [string]$Label)

    $BSTR     = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $Plain    = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

    $Errors = @()
    if ($Plain.Length -lt 8)                          { $Errors += "長度至少需要 8 個字元" }
    if ($Plain -notmatch '[A-Z]')                     { $Errors += "需包含大寫字母" }
    if ($Plain -notmatch '[a-z]')                     { $Errors += "需包含小寫字母" }
    if ($Plain -notmatch '[0-9]')                     { $Errors += "需包含數字" }
    if ($Plain -notmatch '[^A-Za-z0-9]')              { $Errors += "需包含特殊符號" }

    if ($Errors.Count -gt 0) {
        Write-Host "[WARN] ${Label} 密碼強度不足：" -ForegroundColor Yellow
        $Errors | ForEach-Object { Write-Host "       - $_" -ForegroundColor Yellow }
        $Continue = Read-Host "       是否仍要繼續？(Y/N)"
        if ($Continue -ne 'Y') {
            Write-Host "[INFO] 作業中止，請重新執行腳本並設定更強的密碼。" -ForegroundColor Gray
            exit 1
        }
    } else {
        Write-Host "[OK] ${Label} 密碼強度檢查通過。" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "[檢查] 驗證密碼強度..." -ForegroundColor Yellow
Test-PasswordComplexity -SecurePassword $DomainAdminCred.Password -Label 'Domain Administrator'
Test-PasswordComplexity -SecurePassword $SafeModeCred.Password    -Label 'DSRM'

#endregion

#region ── 編譯並套用設定 ────────────────────────────────────

# Step 1：設定 ConfigurationData（指定公鑰憑證，讓 DSC 編譯時加密 Credential）
$ConfigData = @{
    AllNodes = @(
        @{
            NodeName                    = 'localhost'
            PSDscAllowPlainTextPassword = $false    # 強制加密，不允許明文
            PSDscAllowDomainUser        = $false
            CertificateFile             = $ADForestParams.CertificatePath        # 公鑰 .cer 路徑
            Thumbprint                  = $ADForestParams.CertificateThumbprint  # 憑證指紋
        }
    )
}

# 執行前顯示設定摘要（不顯示任何密碼）
Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  即將套用的 AD Forest 設定摘要"                    -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  網域名稱（FQDN）  : $($ADForestParams.DomainName)"
Write-Host "  NetBIOS 名稱      : $($ADForestParams.DomainNetbiosName)"
Write-Host "  網域功能等級      : $($ADForestParams.DomainMode)"
Write-Host "  樹系功能等級      : $($ADForestParams.ForestMode)"
Write-Host "  資料庫路徑        : $($ADForestParams.DatabasePath)"
Write-Host "  SYSVOL 路徑       : $($ADForestParams.SysvolPath)"
Write-Host "  Administrator     : $($DomainAdminCred.UserName)"
Write-Host "  DSRM 帳號         : $($SafeModeCred.UserName)"
Write-Host "  加密憑證指紋      : $($ADForestParams.CertificateThumbprint)"
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

$Confirm = Read-Host "確認以上設定無誤，開始部署？(Y/N)"
if ($Confirm -ne 'Y') {
    Write-Host "[INFO] 作業取消。" -ForegroundColor Gray
    exit 0
}

# Step 2：編譯 LCM 設定
Write-Host ""
Write-Host "[1/4] 編譯 LCM 設定..." -ForegroundColor Yellow
LCM_CertConfig -OutputPath '.\ADForest_MOF\LCM' | Out-Null

# Step 3：套用 LCM 設定（讓 LCM 知道使用哪張憑證解密）
Write-Host "[2/4] 套用 LCM 設定..." -ForegroundColor Yellow
Set-DscLocalConfigurationManager -Path '.\ADForest_MOF\LCM' -Verbose

# Step 4：編譯主設定 MOF（Credential 將以公鑰憑證加密後寫入 MOF）
Write-Host "[3/4] 編譯 AD Forest 設定（Credential 加密中）..." -ForegroundColor Yellow
NewADForest `
    -NodeName              'localhost' `
    -DomainAdminCredential $DomainAdminCred `
    -SafeModeCredential    $SafeModeCred `
    -ConfigurationData     $ConfigData `
    -OutputPath            '.\ADForest_MOF\Config'

# Step 5：套用設定（伺服器將自動重啟並完成 AD 安裝）
Write-Host "[4/4] 套用設定，伺服器將重新啟動以完成 AD Forest 建立..." -ForegroundColor Green
Start-DscConfiguration -Path '.\ADForest_MOF\Config' -Wait -Verbose -Force

Write-Host @"

==================================================
  AD Forest 設定已觸發，請注意：
  - 伺服器將自動重啟（可能重啟 1~2 次）
  - 重啟後 DSC 會自動繼續完成剩餘設定
  - 完成後可執行下列指令驗證：

    Test-DscConfiguration -Detailed
    Get-ADDomain
    Get-ADForest

==================================================
"@ -ForegroundColor Cyan

#endregion
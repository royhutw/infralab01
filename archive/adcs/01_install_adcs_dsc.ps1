# ============================================================
#  PowerShell DSC - 安裝與設定 AD CS Enterprise Subordinate CA
#  網域     ：corp.foo.bar.tw
#  CA 類型  ：Enterprise Subordinate CA（加入網域，整合 AD）
#  用途     ：802.1x EAP-TLS 電腦與使用者憑證簽發
#  離線 Root CA 架構：Root CA（離線）→ 本台 Enterprise Sub CA（上線）
#
#  需求模組：
#    Install-Module -Name ActiveDirectoryDsc      -Force
#    Install-Module -Name ActiveDirectoryCSDsc    -Force
#    Install-Module -Name NetworkingDsc           -Force
# ============================================================

#region ── 參數區（請依實際環境修改） ────────────────────────
$ADCSParams = @{
    # ── CA 基本設定 ─────────────────────────────────────────
    CACommonName        = 'corp-foo-bar-tw-SubCA'      # CA 顯示名稱（建議含組織辨識）
    CADistinguishedNameSuffix = 'DC=corp,DC=foo,DC=bar,DC=tw'  # AD DN 後綴
    DomainName          = 'corp.foo.bar.tw'            # 網域 FQDN

    # ── 金鑰設定 ────────────────────────────────────────────
    KeyLength           = 4096                         # RSA 金鑰長度
    HashAlgorithm       = 'SHA256'                     # 雜湊演算法

    # ── Subordinate CA 有效期（需小於 Root CA 剩餘效期） ───
    # 此值最終取決於 Root CA 簽發時指定的天數，DSC 僅安裝角色
    # 實際有效期在提交 CSR 給 Root CA 時由 Root CA 決定

    # ── CRL 與 CDP 設定 ──────────────────────────────────────
    # CRL 發布至此 Web 伺服器路徑（需另建 IIS 提供靜態下載）
    CRLPublishPath      = 'C:\CRLPublish'              # 本機 CRL 輸出目錄
    CDPUrl              = 'http://pki.corp.foo.bar.tw/CRL'  # 對外 CRL HTTP URL
    AIAUrl              = 'http://pki.corp.foo.bar.tw/AIA'  # 對外 AIA HTTP URL

    # ── CRL 更新週期 ─────────────────────────────────────────
    CRLPeriodUnits      = 1                            # CRL 有效期數值
    CRLPeriod           = 'Weeks'                      # CRL 有效期單位（Days/Weeks/Months）
    CRLDeltaPeriodUnits = 1                            # Delta CRL 有效期數值
    CRLDeltaPeriod      = 'Days'                       # Delta CRL 有效期單位

    # ── DSC Credential 加密憑證 ──────────────────────────────
    CertificateThumbprint = 'YOUR_CERTIFICATE_THUMBPRINT_HERE'  # ← 請修改
    CertificatePath       = 'C:\DSC\DSC_Credential_Encryption.cer'

    # ── CSR 暫存路徑（提交給離線 Root CA 用） ───────────────
    CSROutputPath       = 'C:\CAConfig\SubCA.req'      # CSR 輸出路徑
    SignedCertPath      = 'C:\CAConfig\SubCA.crt'      # Root CA 簽回的憑證路徑
    RootCACertPath      = 'C:\CAConfig\RootCA.crt'     # Root CA 憑證路徑（需事先複製）
    RootCACRLPath       = 'C:\CAConfig\RootCA.crl'     # Root CA CRL（需事先複製）
}
#endregion

#region ── LCM 設定 ──────────────────────────────────────────
[DSCLocalConfigurationManager()]
Configuration LCM_ADCSConfig {
    Node 'localhost' {
        Settings {
            RebootNodeIfNeeded             = $true
            ActionAfterReboot              = 'ContinueConfiguration'
            ConfigurationMode              = 'ApplyAndAutoCorrect'
            ConfigurationModeFrequencyMins = 15
            CertificateID                  = $ADCSParams.CertificateThumbprint
        }
    }
}
#endregion

#region ── DSC 主設定：安裝 AD CS Enterprise Subordinate CA ──
Configuration Install_EnterpriseSubCA {

    param (
        [Parameter(Mandatory)]
        [string] $NodeName,

        [Parameter(Mandatory)]
        [PSCredential] $DomainAdminCredential
    )

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'ActiveDirectoryCSDsc'

    Node $NodeName {

        # ────────────────────────────────────────────────────
        # 1. 安裝 AD CS 角色
        #    安裝 Certification Authority 與 Web Enrollment 角色
        #    Web Enrollment 提供瀏覽器手動申請介面（選用但常見）
        # ────────────────────────────────────────────────────
        WindowsFeature ADCS_CertAuthority {
            Name   = 'ADCS-Cert-Authority'
            Ensure = 'Present'
        }

        WindowsFeature ADCS_WebEnrollment {
            Name      = 'ADCS-Web-Enrollment'
            Ensure    = 'Present'
            DependsOn = '[WindowsFeature]ADCS_CertAuthority'
        }

        WindowsFeature ADCS_RSAT {
            # RSAT 管理工具，方便在本機管理 CA
            Name      = 'RSAT-ADCS'
            Ensure    = 'Present'
            DependsOn = '[WindowsFeature]ADCS_CertAuthority'
        }

        # ────────────────────────────────────────────────────
        # 2. 設定 Enterprise Subordinate CA
        #
        #    CAType = EnterpriseSubordinateCA：
        #      加入網域的下層 CA，可整合 AD 自動發布 Template
        #      與 Auto-Enrollment，適合 802.1x EAP-TLS 使用。
        #
        #    初次安裝時 DSC 會：
        #      a. 產生 CA 金鑰對（RSA 4096）
        #      b. 產生 CSR 檔案至 CSROutputPath
        #      c. 等待管理員將 CSR 提交至離線 Root CA 簽發
        #      d. 憑證簽回後執行 03_install_subcacert.ps1 完成安裝
        # ────────────────────────────────────────────────────
        AdcsCertificationAuthority EnterpriseSubCA {
            Ensure                = 'Present'
            CAType                = 'EnterpriseSubordinateCA'
            CACommonName          = $ADCSParams.CACommonName
            CADistinguishedNameSuffix = $ADCSParams.CADistinguishedNameSuffix
            KeyLength             = $ADCSParams.KeyLength
            HashAlgorithmName     = $ADCSParams.HashAlgorithm
            CryptoProviderName    = 'RSA#Microsoft Software Key Storage Provider'
            OutputCertRequestFile = $ADCSParams.CSROutputPath  # CSR 輸出，供提交 Root CA
            OverwriteExistingCAinDS        = $false
            OverwriteExistingDatabase      = $false
            OverwriteExistingKey           = $false
            Credential            = $DomainAdminCredential
            DependsOn             = '[WindowsFeature]ADCS_CertAuthority'
        }

        # ────────────────────────────────────────────────────
        # 3. 設定 Web Enrollment
        #    提供 https://CA伺服器/certsrv 的手動申請介面
        #    需在 CA 設定完成（憑證安裝後）才可啟用
        # ────────────────────────────────────────────────────
        AdcsWebEnrollment WebEnrollment {
            Ensure     = 'Present'
            Credential = $DomainAdminCredential
            DependsOn  = '[AdcsCertificationAuthority]EnterpriseSubCA'
        }
    }
}
#endregion

#region ── 互動式 Credential 輸入 ────────────────────────────
Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  AD CS Enterprise Subordinate CA 安裝"             -ForegroundColor Cyan
Write-Host "  網域：$($ADCSParams.DomainName)"                  -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""
Write-Host "[密碼輸入] Domain Admin Credential" -ForegroundColor Yellow
Write-Host "  需要 Domain Admins 與 Enterprise Admins 群組成員資格" -ForegroundColor Gray
Write-Host ""

$DomainAdminCred = Get-Credential `
    -UserName "$($ADCSParams.DomainName)\Administrator" `
    -Message  '請輸入 Domain Administrator 帳號密碼（需具備 Enterprise Admins 權限）'

if ($null -eq $DomainAdminCred) {
    Write-Host "[ERROR] 未輸入 Credential，作業中止。" -ForegroundColor Red
    exit 1
}
#endregion

#region ── 前置確認：Root CA 憑證與 CRL 是否已複製 ────────────
Write-Host ""
Write-Host "[前置確認] 檢查必要檔案..." -ForegroundColor Yellow

$PreChecks = @(
    @{ Path = $ADCSParams.RootCACertPath; Label = 'Root CA 憑證 (.crt)' },
    @{ Path = $ADCSParams.RootCACRLPath;  Label = 'Root CA CRL (.crl)'  },
    @{ Path = $ADCSParams.CertificatePath; Label = 'DSC 加密憑證 (.cer)' }
)

$PreCheckFailed = $false
foreach ($Check in $PreChecks) {
    if (Test-Path $Check.Path) {
        Write-Host "  [OK] $($Check.Label)：$($Check.Path)" -ForegroundColor Green
    } else {
        Write-Host "  [缺少] $($Check.Label)：$($Check.Path)" -ForegroundColor Red
        $PreCheckFailed = $true
    }
}

if ($PreCheckFailed) {
    Write-Host ""
    Write-Host "[ERROR] 請先將上述缺少的檔案複製到指定路徑後再執行。" -ForegroundColor Red
    Write-Host "        Root CA 憑證與 CRL 需從離線 Root CA VM 複製至此伺服器。" -ForegroundColor Red
    exit 1
}

# 將 Root CA 憑證發布至 AD 與本機信任存放區
Write-Host ""
Write-Host "[前置] 匯入 Root CA 憑證至本機信任存放區..." -ForegroundColor Yellow
certutil -addstore "Root" $ADCSParams.RootCACertPath | Out-Null
certutil -addstore "Root" $ADCSParams.RootCACRLPath  | Out-Null
Write-Host "  [OK] Root CA 憑證已匯入。" -ForegroundColor Green

# 將 Root CA 憑證發布至 AD NTAuthCertificates（Enterprise CA 必要）
Write-Host "[前置] 發布 Root CA 憑證至 AD（NTAuthCertificates）..." -ForegroundColor Yellow
certutil -dspublish -f $ADCSParams.RootCACertPath RootCA | Out-Null
Write-Host "  [OK] 發布完成。" -ForegroundColor Green
#endregion

#region ── 建立必要目錄 ──────────────────────────────────────
New-Item -Path $ADCSParams.CRLPublishPath -ItemType Directory -Force | Out-Null
New-Item -Path (Split-Path $ADCSParams.CSROutputPath) -ItemType Directory -Force | Out-Null
#endregion

#region ── 設定 ConfigurationData ────────────────────────────
$ConfigData = @{
    AllNodes = @(
        @{
            NodeName                    = 'localhost'
            PSDscAllowPlainTextPassword = $false
            PSDscAllowDomainUser        = $true      # Enterprise Sub CA 需要網域帳號
            CertificateFile             = $ADCSParams.CertificatePath
            Thumbprint                  = $ADCSParams.CertificateThumbprint
        }
    )
}
#endregion

#region ── 編譯並套用 DSC ────────────────────────────────────
Write-Host ""
Write-Host "[1/4] 編譯 LCM 設定..." -ForegroundColor Yellow
LCM_ADCSConfig -OutputPath '.\ADCS_MOF\LCM' | Out-Null
Set-DscLocalConfigurationManager -Path '.\ADCS_MOF\LCM' -Verbose

Write-Host "[2/4] 編譯 AD CS 安裝設定..." -ForegroundColor Yellow
Install_EnterpriseSubCA `
    -NodeName             'localhost' `
    -DomainAdminCredential $DomainAdminCred `
    -ConfigurationData    $ConfigData `
    -OutputPath           '.\ADCS_MOF\Config' | Out-Null

Write-Host "[3/4] 套用 AD CS 安裝設定..." -ForegroundColor Yellow
Start-DscConfiguration -Path '.\ADCS_MOF\Config' -Wait -Verbose -Force

Write-Host "[4/4] 完成初步安裝。" -ForegroundColor Green
#endregion

#region ── 後續步驟提示 ──────────────────────────────────────
Write-Host @"

==================================================
  AD CS 角色安裝完成，後續步驟：

  [Step 1] 將 CSR 檔案複製到離線 Root CA VM：
           $($ADCSParams.CSROutputPath)

  [Step 2] 在 Root CA VM 執行 02_sign_intermediate.bat
           簽發 Subordinate CA 憑證

  [Step 3] 將簽回的憑證複製到：
           $($ADCSParams.SignedCertPath)

  [Step 4] 執行 02_install_subcacert.ps1 完成 CA 憑證安裝

  [Step 5] 執行 03_configure_cdp_aia.ps1 設定 CDP/AIA

  [Step 6] 執行 04_create_templates.ps1 建立 EAP-TLS Template

  [Step 7] 執行 05_configure_autoenrollment_gpo.ps1 設定 GPO Auto-Enrollment
==================================================
"@ -ForegroundColor Cyan
#endregion

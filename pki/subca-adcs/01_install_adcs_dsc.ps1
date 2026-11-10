# ============================================================
#  PowerShell DSC - 安裝與設定 AD CS Enterprise Subordinate CA
#  網域     ：corp.foo.bar.tw
#  CA 類型  ：Enterprise Subordinate CA（加入網域，整合 AD）
#  用途     ：802.1x EAP-TLS 電腦與使用者憑證簽發
#  離線 Root CA 架構：Root CA（離線）→ 本台 Enterprise Sub CA（上線）
#
#  需求模組：
#    Install-Module -Name ActiveDirectoryCSDsc    -Force
#
#  需求權限：
#    - 以系統管理員身分執行，且「目前登入帳號」須為 Enterprise Admins
#      （certutil -dspublish 無法指定其他帳號，一律使用目前登入身分）
#    - 另需輸入一組 Enterprise Admins 憑證供 DSC 資源安裝 CA 使用
#
#  本機需有可加密 DSC Credential 的自簽憑證（尚未建立時）：
#
#        $cert = New-SelfSignedCertificate `
#                    -Subject 'CN=DSC_Credential_Encryption' `
#                    -CertStoreLocation 'Cert:\LocalMachine\My' `
#                    -KeyUsage KeyEncipherment, DataEncipherment `
#                    -Type DocumentEncryptionCert `
#                    -HashAlgorithm SHA256
#        Export-Certificate -Cert $cert -FilePath 'C:\DSC\DSC_Credential_Encryption.cer'
#        $cert.Thumbprint     # 填入 CAConfig.psd1 的 DSCCredential.CertificateThumbprint
#
#  修正記錄：
#    - 【Web Enrollment】移出本腳本。原版與 CA 設定放在同一輪 DSC，但此時
#      CA 尚無憑證，AdcsWebEnrollment 必然失敗；且 /certsrv 會增加 ESC8
#      （NTLM relay）攻擊面，規劃使用獨立 CEP/CES 時更無必要。
#      若確實需要，請在 02 完成後另行安裝，並限定 HTTPS + EPA、停用 NTLM。
#    - 【DSC 不再常駐】LCM 改為 ApplyOnly、不自動重開機；安裝完成後
#      移除 DSC 組態文件（含加密後的 Domain Admin 認證）並刪除 MOF。
#      原版 ApplyAndAutoCorrect 每 15 分鐘重套一次，且 MOF 殘留在 Tier 0 主機。
#      若需保留，加上參數 -KeepDscConfiguration。
#    - 【DN 順序】改為標準「最具體在前」：OU, O, L, ST, C, DC…
#      （原版 OU 插在 O 後面、L/ST 排在 C 後面，與註解範例也不一致）；
#      DN 值中的特殊字元（, + " \ < > ; =）自動跳脫。
#    - 【Root DN 自動比對】直接讀取 RootCA.crt 的 Subject，與 psd1 的
#      C/O/ST 比對，不符就在產生 CSR 前中止（避免 Root CA 端被
#      policy_strict 拒簽才發現）。
#    - 【前置檢查前移】網域、模組、DSC 憑證、檔案、Enterprise Admins
#      全部在輸入密碼之前檢查；Credential 驗證通過才繼續。
#    - 【Credential】預設帳號改用 NetBIOS 格式（原版用 FQDN\Administrator）。
#    - 所有 certutil 呼叫檢查結束代碼；NTAuth 註解更正
#      （RootCA 是發布至 Certification Authorities 容器，非 NTAuth）。
#    - MOF 改輸出至暫存目錄並於結束時清除；加入 Transcript 記錄。
# ============================================================
#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    # 預設安裝完成後移除 DSC 組態；加上此參數則保留（不建議於 Tier 0 主機）
    [switch] $KeepDscConfiguration
)

#region ── 參數區（統一從 CAConfig.psd1 讀取，請至該檔案修改參數）──
# 本腳本用到的區塊：Global（網域/CA名稱/CRL發布路徑）、
# RootCADN（CSR DN欄位，需與Root CA一致）、ADCSInstall（金鑰設定）、
# CRLPolicy（僅供對照，實際CRL週期由03腳本套用）、
# DSCCredential（DSC Credential 加密憑證）、
# ExchangePaths（CSR/憑證交換路徑）
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
$Params = Merge-CAConfig -Sections 'Global','RootCADN','ADCSInstall','CRLPolicy','DSCCredential','ExchangePaths'
#endregion

$ErrorActionPreference = 'Stop'
$script:Failed = $false

# ── 記錄檔 ───────────────────────────────────────────────────
$LogDir = Join-Path $Params.CAConfigDir 'Logs'
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
$LogFile = Join-Path $LogDir ('01_install_adcs_dsc_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
Start-Transcript -Path $LogFile | Out-Null

# ── 暫存 MOF 目錄（結束時一律清除）───────────────────────────
$MofRoot = Join-Path $env:TEMP ('ADCS_MOF_{0}' -f ([guid]::NewGuid().ToString('N')))

#region ── 輔助函式 ──────────────────────────────────────────
# Invoke-CertutilChecked / ConvertTo-DnValue / New-CADnSuffix 已移至共用的 Import-CAConfig.ps1

function Get-DnAttribute {
    <# 從 DN 字串取出指定屬性值（支援引號與反斜線跳脫），找不到回傳空字串 #>
    param([string] $Dn, [string[]] $Keys)
    foreach ($Key in $Keys) {
        $Pattern = '(?:^|,\s*)' + [regex]::Escape($Key) + '=(?<v>"(?:[^"]|"")*"|(?:\\.|[^,])*)'
        $Match   = [regex]::Match($Dn, $Pattern)
        if ($Match.Success) {
            $Value = $Match.Groups['v'].Value
            if ($Value.StartsWith('"')) { $Value = $Value.Substring(1, $Value.Length - 2) -replace '""', '"' }
            else                        { $Value = $Value -replace '\\(.)', '$1' }
            return $Value.Trim()
        }
    }
    return ''
}
#endregion

#region ── DSC 組態定義（置於 try 之外，避免 Configuration 關鍵字出現在區塊內）──
# LCM：ApplyOnly + 不自動重開機。AD CS 安裝是一次性作業（中間還有人工簽發 CSR），
# 不需要 DSC 持續檢查與自動修正；常駐只會增加 Tier 0 主機的風險與不可預期的重套。
[DSCLocalConfigurationManager()]
Configuration LCM_ADCSConfig {
    param([Parameter(Mandatory)][string] $Thumbprint)
    Node 'localhost' {
        Settings {
            RebootNodeIfNeeded = $false
            ActionAfterReboot  = 'ContinueConfiguration'
            ConfigurationMode  = 'ApplyOnly'
            CertificateID      = $Thumbprint
        }
    }
}

Configuration Install_EnterpriseSubCA {
    param (
        [Parameter(Mandatory)][string]       $NodeName,
        [Parameter(Mandatory)][PSCredential] $DomainAdminCredential,
        [Parameter(Mandatory)][string]       $CACommonName,
        [Parameter(Mandatory)][string]       $DNSuffix,
        [Parameter(Mandatory)][int]          $KeyLength,
        [Parameter(Mandatory)][string]       $HashAlgorithm,
        [Parameter(Mandatory)][string]       $CSROutputPath
    )

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'ActiveDirectoryCSDsc'

    Node $NodeName {

        # 1. AD CS 角色與管理工具
        #    （Web Enrollment 已移出：CA 尚無憑證時無法設定，且建議改用獨立 CEP/CES）
        WindowsFeature ADCS_CertAuthority {
            Name   = 'ADCS-Cert-Authority'
            Ensure = 'Present'
        }

        WindowsFeature ADCS_RSAT {
            Name      = 'RSAT-ADCS'
            Ensure    = 'Present'
            DependsOn = '[WindowsFeature]ADCS_CertAuthority'
        }

        # 2. Enterprise Subordinate CA
        #    初次安裝時 DSC 會：
        #      a. 產生 CA 金鑰對（RSA）
        #      b. 產生 CSR 檔案至 OutputCertRequestFile
        #      c. 等待管理員將 CSR 提交至離線 Root CA 簽發
        #      d. 憑證簽回後執行 02_install_subcacert.ps1 完成安裝
        AdcsCertificationAuthority EnterpriseSubCA {
            Ensure                    = 'Present'
            IsSingleInstance          = 'Yes'
            CAType                    = 'EnterpriseSubordinateCA'
            CACommonName              = $CACommonName
            CADistinguishedNameSuffix = $DNSuffix
            KeyLength                 = $KeyLength
            HashAlgorithmName         = $HashAlgorithm
            CryptoProviderName        = 'RSA#Microsoft Software Key Storage Provider'
            OutputCertRequestFile     = $CSROutputPath
            OverwriteExistingCAinDS   = $false
            OverwriteExistingDatabase = $false
            OverwriteExistingKey      = $false
            Credential                = $DomainAdminCredential
            DependsOn                 = '[WindowsFeature]ADCS_CertAuthority'
        }
    }
}
#endregion

try {
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  AD CS Enterprise Subordinate CA 安裝"             -ForegroundColor Cyan
    Write-Host "  網域：$($Params.DomainName)"                      -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  記錄檔：$LogFile" -ForegroundColor Gray

    # ════════════════════════════════════════════════════════
    #  階段 A：前置檢查（全部通過才會要求輸入密碼）
    # ════════════════════════════════════════════════════════
    Write-Host ""
    Write-Host "[前置] 環境檢查..." -ForegroundColor Yellow

    # A1. 已是網域成員，且網域與設定一致
    $CS = Get-CimInstance Win32_ComputerSystem
    if (-not $CS.PartOfDomain) { throw "此電腦尚未加入網域；Enterprise Sub CA 必須先加入 $($Params.DomainName)。" }
    if ($CS.Domain -ne $Params.DomainName) {
        throw "本機所屬網域（$($CS.Domain)）與 CAConfig.psd1 的 DomainName（$($Params.DomainName)）不一致。"
    }
    Write-Host "  [OK] 已加入網域：$($CS.Domain)" -ForegroundColor Green

    # A2. 目前登入者必須是 Enterprise Admins（SID 結尾 -519）
    #     certutil -dspublish 只能用目前登入身分執行，無法套用下方輸入的 Credential。
    $IsEA = [Security.Principal.WindowsIdentity]::GetCurrent().Groups | Where-Object { $_.Value -match '-519$' }
    if (-not $IsEA) {
        throw "目前登入帳號不是 Enterprise Admins 成員（或未以提升權限的視窗執行）。certutil -dspublish 需要此權限，請改用 EA 帳號登入後重跑。"
    }
    Write-Host "  [OK] 目前登入帳號具 Enterprise Admins 權限" -ForegroundColor Green

    # A3. 若 CA 已設定，直接結束（避免重複安裝）
    $CertSvcCfg = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
    $ExistingCA = (Get-ItemProperty -Path $CertSvcCfg -ErrorAction SilentlyContinue).Active
    if (-not [string]::IsNullOrWhiteSpace($ExistingCA)) {
        Write-Host "  [SKIP] 本機已設定 CA：$ExistingCA" -ForegroundColor Yellow
        Write-Host "         若 CSR 已簽回，請直接執行 02_install_subcacert.ps1；若要重建 CA 請先手動移除 AD CS 角色。" -ForegroundColor Yellow
        return
    }

    # A4. DSC 資源模組
    if (-not (Get-Module -ListAvailable -Name 'ActiveDirectoryCSDsc')) {
        throw "找不到 ActiveDirectoryCSDsc 模組。請先執行：Install-Module -Name ActiveDirectoryCSDsc -Force"
    }
    Write-Host "  [OK] ActiveDirectoryCSDsc 模組已安裝" -ForegroundColor Green

    # A5. DSC 加密憑證：存在於本機、有私鑰、未過期
    $DscCert = Get-Item -Path "Cert:\LocalMachine\My\$($Params.CertificateThumbprint)" -ErrorAction SilentlyContinue
    if ($null -eq $DscCert)           { throw "LocalMachine\My 找不到指紋為 $($Params.CertificateThumbprint) 的 DSC 加密憑證。" }
    if (-not $DscCert.HasPrivateKey)  { throw "DSC 加密憑證沒有私鑰，無法解密 Credential。" }
    if ($DscCert.NotAfter -lt (Get-Date)) { throw "DSC 加密憑證已過期（$($DscCert.NotAfter)）。" }
    $DscEku = @($DscCert.EnhancedKeyUsageList.ObjectId)
    if ($DscEku.Count -gt 0 -and $DscEku -notcontains '1.3.6.1.4.1.311.80.1') {
        Write-Host "  [WARN] DSC 加密憑證缺少 Document Encryption EKU（1.3.6.1.4.1.311.80.1），DSC 可能拒絕使用。" -ForegroundColor Yellow
    }
    Write-Host "  [OK] DSC 加密憑證有效（到期：$($DscCert.NotAfter.ToString('yyyy-MM-dd'))）" -ForegroundColor Green

    # A6. 必要檔案
    $PreChecks = @(
        @{ Path = $Params.RootCACertPath;  Label = 'Root CA 憑證 (.crt)'  },
        @{ Path = $Params.RootCACRLPath;   Label = 'Root CA CRL (.crl)'   },
        @{ Path = $Params.CertificatePath; Label = 'DSC 加密憑證 (.cer)'  }
    )
    $Missing = $false
    foreach ($Check in $PreChecks) {
        if (Test-Path -LiteralPath $Check.Path) {
            Write-Host "  [OK] $($Check.Label)：$($Check.Path)" -ForegroundColor Green
        } else {
            Write-Host "  [缺少] $($Check.Label)：$($Check.Path)" -ForegroundColor Red
            $Missing = $true
        }
    }
    if ($Missing) { throw "請先將缺少的檔案複製到指定路徑（Root CA 憑證與 CRL 需從離線 Root CA VM 複製過來）。" }

    # A7. Root CA 憑證有效，且 DN 欄位與 psd1 一致
    $RootCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Params.RootCACertPath)
    if ($RootCert.NotAfter -lt (Get-Date)) { throw "Root CA 憑證已過期（$($RootCert.NotAfter)）。" }
    $RootDn = $RootCert.Subject
    Write-Host "  [INFO] Root CA Subject：$RootDn" -ForegroundColor Gray

    # (欄位, psd1 值, 比對的 DN 鍵名, 不符時是否中止)
    # .NET 將 stateOrProvinceName 顯示為 "S"，故 ST 同時比對 ST / S。
    $DnChecks = @(
        @{ Label = 'C  (國碼)';  Config = $Params.CACountry;      Keys = @('C');        Strict = $true  },
        @{ Label = 'O  (組織)';  Config = $Params.CAOrganization; Keys = @('O');        Strict = $true  },
        @{ Label = 'ST (州/省)'; Config = $Params.CAState;        Keys = @('ST','S');   Strict = $true  },
        @{ Label = 'L  (地區)';  Config = $Params.CALocality;     Keys = @('L');        Strict = $false },
        @{ Label = 'OU (單位)';  Config = $Params.CAOU;           Keys = @('OU');       Strict = $false }
    )
    foreach ($Item in $DnChecks) {
        $RootValue   = Get-DnAttribute -Dn $RootDn -Keys $Item.Keys
        $ConfigValue = [string]$Item.Config
        if ($RootValue -cne $ConfigValue) {
            $Msg = "DN 欄位 $($Item.Label) 不一致：Root CA='$RootValue'，CAConfig.psd1='$ConfigValue'"
            if ($Item.Strict) {
                throw "$Msg。Root CA 的 policy_strict 會拒簽此 CSR（比對區分大小寫）。請修正 CAConfig.psd1 的 RootCADN 區塊。"
            }
            Write-Host "  [WARN] $Msg（此欄位通常為選填，請確認 Root CA 的 policy 設定）" -ForegroundColor Yellow
        }
    }
    Write-Host "  [OK] DN 欄位與 Root CA 憑證相符（C / O / ST）" -ForegroundColor Green

    # ════════════════════════════════════════════════════════
    #  階段 B：組合 CADistinguishedNameSuffix
    # ════════════════════════════════════════════════════════
    # 標準順序（最具體在前）：OU, O, L, ST, C，最後接 DC 鏈。
    #   必填：O、C；選填：OU、L、ST（有值才加入）
    # 範例：OU=IT, O=MyOrg Ltd, L=Taipei, ST=Taiwan, C=TW, DC=corp, DC=foo, DC=bar, DC=tw
    $DNSuffix = New-CADnSuffix -Params $Params

    Write-Host ""
    Write-Host "[DN] CADistinguishedNameSuffix：" -ForegroundColor Gray
    Write-Host "     $DNSuffix" -ForegroundColor Gray
    Write-Host "[DN] CSR 完整 DN 將為：" -ForegroundColor Gray
    Write-Host "     CN=$($Params.CACommonName), $DNSuffix" -ForegroundColor Gray

    # ════════════════════════════════════════════════════════
    #  階段 C：輸入並驗證 Credential
    # ════════════════════════════════════════════════════════
    Write-Host ""
    Write-Host "[密碼輸入] Domain Admin Credential" -ForegroundColor Yellow
    Write-Host "  需要 Enterprise Admins 群組成員資格（DSC 資源以此身分安裝 CA）" -ForegroundColor Gray
    Write-Host ""

    $DomainAdminCred = Get-Credential `
        -UserName "$($Params.NetBIOSDomainName)\Administrator" `
        -Message  '請輸入具 Enterprise Admins 權限的網域帳號（格式：NETBIOS\帳號）'
    if ($null -eq $DomainAdminCred) { throw "未輸入 Credential，作業中止。" }

    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $Net = $DomainAdminCred.GetNetworkCredential()
    $Ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
               [System.DirectoryServices.AccountManagement.ContextType]::Domain, $Params.DomainName)
    try {
        if (-not $Ctx.ValidateCredentials($Net.UserName, $Net.Password)) {
            throw "Credential 驗證失敗，請確認帳號密碼（格式：$($Params.NetBIOSDomainName)\帳號）。"
        }
    } finally { $Ctx.Dispose(); $Net = $null }
    Write-Host "  [OK] Credential 驗證通過" -ForegroundColor Green

    # ════════════════════════════════════════════════════════
    #  階段 D：Root CA 憑證 / CRL 匯入與發布
    # ════════════════════════════════════════════════════════
    Write-Host ""
    Write-Host "[前置] 匯入 Root CA 憑證與 CRL 至本機信任存放區..." -ForegroundColor Yellow
    Invoke-CertutilChecked -Arguments @('-addstore','-f','Root',$Params.RootCACertPath) `
        -SuccessMessage 'Root CA 憑證已匯入' -FailureMessage 'Root CA 憑證匯入失敗'
    Invoke-CertutilChecked -Arguments @('-addstore','-f','Root',$Params.RootCACRLPath) `
        -SuccessMessage 'Root CA CRL 已匯入' -FailureMessage 'Root CA CRL 匯入失敗（請確認檔案有效且未過期）'

    # RootCA：發布至 AD 的 Certification Authorities 容器，讓網域成員信任 Root。
    # （Sub CA 憑證加入 NTAuthCertificates 是 02 的工作，Enterprise CA 安裝時也會自動處理。）
    Write-Host "[前置] 發布 Root CA 憑證至 AD（Certification Authorities 容器）..." -ForegroundColor Yellow
    Invoke-CertutilChecked -Arguments @('-dspublish','-f',$Params.RootCACertPath,'RootCA') `
        -SuccessMessage 'Root CA 憑證已發布至 AD' -FailureMessage 'Root CA 憑證發布至 AD 失敗'

    # ── 建立必要目錄 ─────────────────────────────────────────
    New-Item -Path $Params.CRLPublishPath -ItemType Directory -Force | Out-Null
    New-Item -Path (Split-Path $Params.CSROutputPath) -ItemType Directory -Force | Out-Null

    # ════════════════════════════════════════════════════════
    #  階段 E：DSC 組態資料（組態定義位於 try 區塊之前）
    # ════════════════════════════════════════════════════════
    $ConfigData = @{
        AllNodes = @(
            @{
                NodeName                    = 'localhost'
                PSDscAllowPlainTextPassword = $false
                PSDscAllowDomainUser        = $true
                CertificateFile             = $Params.CertificatePath
                Thumbprint                  = $Params.CertificateThumbprint
            }
        )
    }

    # ════════════════════════════════════════════════════════
    #  階段 F：編譯並套用 DSC
    # ════════════════════════════════════════════════════════
    New-Item -Path $MofRoot -ItemType Directory -Force | Out-Null

    Write-Host ""
    Write-Host "[1/4] 編譯並套用 LCM 設定（ApplyOnly）..." -ForegroundColor Yellow
    LCM_ADCSConfig -Thumbprint $Params.CertificateThumbprint -OutputPath (Join-Path $MofRoot 'LCM') | Out-Null
    Set-DscLocalConfigurationManager -Path (Join-Path $MofRoot 'LCM') -Verbose

    Write-Host "[2/4] 編譯 AD CS 安裝設定..." -ForegroundColor Yellow
    Install_EnterpriseSubCA `
        -NodeName              'localhost' `
        -DomainAdminCredential $DomainAdminCred `
        -CACommonName          $Params.CACommonName `
        -DNSuffix              $DNSuffix `
        -KeyLength             $Params.KeyLength `
        -HashAlgorithm         $Params.HashAlgorithm `
        -CSROutputPath         $Params.CSROutputPath `
        -ConfigurationData     $ConfigData `
        -OutputPath            (Join-Path $MofRoot 'Config') | Out-Null

    Write-Host "[3/4] 套用 AD CS 安裝設定..." -ForegroundColor Yellow
    $DscError = $null
    try {
        Start-DscConfiguration -Path (Join-Path $MofRoot 'Config') -Wait -Verbose -Force
    } catch {
        $DscError = $_.Exception.Message
    }

    # 以「實際結果」判斷成敗，而非只看有沒有例外：
    # Sub CA 在憑證尚未簽回的狀態下，安裝流程可能回報「待處理」類訊息，
    # 只要 CSR 已產生且 CA 組態已寫入即屬預期結果。
    $CsrOk = (Test-Path -LiteralPath $Params.CSROutputPath) -and ((Get-Item -LiteralPath $Params.CSROutputPath).Length -gt 0)
    $CaCfg = (Get-ItemProperty -Path $CertSvcCfg -ErrorAction SilentlyContinue).Active

    if ($DscError -and -not ($CsrOk -and $CaCfg)) {
        throw "DSC 套用失敗，且未產生 CSR / CA 組態：$DscError"
    }
    if ($DscError) {
        Write-Host "  [WARN] DSC 回報訊息：$DscError" -ForegroundColor Yellow
        Write-Host "         但 CSR 已產生、CA 組態已寫入，視為預期的『待簽憑證』狀態。" -ForegroundColor Yellow
    }
    if (-not $CsrOk) { throw "未找到 CSR 檔案：$($Params.CSROutputPath)" }
    Write-Host "  [OK] CSR 已產生：$($Params.CSROutputPath)" -ForegroundColor Green

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        Write-Host "  [WARN] 系統標示需要重新開機。請於重開機後再執行 02（本腳本不會自動重開機）。" -ForegroundColor Yellow
    }

    # ════════════════════════════════════════════════════════
    #  階段 G：清除 DSC 殘留（預設）
    # ════════════════════════════════════════════════════════
    Write-Host ""
    Write-Host "[4/4] 清除 DSC 殘留..." -ForegroundColor Yellow
    if ($KeepDscConfiguration) {
        Write-Host "  [SKIP] 已指定 -KeepDscConfiguration，保留 DSC 組態文件。" -ForegroundColor Yellow
    } else {
        foreach ($Stage in 'Current','Pending','Previous') {
            try { Remove-DscConfigurationDocument -Stage $Stage -Force -ErrorAction Stop }
            catch { Write-Host "  [INFO] 無 $Stage 階段文件可移除（或已移除）。" -ForegroundColor DarkGray }
        }
        Write-Host "  [OK] 已移除 DSC 組態文件（含加密後的 Credential）；LCM 維持 ApplyOnly。" -ForegroundColor Green
    }

    Write-Host @"

==================================================
  AD CS 角色安裝完成（CA 目前處於「待簽憑證」狀態），後續步驟：

  [Step 1] 將 CSR 檔案複製到離線 Root CA VM：
           $($Params.CSROutputPath)
           CSR DN：CN=$($Params.CACommonName), $DNSuffix

  [Step 2] 在 Root CA VM 簽發 Subordinate CA 憑證
           （簽發時的 extension 須含 CA=TRUE，且 CDP/AIA 指向正式 HTTP 位置）

  [Step 3] 將簽回的憑證複製到：
           $($Params.SignedCertPath)

  [Step 4] 執行 02_install_subcacert.ps1 完成 CA 憑證安裝
  [Step 5] 執行 03_configure_cdp_aia.ps1 設定 CDP/AIA（務必在簽發任何憑證前完成）
  [Step 6] 執行 04_create_templates.ps1 建立 EAP-TLS Template
  [Step 7] 執行 05_configure_autoenrollment_gpo.ps1 設定 GPO Auto-Enrollment

  備註：Web Enrollment（/certsrv）未安裝。若確實需要，請於 02 完成後另行
        安裝，並限定 HTTPS + Extended Protection、停用 NTLM（ESC8 防護）。
==================================================
"@ -ForegroundColor Cyan
}
catch {
    $script:Failed = $true
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        詳細記錄：$LogFile" -ForegroundColor Red
}
finally {
    # MOF 內含以憑證加密的 Credential，無論成敗都清除
    if (Test-Path -LiteralPath $MofRoot) { Remove-Item -LiteralPath $MofRoot -Recurse -Force -ErrorAction SilentlyContinue }
    Stop-Transcript | Out-Null
}
if ($script:Failed) { exit 1 }
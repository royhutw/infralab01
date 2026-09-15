# ============================================================
#  06_renew_subcacert.ps1
#  Subordinate CA 憑證 Renewal 腳本
#  每次 Renewal 產生全新 Private Key 與 CSR
#
#  執行時機：
#    - Subordinate CA 憑證即將到期前
#    - 需要更換 CDP/AIA URL 時
#    - 主動汰換金鑰時（安全考量）
#
#  執行流程：
#    1. 停止 CA 服務
#    2. 備份現有憑證與設定
#    3. 清除舊的憑證與金鑰
#    4. 重新安裝 CA 角色設定（產生新 Private Key 與 CSR）
#    5. 提示將 CSR 帶到 Root CA 簽發
# ============================================================

#region ── 參數區（請依實際環境修改） ────────────────────────
$RenewalParams = @{
    # ── CA 識別名稱 ──────────────────────────────────────────
    CACommonName          = 'corp-foo-bar-tw-SubCA'
    CADistinguishedNameSuffix = $null    # 由下方自動組合，勿填寫

    # ── DN 欄位（需與 Root CA openssl-rootca.cnf 完全一致）──
    CACountry             = 'TW'
    CAOrganization        = 'MyOrg Ltd'
    #CAState               = ''           # 選填，留空則不加入 DN
    #CALocality            = ''           # 選填，留空則不加入 DN
    #CAOU                  = ''           # 選填，留空則不加入 DN

    # ── 網域設定 ─────────────────────────────────────────────
    DomainName            = 'corp.foo.bar.tw'

    # ── 金鑰設定 ─────────────────────────────────────────────
    KeyLength             = 4096
    HashAlgorithm         = 'SHA256'

    # ── CSR 輸出路徑 ─────────────────────────────────────────
    CSROutputPath         = 'C:\CAConfig\SubCA_renewal.req'

    # ── 備份目錄 ─────────────────────────────────────────────
    BackupPath            = 'C:\CAConfig\Backup'

    # ── DSC Credential 加密憑證 ──────────────────────────────
    CertificateThumbprint = 'YOUR_CERTIFICATE_THUMBPRINT_HERE'  # ← 請修改
    CertificatePath       = 'C:\DSC\DSC_Credential_Encryption.cer'
}
#endregion

# ── 取得時間戳記（用於備份檔名）─────────────────────────────
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  Subordinate CA 憑證 Renewal"                      -ForegroundColor Cyan
Write-Host "  時間：$Timestamp"                                  -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""
Write-Host "[方式] 產生全新 Private Key 與 CSR" -ForegroundColor Yellow
Write-Host ""

#region ── 互動式 Credential 輸入 ────────────────────────────
Write-Host "[密碼輸入] Domain Admin Credential" -ForegroundColor Yellow
Write-Host "  需要 Domain Admins 與 Enterprise Admins 群組成員資格" -ForegroundColor Gray
Write-Host ""

$DomainAdminCred = Get-Credential `
    -UserName "$($RenewalParams.DomainName)\Administrator" `
    -Message  '請輸入 Domain Administrator 帳號密碼（需具備 Enterprise Admins 權限）'

if ($null -eq $DomainAdminCred) {
    Write-Host "[ERROR] 未輸入 Credential，作業中止。" -ForegroundColor Red
    exit 1
}
#endregion

#region ── 自動組合 CADistinguishedNameSuffix ────────────────
$DNParts = [System.Collections.Generic.List[string]]::new()

# 必填欄位
$DNParts.Add("O=$($RenewalParams.CAOrganization)")
$DNParts.Add("C=$($RenewalParams.CACountry)")

# 選填欄位（有值才加入）
if (-not [string]::IsNullOrWhiteSpace($RenewalParams.CAOU)) {
    $DNParts.Insert(1, "OU=$($RenewalParams.CAOU)")
}
if (-not [string]::IsNullOrWhiteSpace($RenewalParams.CALocality)) {
    $DNParts.Add("L=$($RenewalParams.CALocality)")
}
if (-not [string]::IsNullOrWhiteSpace($RenewalParams.CAState)) {
    $DNParts.Add("ST=$($RenewalParams.CAState)")
}

# 從 DomainName 自動拆解 DC= 鏈
$DCParts = $RenewalParams.DomainName.Split('.') | ForEach-Object { "DC=$_" }
$DNParts.AddRange([string[]]$DCParts)
$RenewalParams.CADistinguishedNameSuffix = $DNParts -join ', '

Write-Host "[DN] CSR 完整 DN 將為：" -ForegroundColor Gray
Write-Host "     CN=$($RenewalParams.CACommonName), $($RenewalParams.CADistinguishedNameSuffix)" -ForegroundColor Gray
Write-Host ""
#endregion

#region ── 執行確認 ──────────────────────────────────────────
Write-Host "=================================================="  -ForegroundColor Yellow
Write-Host "  [警告] 此操作將執行以下動作："                    -ForegroundColor Yellow
Write-Host "    1. 停止 CertSvc 服務"                           -ForegroundColor Yellow
Write-Host "    2. 備份現有憑證至 $($RenewalParams.BackupPath)" -ForegroundColor Yellow
Write-Host "    3. 移除現有 CA 憑證與金鑰（無法復原）"          -ForegroundColor Yellow
Write-Host "    4. 產生全新 Private Key 與 CSR"                 -ForegroundColor Yellow
Write-Host "    5. CA 服務將停止，直到新憑證安裝完成"           -ForegroundColor Yellow
Write-Host "=================================================="  -ForegroundColor Yellow
Write-Host ""
$Confirm = Read-Host "確認繼續？(YES/N)"
if ($Confirm -ne 'YES') {
    Write-Host "[INFO] 作業取消。" -ForegroundColor Gray
    exit 0
}
#endregion

#region ── Step 1：停止 CA 服務 ──────────────────────────────
Write-Host ""
Write-Host "[1/7] 停止 CA 服務..." -ForegroundColor Yellow
$SvcStatus = (Get-Service CertSvc -ErrorAction SilentlyContinue).Status
if ($SvcStatus -eq 'Running') {
    Stop-Service CertSvc -Force
    Write-Host "      [OK] CertSvc 已停止。" -ForegroundColor Green
} else {
    Write-Host "      [INFO] CertSvc 已是停止狀態。" -ForegroundColor Gray
}
#endregion

#region ── Step 2：備份現有憑證 ──────────────────────────────
Write-Host ""
Write-Host "[2/7] 備份現有憑證與金鑰資訊..." -ForegroundColor Yellow

$BackupDir = "$($RenewalParams.BackupPath)\$Timestamp"
New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null

# 備份現有憑證（若存在）
$ExistingCerts = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -match $RenewalParams.CACommonName }

if ($ExistingCerts) {
    foreach ($Cert in $ExistingCerts) {
        $CertFile = "$BackupDir\SubCA_$($Cert.Thumbprint).cer"
        Export-Certificate -Cert $Cert -FilePath $CertFile | Out-Null
        Write-Host "      [OK] 備份憑證：$CertFile" -ForegroundColor Green
        Write-Host "           Thumbprint：$($Cert.Thumbprint)" -ForegroundColor Gray
        Write-Host "           到期日    ：$($Cert.NotAfter)" -ForegroundColor Gray
    }
} else {
    Write-Host "      [INFO] 找不到現有 SubCA 憑證（可能已清除）。" -ForegroundColor Gray
}

# 備份 CertSrv 設定資訊
certutil -getreg CA\ > "$BackupDir\CA_Registry_Backup.txt" 2>$null
Write-Host "      [OK] CA 登錄設定已備份至：$BackupDir\CA_Registry_Backup.txt" -ForegroundColor Green
#endregion

#region ── Step 3：清除舊憑證與金鑰 ─────────────────────────
Write-Host ""
Write-Host "[3/7] 清除舊的憑證與金鑰..." -ForegroundColor Yellow

# 移除 Personal 憑證存放區中的舊 SubCA 憑證（含封存）
$ThumbprintsToRemove = @()

# 用 certutil 列出含封存的憑證
$CertutilOutput = certutil -store My 2>$null
$CurrentThumbprint = $null
$IsSubCA = $false

foreach ($Line in $CertutilOutput) {
    if ($Line -match 'Cert Hash\(sha1\):\s+(.+)') {
        $CurrentThumbprint = $Matches[1].Trim()
    }
    if ($Line -match "Subject:.*$($RenewalParams.CACommonName)") {
        $IsSubCA = $true
    }
    if ($IsSubCA -and $CurrentThumbprint) {
        $ThumbprintsToRemove += $CurrentThumbprint
        $CurrentThumbprint = $null
        $IsSubCA = $false
    }
}

foreach ($Tp in ($ThumbprintsToRemove | Select-Object -Unique)) {
    Write-Host "      移除憑證：$Tp" -ForegroundColor Gray
    certutil -delstore My $Tp 2>$null | Out-Null
}

# 移除金鑰容器
Write-Host "      移除金鑰容器：$($RenewalParams.CACommonName)" -ForegroundColor Gray
certutil -delkey -csp "Microsoft Software Key Storage Provider" `
    $RenewalParams.CACommonName 2>$null | Out-Null

# 清除 CertEnroll 目錄
Remove-Item 'C:\Windows\System32\CertSrv\CertEnroll\*' `
    -Force -Recurse -ErrorAction SilentlyContinue

# 移除 AD DS 殘留物件
Write-Host "      清除 AD DS 殘留物件..." -ForegroundColor Gray
$ConfigDN = ($RenewalParams.DomainName.Split('.') | ForEach-Object { "DC=$_" }) -join ','
$CAName   = $RenewalParams.CACommonName

@(
    "CN=$CAName,CN=Enrollment Services,CN=Public Key Services,CN=Services,CN=Configuration,$ConfigDN",
    "CN=$CAName,CN=AIA,CN=Public Key Services,CN=Services,CN=Configuration,$ConfigDN",
    "CN=$CAName,CN=CDP,CN=Public Key Services,CN=Services,CN=Configuration,$ConfigDN"
) | ForEach-Object {
    certutil -dspublish -delstore $_ 2>$null | Out-Null
}

# Uninstall CA 設定
Write-Host "      移除 CA 設定..." -ForegroundColor Gray
Uninstall-AdcsCertificationAuthority -Force -ErrorAction SilentlyContinue | Out-Null

Write-Host "      [OK] 清除完成。" -ForegroundColor Green
#endregion

#region ── Step 4：確認清除結果 ──────────────────────────────
Write-Host ""
Write-Host "[4/7] 確認清除結果..." -ForegroundColor Yellow

$StoreCheck = certutil -store My 2>$null | Select-String $RenewalParams.CACommonName
if ($StoreCheck) {
    Write-Host "      [WARN] 憑證存放區仍有殘留，請手動確認。" -ForegroundColor Yellow
} else {
    Write-Host "      [OK] 憑證存放區乾淨。" -ForegroundColor Green
}

$KeyCheck = certutil -csp "Microsoft Software Key Storage Provider" -key 2>$null |
    Select-String $RenewalParams.CACommonName
if ($KeyCheck) {
    Write-Host "      [WARN] 金鑰容器仍有殘留，請手動確認。" -ForegroundColor Yellow
} else {
    Write-Host "      [OK] 金鑰容器乾淨。" -ForegroundColor Green
}
#endregion

#region ── Step 5：產生新的 Private Key 與 CSR ───────────────
Write-Host ""
Write-Host "[5/7] 產生新的 Private Key 與 CSR..." -ForegroundColor Yellow

# 設定 ConfigurationData（DSC Credential 加密用）
$ConfigData = @{
    AllNodes = @(
        @{
            NodeName                    = 'localhost'
            PSDscAllowPlainTextPassword = $false
            PSDscAllowDomainUser        = $true
            CertificateFile             = $RenewalParams.CertificatePath
            Thumbprint                  = $RenewalParams.CertificateThumbprint
        }
    )
}

# 定義 DSC 設定（僅 CA 安裝，不含其他角色）
Configuration RenewSubCA {
    param (
        [Parameter(Mandatory)]
        [string] $NodeName,
        [Parameter(Mandatory)]
        [PSCredential] $DomainAdminCredential
    )

    Import-DscResource -ModuleName 'PSDesiredStateConfiguration'
    Import-DscResource -ModuleName 'ActiveDirectoryCSDsc'

    Node $NodeName {
        # 角色已安裝，此處確保 Present 狀態即可
        WindowsFeature ADCS_CertAuthority {
            Name   = 'ADCS-Cert-Authority'
            Ensure = 'Present'
        }

        # 重新產生新的 Private Key 與 CSR
        AdcsCertificationAuthority RenewSubCA {
            Ensure                    = 'Present'
            IsSingleInstance          = 'Yes'
            CAType                    = 'EnterpriseSubordinateCA'
            CACommonName              = $RenewalParams.CACommonName
            CADistinguishedNameSuffix = $RenewalParams.CADistinguishedNameSuffix
            KeyLength                 = $RenewalParams.KeyLength
            HashAlgorithmName         = $RenewalParams.HashAlgorithm
            CryptoProviderName        = 'RSA#Microsoft Software Key Storage Provider'
            OutputCertRequestFile     = $RenewalParams.CSROutputPath
            OverwriteExistingCAinDS   = $true   # Renewal 時允許覆寫 AD DS 物件
            OverwriteExistingDatabase = $true   # Renewal 時允許覆寫資料庫
            OverwriteExistingKey      = $true   # Renewal 時產生全新金鑰對
            Credential                = $DomainAdminCredential
            DependsOn                 = '[WindowsFeature]ADCS_CertAuthority'
        }
    }
}

# ── LCM 設定：告知 LCM 使用哪張憑證解密 Credential ─────────
# 必須在套用主設定前先套用 LCM，否則 LCM 找不到解密憑證會報錯：
# "The certificate cannot be found in the local machine certificate store."
[DSCLocalConfigurationManager()]
Configuration LCM_RenewConfig {
    Node 'localhost' {
        Settings {
            RebootNodeIfNeeded             = $true
            ActionAfterReboot              = 'ContinueConfiguration'
            ConfigurationMode              = 'ApplyAndAutoCorrect'
            ConfigurationModeFrequencyMins = 15
            CertificateID                  = $RenewalParams.CertificateThumbprint
        }
    }
}

Write-Host "      編譯並套用 LCM 設定（憑證解密）..." -ForegroundColor Gray
New-Item -Path '.\RenewSubCA_MOF\LCM'    -ItemType Directory -Force | Out-Null
New-Item -Path '.\RenewSubCA_MOF\Config' -ItemType Directory -Force | Out-Null

LCM_RenewConfig -OutputPath '.\RenewSubCA_MOF\LCM' | Out-Null
Set-DscLocalConfigurationManager -Path '.\RenewSubCA_MOF\LCM' -Verbose

# ── 編譯主設定 MOF ───────────────────────────────────────────
Write-Host "      編譯 DSC 主設定..." -ForegroundColor Gray
RenewSubCA `
    -NodeName              'localhost' `
    -DomainAdminCredential $DomainAdminCred `
    -ConfigurationData     $ConfigData `
    -OutputPath            '.\RenewSubCA_MOF\Config' | Out-Null

# ── 套用 DSC ─────────────────────────────────────────────────
Write-Host "      套用 DSC（產生新 Private Key 與 CSR）..." -ForegroundColor Gray
Start-DscConfiguration -Path '.\RenewSubCA_MOF\Config' -Wait -Force `
    -ErrorAction Stop
#endregion

#region ── Step 6：確認 CSR 產生成功 ─────────────────────────
Write-Host ""
Write-Host "[6/7] 確認 CSR 產生結果..." -ForegroundColor Yellow

# 確認 CSR 檔案
$CSRLocations = @(
    $RenewalParams.CSROutputPath,
    'C:\Windows\System32\CertSrv\CertEnroll\'
)

$CSRFound = $false
foreach ($Location in $CSRLocations) {
    if (Test-Path $Location) {
        $CSRFiles = Get-ChildItem $Location -Filter '*.req' -ErrorAction SilentlyContinue
        if ($CSRFiles) {
            foreach ($CSR in $CSRFiles) {
                Write-Host "      [OK] CSR 已產生：$($CSR.FullName)" -ForegroundColor Green
                Write-Host "           大小：$($CSR.Length) bytes" -ForegroundColor Gray
                Write-Host "           時間：$($CSR.LastWriteTime)" -ForegroundColor Gray
            }
            $CSRFound = $true
        }
    }
}

if (-not $CSRFound) {
    Write-Host "      [ERROR] 找不到 CSR 檔案，請檢查 DSC 執行結果。" -ForegroundColor Red
    Write-Host "              執行 Get-DscConfigurationStatus 查看詳細錯誤。" -ForegroundColor Red
    exit 1
}

# 顯示新 CSR 的 Public Key 指紋（供確認用）
Write-Host ""
Write-Host "      [確認] 新 CSR 的 Public Key Hash：" -ForegroundColor Gray
certutil -dump $RenewalParams.CSROutputPath 2>$null |
    Select-String -Pattern 'Public Key Hash|Subject' |
    ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }
#endregion

#region ── Step 7：後續步驟提示 ──────────────────────────────
Write-Host ""
Write-Host "[7/7] 後續步驟提示..." -ForegroundColor Yellow

Write-Host @"

==================================================
  Subordinate CA Renewal CSR 產生完成！

  新 CSR 位置：$($RenewalParams.CSROutputPath)
  備份位置  ：$BackupDir

  ─────────────────────────────────────────────
  後續步驟：

  [Root CA VM]
    1. 將新 CSR 複製到 Root CA VM：
       C:\RootCA\requests\intermediateCA.csr

    2. 若需要更新 CDP URL，先修改：
       C:\RootCA\openssl-rootca.cnf
       → [v3_intermediate_ca] crlDistributionPoints

    3. 撤銷舊憑證（若仍有效）：
       執行 04_revoke_cert.bat

    4. 重新簽發新憑證：
       執行 02_sign_intermediate.bat

    5. 更新並發布 CRL：
       執行 03_renew_crl.bat

  [AD CS 伺服器]
    6. 將簽回的憑證複製到：
       C:\CAConfig\SubCA_renewal.crt

    7. 安裝新憑證：
       執行 02_install_subcacert.ps1

    8. 更新 CDP/AIA 設定（如有異動）：
       執行 03_configure_cdp_aia.ps1

  ─────────────────────────────────────────────
  注意：CA 服務目前為停止狀態，
        安裝新憑證後才會恢復正常運作。
==================================================
"@ -ForegroundColor Cyan
#endregion
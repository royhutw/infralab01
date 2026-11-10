# ============================================================
#  06_Deploy-RootCACert.ps1
#  （修正：原檔頭註解遺漏檔名編號前綴，已補上，與檔案實際
#    名稱 06_Deploy-RootCACert.ps1 一致，避免與 07 混淆）
#
#  將 Root CA 憑證部署到網域內所有電腦的
#  受信任根憑證授權單位（Trusted Root Certification Authorities）存放區
#
#  部署方式（兩條路徑並行）：
#    1. certutil -dspublish ... RootCA：發布至 AD 的 Certification Authorities 容器，
#       網域成員在 Auto-Enrollment（05 的 AEPolicy）執行時自動下載到受信任根存放區。
#       這是主要、標準的機制。
#    2. GPO 登錄值：將憑證以「序列化憑證存放區格式」（X509ContentType.SerializedCert，
#       與公開金鑰原則寫入的 Blob 相同）寫入
#       HKLM\SOFTWARE\Policies\Microsoft\SystemCertificates\Root\Certificates\<指紋>\Blob。
#       寫入後會讀回比對；是否真的在用戶端生效，請依完成提示在用戶端實測。
#
#  適用網域：corp.foo.bar.tw
#  執行地點：DC 或具備 GroupPolicy / RSAT 模組的成員伺服器
#  執行身份：Domain Admins / Enterprise Admins
# ============================================================
#requires -Version 5.1
#requires -RunAsAdministrator

#region ── 參數區（統一從 CAConfig.psd1 讀取，請至該檔案修改參數）──
# 本腳本用到的區塊：Global（網域名稱/DN、記錄目錄）、ExchangePaths（Root CA 憑證路徑）、
# DeployRootCAGPO（GPO名稱/說明/登錄路徑）
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
$Params = Merge-CAConfig -Sections 'Global','ExchangePaths','DeployRootCAGPO'

# Set-GPRegistryValueIfNeeded 已移至共用的 Import-CAConfig.ps1
# ── 套用目標（網域根層級，涵蓋所有電腦）────────────────────
# 直接沿用 Global.DomainDN，不再另外重複定義一份一樣的 DN 字串。
$Params.GPOTarget = $Params.DomainDN
#endregion

$ErrorActionPreference = 'Stop'
$LogFile = Start-CATranscript -Name '06_Deploy-RootCACert' -Params $Params
trap {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        詳細記錄：$LogFile" -ForegroundColor Red
    Stop-CATranscript
    exit 1
}

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  部署 Root CA 憑證至網域所有電腦"                  -ForegroundColor Cyan
Write-Host "  網域：$($Params.DomainName)"                      -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

#region ── 前置確認 ──────────────────────────────────────────

# ── 確認必要模組 ─────────────────────────────────────────────
Write-Host "[前置] 載入必要模組..." -ForegroundColor Yellow
Import-Module GroupPolicy
Import-Module ActiveDirectory
Write-Host "      [OK] 模組載入完成" -ForegroundColor Green

# ── 確認 Root CA 憑證檔案存在 ────────────────────────────────
Write-Host "[前置] 確認 Root CA 憑證檔案..." -ForegroundColor Yellow
if (-not (Test-Path -LiteralPath $Params.RootCACertPath)) {
    throw "找不到 Root CA 憑證：$($Params.RootCACertPath)（請將 RootCA.crt 複製到指定路徑後重新執行）。"
}

# 讀取並驗證憑證
$RootCACert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Params.RootCACertPath)
$RootBasicConstraints = $RootCACert.Extensions |
    Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] }
if ($null -eq $RootBasicConstraints -or -not $RootBasicConstraints.CertificateAuthority) {
    throw "$($Params.RootCACertPath) 不是 CA 憑證（Basic Constraints: CA=TRUE 缺失），不可部署為受信任根。"
}
if ($RootCACert.Subject -ne $RootCACert.Issuer) {
    throw "$($Params.RootCACertPath) 不是自簽的 Root CA 憑證（Subject 與 Issuer 不同）；受信任根必須是 Root CA 本身。"
}
if ($RootCACert.NotAfter -lt (Get-Date)) { throw "Root CA 憑證已過期（$($RootCACert.NotAfter)）。" }
Write-Host "      [OK] 憑證讀取成功" -ForegroundColor Green
Write-Host "      Subject    : $($RootCACert.Subject)" -ForegroundColor Gray
Write-Host "      Thumbprint : $($RootCACert.Thumbprint)" -ForegroundColor Gray
Write-Host "      到期日     : $($RootCACert.NotAfter)" -ForegroundColor Gray
Write-Host "      記錄檔     : $LogFile" -ForegroundColor Gray

#endregion

#region ── Step 1：建立或取得 GPO ────────────────────────────
Write-Host ""
Write-Host "[1/5] 建立 GPO：$($Params.GPOName)..." -ForegroundColor Yellow

$GPO = Get-GPO -Name $Params.GPOName -Domain $Params.DomainName -ErrorAction SilentlyContinue
if ($null -eq $GPO) {
    $GPO = New-GPO -Name    $Params.GPOName `
                   -Comment $Params.GPOComment `
                   -Domain  $Params.DomainName
    Write-Host "      [OK] GPO 已建立：$($Params.GPOName)" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] GPO 已存在，將更新設定。" -ForegroundColor Yellow
}
Write-Host "      GPO ID：$($GPO.Id)" -ForegroundColor Gray
#endregion

#region ── Step 2：將 Root CA 憑證寫入 GPO ───────────────────
Write-Host ""
Write-Host "[2/5] 發布 Root CA 憑證並寫入 GPO..." -ForegroundColor Yellow

# 先將憑證加入本機受信任根憑證存放區（供本機立即生效）
Write-Host "      將憑證加入本機受信任根存放區..." -ForegroundColor Gray
$LocalStore = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
$LocalStore.Open('ReadWrite')
try {
    if ($null -eq ($LocalStore.Certificates | Where-Object { $_.Thumbprint -eq $RootCACert.Thumbprint })) {
        $LocalStore.Add($RootCACert)
        Write-Host "      [OK] 已加入本機受信任根存放區" -ForegroundColor Green
    } else {
        Write-Host "      [SKIP] 憑證已存在於本機存放區" -ForegroundColor Yellow
    }
} finally {
    $LocalStore.Close()
}

# ── 路徑 1：發布至 AD 的 Certification Authorities 容器（主要機制）──
Write-Host "      發布 Root CA 憑證至 AD..." -ForegroundColor Gray
Invoke-CertutilChecked -Arguments @('-dspublish', '-f', $Params.RootCACertPath, 'RootCA') `
    -SuccessMessage '已發布至 AD（Certification Authorities 容器）' `
    -FailureMessage '發布 Root CA 憑證至 AD 失敗' -Indent '      '

# ── 路徑 2：GPO 登錄值 ───────────────────────────────────────
# Blob 必須是「序列化憑證存放區格式」（CertSerializeCertificateStoreElement），
# 以 X509ContentType.SerializedCert 匯出即為此格式；不可自行拼接標頭。
# 登錄路徑引用參數區的 TrustedRootStore，避免多處各自維護。
$RegKey   = "$($Params.TrustedRootStore)\$($RootCACert.Thumbprint)"
$BlobData = $RootCACert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::SerializedCert)

$BlobChanged = Set-GPRegistryValueIfNeeded -GpoName $Params.GPOName `
    -Key $RegKey `
    -ValueName 'Blob' `
    -Type 'Binary' `
    -Value $BlobData

if ($BlobChanged) {
    Write-Host "      [OK] 憑證已寫入 GPO 登錄設定" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] GPO 登錄值已符合目標，未重複寫入" -ForegroundColor DarkGray
}
Write-Host "      登錄路徑：$RegKey" -ForegroundColor Gray
#endregion

#region ── Step 3：連結 GPO 至網域根層級 ─────────────────────
Write-Host ""
Write-Host "[3/5] 連結 GPO 至網域根層級..." -ForegroundColor Yellow

$ExistingLink = Get-GPInheritance -Target $Params.GPOTarget -Domain $Params.DomainName |
    Select-Object -ExpandProperty GpoLinks |
    Where-Object { $_.DisplayName -eq $Params.GPOName }

if ($null -eq $ExistingLink) {
    New-GPLink -Guid        $GPO.Id `
               -Target      $Params.GPOTarget `
               -Domain      $Params.DomainName `
               -LinkEnabled Yes `
               -Enforced    Yes | Out-Null
    Write-Host "      [OK] GPO 已連結（Enforced = Yes）" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] GPO 連結已存在。" -ForegroundColor Yellow
}
#endregion

#region ── Step 4：強制套用至 DC（立即生效）──────────────────
Write-Host ""
Write-Host "[4/5] 強制更新本機群組原則..." -ForegroundColor Yellow
gpupdate /force /target:computer | Out-Null
Write-Host "      [OK] 本機 GPO 已更新" -ForegroundColor Green
#endregion

#region ── Step 5：驗證 ──────────────────────────────────────
Write-Host ""
Write-Host "[5/5] 驗證部署結果..." -ForegroundColor Yellow

# (a) AD 的 Certification Authorities 容器（網域成員 Auto-Enrollment 的來源）
$ConfigNC = ([ADSI]"LDAP://RootDSE").configurationNamingContext
$CaContainer = "CN=Certification Authorities,CN=Public Key Services,CN=Services,$ConfigNC"
$InAD = Get-ADObject -SearchBase $CaContainer -SearchScope OneLevel -Filter * -Properties cACertificate |
    Where-Object {
        $_.cACertificate | Where-Object {
            (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,[byte[]]$_)).Thumbprint -eq $RootCACert.Thumbprint
        }
    }
if ($InAD) {
    Write-Host "      [OK] Root CA 憑證已在 AD 的 Certification Authorities 容器" -ForegroundColor Green
} else {
    Write-Host "      [WARN] AD 的 Certification Authorities 容器找不到此憑證（可能尚未複寫），請稍後以 certutil -viewstore -enterprise Root 確認。" -ForegroundColor Yellow
}

# (b) GPO 內的登錄值讀回比對
$StoredBlob = (Get-GPRegistryValue -Name $Params.GPOName -Key $RegKey -ValueName 'Blob' -Domain $Params.DomainName -ErrorAction SilentlyContinue).Value
if ($null -ne $StoredBlob -and (($StoredBlob | ForEach-Object { $_.ToString('X2') }) -join '') -eq (($BlobData | ForEach-Object { $_.ToString('X2') }) -join '')) {
    Write-Host "      [OK] GPO 內的 Blob 與預期一致" -ForegroundColor Green
} else {
    Write-Host "      [WARN] GPO 內的 Blob 讀回後與預期不一致，請檢查 GPO 報告。" -ForegroundColor Yellow
}

# 產生 GPO 報告
$ReportPath = Join-Path (Join-Path $Params.CAConfigDir 'Logs') 'RootCA_Deploy_GPO_Report.html'
Get-GPOReport -Name $Params.GPOName -ReportType Html -Path $ReportPath -Domain $Params.DomainName
Write-Host "      [OK] GPO 報告：$ReportPath" -ForegroundColor Green
#endregion

#region ── 完成提示 ──────────────────────────────────────────
Write-Host @"

==================================================
  Root CA 憑證部署完成！

  GPO 名稱  ：$($Params.GPOName)
  套用範圍  ：$($Params.GPOTarget)（整個網域）
  憑證主體  ：$($RootCACert.Subject)
  Thumbprint：$($RootCACert.Thumbprint)
  到期日    ：$($RootCACert.NotAfter)

  用戶端生效方式：
    自動：等待 GPO 更新 / Auto-Enrollment 週期（約 90 分鐘）
    手動：在用戶端執行 gpupdate /force 與 certutil -pulse

  【請務必在用戶端實測】本腳本只能驗證 AD 與 GPO 內容，無法確認用戶端是否真的信任：
    Get-ChildItem Cert:\LocalMachine\Root |
        Where-Object { `$_.Thumbprint -eq '$($RootCACert.Thumbprint)' }
    （或 certlm.msc → 受信任的根憑證授權單位 → 憑證）
    若 GPO 路徑未生效，AD 發布路徑（Auto-Enrollment）仍會讓網域成員信任此 Root CA；
    也可改在 GPMC：電腦設定 → 原則 → Windows 設定 → 安全性設定 → 公開金鑰原則
    → 受信任的根憑證授權單位 → 匯入。

  注意事項：
    1. 新加入網域的電腦在第一次 GPO 套用 / Auto-Enrollment 後即自動信任
    2. 若有多台 DC，請等待 AD 複寫完成（預設 15 分鐘）
    3. 若環境有 OU 封鎖繼承（Block Inheritance），
       需另外在該 OU 連結此 GPO 或設定 Enforced
==================================================
"@ -ForegroundColor Green
#endregion

Stop-CATranscript
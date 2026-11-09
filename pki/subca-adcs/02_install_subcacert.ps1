# ============================================================
#  02_install_subcacert.ps1
#  安裝由離線 Root CA 簽回的 Subordinate CA 憑證
#  執行時機：Root CA 簽回 .crt 憑證後，複製到本機再執行此腳本
# ============================================================

#region ── 參數區（統一從 CAConfig.psd1 讀取，請至該檔案修改參數）──
# 本腳本用到的區塊：Global（CRL 發布目錄）、
# ExchangePaths（Root CA / Sub CA 憑證交換路徑，與 01 共用同一份）
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
$Params = Merge-CAConfig -Sections 'Global','ExchangePaths'
#endregion

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  安裝 Subordinate CA 憑證"                         -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

# ── 確認憑證檔案存在 ─────────────────────────────────────────
foreach ($File in @($Params.SignedCertPath, $Params.RootCACertPath, $Params.RootCACRLPath)) {
    if (-not (Test-Path $File)) {
        Write-Host "[ERROR] 找不到檔案：$File" -ForegroundColor Red
        exit 1
    }
}

function Invoke-CertutilChecked {
    param(
        [Parameter(Mandatory = $true)][string]$Arguments,
        [string]$SuccessMessage = 'certutil 執行成功。',
        [string]$FailureMessage = 'certutil 執行失敗。'
    )

    $Output = & certutil $Arguments 2>&1
    $ExitCode = $LASTEXITCODE

    if ($ExitCode -ne 0) {
        Write-Host "      [ERROR] $FailureMessage（退出碼：$ExitCode）" -ForegroundColor Red
        if ($Output) {
            foreach ($Line in $Output) {
                Write-Host "      $Line" -ForegroundColor Red
            }
        }
        throw "certutil $Arguments 執行失敗。"
    }

    Write-Host "      [OK] $SuccessMessage" -ForegroundColor Green
    return $Output
}

# ── Step 1：確認 Root CA CRL 已發布（避免安裝時驗證失敗）────
Write-Host "[1/5] 確認 Root CA CRL 已發布至信任存放區..." -ForegroundColor Yellow
$RootCRLThumbprint = (Get-PfxCertificate -FilePath $Params.RootCACRLPath -ErrorAction SilentlyContinue).Thumbprint
if (-not [string]::IsNullOrWhiteSpace($RootCRLThumbprint)) {
    $CurrentRootCRL = Get-ChildItem Cert:\Root | Where-Object { $_.Thumbprint -eq $RootCRLThumbprint }
    if ($null -ne $CurrentRootCRL) {
        Write-Host "      [SKIP] Root CA CRL 已存在於 Root 信任存放區" -ForegroundColor DarkGray
    } else {
        Invoke-CertutilChecked -Arguments "-addstore \"Root\" $($Params.RootCACRLPath)" -SuccessMessage 'Root CA CRL 已加入信任存放區' -FailureMessage 'Root CA CRL 加入信任存放區失敗'
    }
} else {
    Invoke-CertutilChecked -Arguments "-addstore \"Root\" $($Params.RootCACRLPath)" -SuccessMessage 'Root CA CRL 已加入信任存放區' -FailureMessage 'Root CA CRL 加入信任存放區失敗'
}

# ── Step 2：安裝簽回的 Sub CA 憑證 ──────────────────────────
Write-Host "[2/5] 安裝 Subordinate CA 憑證..." -ForegroundColor Yellow
$SignedCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Params.SignedCertPath)
$InstalledCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $SignedCert.Thumbprint }
if ($null -ne $InstalledCert) {
    Write-Host "      [SKIP] Subordinate CA 憑證已安裝，跳過重複安裝" -ForegroundColor DarkGray
} else {
    # certutil -installcert 會自動將憑證與 CA 金鑰配對並啟動 CA 服務
    Invoke-CertutilChecked -Arguments "-installcert $($Params.SignedCertPath)" -SuccessMessage 'Subordinate CA 憑證安裝成功' -FailureMessage '憑證安裝失敗！請確認憑證與本機 CSR 金鑰是否匹配'
}
Write-Host "      [OK]" -ForegroundColor Green

# ── Step 3：啟動 CA 服務 ────────────────────────────────────
Write-Host "[3/5] 啟動 CertSvc（AD CS 服務）..." -ForegroundColor Yellow
$CertSvc = Get-Service -Name 'CertSvc' -ErrorAction SilentlyContinue
if ($null -eq $CertSvc) {
    throw "找不到 CertSvc 服務，請確認此機器已安裝 AD CS。"
}
if ($CertSvc.Status -ne 'Running') {
    Start-Service -Name 'CertSvc' -ErrorAction Stop
    Write-Host "      [OK] CertSvc 已啟動" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] CertSvc 已在執行中" -ForegroundColor DarkGray
}
Set-Service -Name 'CertSvc' -StartupType Automatic
Write-Host "      [OK]" -ForegroundColor Green

# ── Step 4：發布 Root CA 憑證至 AD DS ────────────────────────
Write-Host "[4/5] 發布 Root CA 憑證至 AD（NTAuthCertificates / AIA）..." -ForegroundColor Yellow
# 發布至 AD DS 的 Certification Authorities 容器
Invoke-CertutilChecked -Arguments "-dspublish -f $($Params.RootCACertPath) RootCA" -SuccessMessage 'Root CA 憑證已發布至 AD' -FailureMessage 'Root CA 憑證發布至 AD 失敗'
# 發布 Sub CA 憑證至 AD DS 的 SubCA 容器
Invoke-CertutilChecked -Arguments "-dspublish -f $($Params.SignedCertPath) SubCA" -SuccessMessage 'Sub CA 憑證已發布至 AD' -FailureMessage 'Sub CA 憑證發布至 AD 失敗'

# ── Step 5：將 Root CA CRL 複製到 CRL 發布目錄 ───────────────
Write-Host "[5/5] 複製 Root CA CRL 到發布目錄..." -ForegroundColor Yellow
New-Item -Path $Params.CRLPublishPath -ItemType Directory -Force | Out-Null
$RootCACRLTarget = Join-Path $Params.CRLPublishPath (Split-Path $Params.RootCACRLPath -Leaf)
$RootCACertTarget = Join-Path $Params.CRLPublishPath (Split-Path $Params.RootCACertPath -Leaf)
if (-not (Test-Path $RootCACRLTarget) -or ((Get-Item $RootCACRLTarget).Length -ne (Get-Item $Params.RootCACRLPath).Length)) {
    Copy-Item -Path $Params.RootCACRLPath -Destination $RootCACRLTarget -Force
}
if (-not (Test-Path $RootCACertTarget) -or ((Get-Item $RootCACertTarget).Length -ne (Get-Item $Params.RootCACertPath).Length)) {
    Copy-Item -Path $Params.RootCACertPath -Destination $RootCACertTarget -Force
}
Write-Host "      [OK]" -ForegroundColor Green

# ── 驗證 CA 服務狀態 ─────────────────────────────────────────
Write-Host ""
Write-Host "[驗證] CA 服務狀態：" -ForegroundColor Yellow
Get-Service -Name 'CertSvc' | Select-Object Name, Status, StartType

Write-Host ""
Write-Host "[驗證] CA 資訊：" -ForegroundColor Yellow
certutil -getconfig

Write-Host @"

==================================================
  Subordinate CA 憑證安裝完成！
  下一步：執行 03_configure_cdp_aia.ps1 設定 CDP/AIA
==================================================
"@ -ForegroundColor Green

# ============================================================
#  02_install_subcacert.ps1
#  安裝由離線 Root CA 簽回的 Subordinate CA 憑證
#  執行時機：Root CA 簽回 .crt 憑證後，複製到本機再執行此腳本
# ============================================================

#region ── 參數區 ────────────────────────────────────────────
$Params = @{
    SignedCertPath  = 'C:\CAConfig\SubCA.crt'     # Root CA 簽回的憑證
    RootCACertPath  = 'C:\CAConfig\RootCA.crt'    # Root CA 憑證
    RootCACRLPath   = 'C:\CAConfig\RootCA.crl'    # Root CA CRL
    CRLPublishPath  = 'C:\CRLPublish'             # CRL 發布目錄
}
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

# ── Step 1：確認 Root CA CRL 已發布（避免安裝時驗證失敗）────
Write-Host "[1/5] 確認 Root CA CRL 已發布至信任存放區..." -ForegroundColor Yellow
certutil -addstore "Root" $Params.RootCACRLPath | Out-Null
Write-Host "      [OK]" -ForegroundColor Green

# ── Step 2：安裝簽回的 Sub CA 憑證 ──────────────────────────
Write-Host "[2/5] 安裝 Subordinate CA 憑證..." -ForegroundColor Yellow
# certutil -installcert 會自動將憑證與 CA 金鑰配對並啟動 CA 服務
certutil -installcert $Params.SignedCertPath

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] 憑證安裝失敗！請確認憑證與本機 CSR 金鑰是否匹配。" -ForegroundColor Red
    exit 1
}
Write-Host "      [OK]" -ForegroundColor Green

# ── Step 3：啟動 CA 服務 ────────────────────────────────────
Write-Host "[3/5] 啟動 CertSvc（AD CS 服務）..." -ForegroundColor Yellow
Start-Service -Name 'CertSvc' -ErrorAction SilentlyContinue
Set-Service  -Name 'CertSvc' -StartupType Automatic
Write-Host "      [OK]" -ForegroundColor Green

# ── Step 4：發布 Root CA 憑證至 AD DS ────────────────────────
Write-Host "[4/5] 發布 Root CA 憑證至 AD（NTAuthCertificates / AIA）..." -ForegroundColor Yellow
# 發布至 AD DS 的 Certification Authorities 容器
certutil -dspublish -f $Params.RootCACertPath RootCA | Out-Null
# 發布 Sub CA 憑證至 AD DS 的 SubCA 容器
certutil -dspublish -f $Params.SignedCertPath SubCA  | Out-Null
Write-Host "      [OK]" -ForegroundColor Green

# ── Step 5：將 Root CA CRL 複製到 CRL 發布目錄 ───────────────
Write-Host "[5/5] 複製 Root CA CRL 到發布目錄..." -ForegroundColor Yellow
New-Item -Path $Params.CRLPublishPath -ItemType Directory -Force | Out-Null
Copy-Item -Path $Params.RootCACRLPath -Destination $Params.CRLPublishPath -Force
Copy-Item -Path $Params.RootCACertPath -Destination $Params.CRLPublishPath -Force
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

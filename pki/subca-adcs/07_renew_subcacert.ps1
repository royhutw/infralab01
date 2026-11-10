# ============================================================
#  07_renew_subcacert.ps1
#  Subordinate CA 憑證更新（產生「新金鑰」的更新 CSR）
#
#  作法：以 certutil -renewcert（不加 ReuseKeys）在「執行中的 CA」上產生新金鑰對與更新 CSR。
#    - 不會移除 CA 角色、不會刪除資料庫、不會刪除舊金鑰、不會刪除 AD 物件。
#      舊金鑰仍用來簽署「舊 CA 憑證時期已簽發憑證」的 CRL；刪除它會使這些憑證無法撤銷。
#    - CA 持續以舊憑證運作，直到新憑證安裝完成才切換（無停機）。
#    - 新金鑰長度由 %windir%\CAPolicy.inf 的 [certsrv_server] RenewalKeyLength 決定
#      （預設 2048，與 01 安裝時的 4096 不同），本腳本會依 CAConfig.psd1 的
#      ADCSInstall.KeyLength 寫入並在產生後驗證。
#
#  執行時機：Sub CA 憑證即將到期、需更換 CDP/AIA URL、或主動汰換金鑰時。
#
#  更新流程：
#    1. 07（本腳本）  備份 CA（含私鑰與資料庫）→ 產生 SubCA_renewal.req
#    2. Root CA       簽發更新憑證（見 README「七、Sub CA 憑證更新」）
#    3. 02 -Renewal   安裝 SubCA_renewal.crt、重啟 CertSvc、發布新 CRL
#
#  需求：以系統管理員身分在 Sub CA 上執行。
# ============================================================
#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    # 已自行完成 certutil -backup（含私鑰）時可略過備份步驟；不建議
    [switch] $SkipBackup
)

#region ── 參數區（統一從 CAConfig.psd1 讀取，請至該檔案修改參數）──
# 本腳本用到的區塊：Global（CA 名稱 / 記錄目錄）、ExchangePaths（Root CA CRL 路徑，僅用於提示）、
# ADCSInstall（金鑰長度，與 01 共用）、SubCARenewal（更新 CSR 輸出路徑 / 備份目錄）
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
$Params = Merge-CAConfig -Sections 'Global','ExchangePaths','ADCSInstall','SubCARenewal'
#endregion

$ErrorActionPreference = 'Stop'
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile = Start-CATranscript -Name '07_renew_subcacert' -Params $Params
trap {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        詳細記錄：$LogFile" -ForegroundColor Red
    Stop-CATranscript
    exit 1
}

#region ── 輔助函式 ──────────────────────────────────────────
function Set-CAPolicyRenewalKeyLength {
    <# 確保 %windir%\CAPolicy.inf 的 [certsrv_server] 含 RenewalKeyLength=<KeyLength>（原檔先備份） #>
    param([Parameter(Mandatory)][int] $KeyLength)

    $Path  = Join-Path $env:windir 'CAPolicy.inf'
    $Lines = if (Test-Path -LiteralPath $Path) { @(Get-Content -LiteralPath $Path) } else { @() }
    if ($Lines.Count -gt 0) { Copy-Item -LiteralPath $Path -Destination "$Path.bak_$Timestamp" }

    $Out = New-Object System.Collections.Generic.List[string]
    $InSection = $false; $Done = $false; $SectionSeen = $false
    foreach ($Line in $Lines) {
        if ($Line -match '^\s*\[(.+)\]\s*$') {
            if ($InSection -and -not $Done) { $Out.Add("RenewalKeyLength=$KeyLength"); $Done = $true }
            $InSection = ($Matches[1] -ieq 'certsrv_server')
            if ($InSection) { $SectionSeen = $true }
            $Out.Add($Line)
            continue
        }
        if ($InSection -and $Line -match '^\s*RenewalKeyLength\s*=') {
            if (-not $Done) { $Out.Add("RenewalKeyLength=$KeyLength"); $Done = $true }
            continue
        }
        $Out.Add($Line)
    }
    if ($InSection -and -not $Done) { $Out.Add("RenewalKeyLength=$KeyLength"); $Done = $true }
    if (-not $SectionSeen) { $Out.Add('[certsrv_server]'); $Out.Add("RenewalKeyLength=$KeyLength") }

    Set-Content -LiteralPath $Path -Value $Out -Encoding ASCII
    return $Path
}
#endregion

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  Subordinate CA 憑證更新（新金鑰 CSR）"             -ForegroundColor Cyan
Write-Host "  時間：$Timestamp"                                  -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  記錄檔：$LogFile" -ForegroundColor Gray
Write-Host ""

# ── Step 0：前置檢查 ─────────────────────────────────────────
Write-Host "[0/5] 前置檢查..." -ForegroundColor Yellow

$CAConfig = Get-LocalCAConfigString
$Svc = Get-Service -Name 'CertSvc' -ErrorAction SilentlyContinue
if ($null -eq $Svc) { throw "找不到 CertSvc 服務，請確認此機器已安裝 AD CS。" }
if ($Svc.Status -ne 'Running') { Start-Service -Name 'CertSvc' }
if (-not (Wait-CertSvcReady)) { throw "CA 未回應 certutil -ping；更新必須在 CA 正常運作時進行，請先排除服務問題。" }
Write-Host "      [OK] CA 運作中：$CAConfig" -ForegroundColor Green

$CurrentCerts = @(Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -like "CN=$($Params.CACommonName),*" -or $_.Subject -eq "CN=$($Params.CACommonName)" })
foreach ($Cert in $CurrentCerts) {
    Write-Host "      目前 CA 憑證：$($Cert.Thumbprint)  到期 $($Cert.NotAfter.ToString('yyyy-MM-dd'))  私鑰：$($Cert.HasPrivateKey)" -ForegroundColor Gray
}
if ($CurrentCerts.Count -eq 0) { Write-Host "      [WARN] LocalMachine\My 找不到 $($Params.CACommonName) 的憑證，請確認 CA 已完成 02。" -ForegroundColor Yellow }

# ── 執行確認 ─────────────────────────────────────────────────
Write-Host ""
Write-Host "==================================================" -ForegroundColor Yellow
Write-Host "  此操作將："                                       -ForegroundColor Yellow
Write-Host "    1. 備份 CA（私鑰 + 資料庫）至 $($Params.BackupPath)" -ForegroundColor Yellow
Write-Host "    2. 更新 $env:windir\CAPolicy.inf 的 RenewalKeyLength = $($Params.KeyLength)" -ForegroundColor Yellow
Write-Host "    3. 以 certutil -renewcert 產生新金鑰與更新 CSR"  -ForegroundColor Yellow
Write-Host "  CA 不會停止、舊金鑰與資料庫不會被刪除。"            -ForegroundColor Yellow
Write-Host "==================================================" -ForegroundColor Yellow
if ((Read-Host "確認繼續？(YES/N)") -ne 'YES') {
    Write-Host "[INFO] 作業取消。" -ForegroundColor Gray
    Stop-CATranscript
    exit 0
}

# ── Step 1：備份 CA ──────────────────────────────────────────
Write-Host ""
Write-Host "[1/5] 備份 CA（私鑰 + 資料庫）..." -ForegroundColor Yellow
$BackupDir = Join-Path $Params.BackupPath $Timestamp
New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null

if ($SkipBackup) {
    Write-Host "      [WARN] 已指定 -SkipBackup，略過 certutil -backup。" -ForegroundColor Yellow
} else {
    Write-Host "      certutil 會要求輸入保護私鑰的密碼（請妥善保管；備份含 CA 私鑰，需放置於安全位置）。" -ForegroundColor Gray
    # 不擷取輸出，讓 certutil 能直接與使用者互動輸入密碼
    & certutil -f -backup (Join-Path $BackupDir 'CABackup')
    if ($LASTEXITCODE -ne 0) { throw "certutil -backup 失敗（退出碼：$LASTEXITCODE），已中止，未做任何變更。" }
    Write-Host "      [OK] CA 備份完成：$BackupDir\CABackup" -ForegroundColor Green
}

# 一併保留登錄設定與現有 CA 憑證（便於稽核與還原）
& certutil -getreg CA\ 2>&1 | Out-File -FilePath (Join-Path $BackupDir 'CA_Registry.txt') -Encoding UTF8
foreach ($Cert in $CurrentCerts) {
    Export-Certificate -Cert $Cert -FilePath (Join-Path $BackupDir "SubCA_$($Cert.Thumbprint).cer") | Out-Null
}
Write-Host "      [OK] 已保存登錄設定與現有 CA 憑證（公鑰）：$BackupDir" -ForegroundColor Green

# ── Step 2：CAPolicy.inf 金鑰長度 ────────────────────────────
Write-Host ""
Write-Host "[2/5] 設定新金鑰長度（CAPolicy.inf RenewalKeyLength）..." -ForegroundColor Yellow
$PolicyPath = Set-CAPolicyRenewalKeyLength -KeyLength $Params.KeyLength
Write-Host "      [OK] 已設定：$PolicyPath（RenewalKeyLength=$($Params.KeyLength)）" -ForegroundColor Green

# ── Step 3：產生新金鑰與更新 CSR ─────────────────────────────
Write-Host ""
Write-Host "[3/5] 產生新金鑰與更新 CSR（certutil -renewcert）..." -ForegroundColor Yellow
$StartTime = Get-Date
$Output    = & certutil -f -renewcert 2>&1
$ExitCode  = $LASTEXITCODE
$Output | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }
if ($ExitCode -ne 0) { throw "certutil -renewcert 失敗（退出碼：$ExitCode）。CA 與舊金鑰未受影響。" }

# 取得 CSR 檔案：優先從輸出解析路徑，否則在系統磁碟根目錄找本次新產生的 .req
$CsrSource = $null
$PathHit = ($Output | Out-String) | Select-String -Pattern '[A-Za-z]:\\[^\r\n"]*\.req' | Select-Object -First 1
if ($PathHit -and (Test-Path -LiteralPath $PathHit.Matches[0].Value)) { $CsrSource = $PathHit.Matches[0].Value }
if (-not $CsrSource) {
    $CsrSource = Get-ChildItem -Path "$env:SystemDrive\" -Filter '*.req' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $StartTime.AddSeconds(-5) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $CsrSource) { throw "找不到新產生的 CSR（.req）。請檢視上方 certutil 輸出，或在 $env:SystemDrive\ 下尋找 *.req。" }

New-Item -Path (Split-Path $Params.RenewalCSROutputPath) -ItemType Directory -Force | Out-Null
Copy-Item -LiteralPath $CsrSource -Destination $Params.RenewalCSROutputPath -Force
Write-Host "      [OK] CSR：$($Params.RenewalCSROutputPath)（來源：$CsrSource）" -ForegroundColor Green

# ── Step 4：驗證 CSR ─────────────────────────────────────────
Write-Host ""
Write-Host "[4/5] 驗證 CSR 內容..." -ForegroundColor Yellow
$Dump = & certutil -dump $Params.RenewalCSROutputPath 2>&1 | Out-String
$Dump -split "`r?`n" | Select-String -Pattern 'Subject|Public Key Length|Public Key Algorithm' | Select-Object -First 6 |
    ForEach-Object { Write-Host "      $($_.Line.Trim())" -ForegroundColor Gray }

if ($Dump -match 'Public Key Length:\s*(\d+)') {
    if ([int]$Matches[1] -ne $Params.KeyLength) {
        throw "新 CSR 的金鑰長度為 $($Matches[1])，與設定的 $($Params.KeyLength) 不符。請確認 CAPolicy.inf 後重新執行本腳本，再送交 Root CA 簽發。"
    }
    Write-Host "      [OK] 新金鑰長度：$($Matches[1]) bits" -ForegroundColor Green
} else {
    Write-Host "      [WARN] 無法從 certutil -dump 解析金鑰長度，請人工確認為 $($Params.KeyLength) bits。" -ForegroundColor Yellow
}

# ── Step 5：後續步驟 ─────────────────────────────────────────
Write-Host ""
Write-Host "[5/5] 後續步驟" -ForegroundColor Yellow
Write-Host @"

==================================================
  更新 CSR 已產生，CA 仍以舊憑證正常運作。

  更新 CSR：$($Params.RenewalCSROutputPath)
  備份位置：$BackupDir（含 CA 私鑰，請移至安全位置保管）

  [Root CA VM]
    1. 將更新 CSR 複製為 C:\RootCA\requests\intermediateCA.csr
    2. 若需更換 CDP URL，先修改 ca-env.bat 的 CA_CRL_URL
    3. 執行 02_sign_intermediate.bat 簽發更新憑證
       ※ 不要撤銷舊的 Sub CA 憑證：它簽發的所有憑證都依賴它，撤銷會讓這些憑證全數失效。
         若 Root CA 因 openssl 的 unique_subject = yes 拒絕簽發相同 Subject 的新憑證，
         請在 Root CA 端處理該設定（見 rootca_openssl 目錄說明），而不是撤銷舊憑證；
         撤銷僅限於舊金鑰外洩的情況。
    4. 執行 03_renew_crl.bat（Root CA CRL 需保持有效）

  [AD CS 伺服器]
    5. 將簽回的憑證複製到：$($Params.RenewalSignedCertPath)
       並更新 Root CA 的 CRL：$($Params.RootCACRLPath)（如有更新）
    6. 執行  .\02_install_subcacert.ps1 -Renewal
       （安裝新憑證、重啟 CertSvc、發布以新金鑰簽署的 CRL）
    7. 確認 http://…/CRL 與 /AIA 目錄已出現新的 .crl / .crt（檔名含 (1) 等金鑰索引），
       再執行 Publish-SubCACRL.ps1 並以 certutil -verify -urlfetch 檢查
==================================================
"@ -ForegroundColor Cyan

Stop-CATranscript

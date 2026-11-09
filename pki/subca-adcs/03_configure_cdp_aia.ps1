# ============================================================
#  03_configure_cdp_aia.ps1
#  設定 Subordinate CA 的 CDP（CRL發布點）與 AIA（授權資訊存取）
#  執行時機：Sub CA 憑證安裝完成後（02_install_subcacert.ps1 之後）
#
#  CDP（CRL Distribution Point）：
#    用戶端透過此 URL 下載 CRL 驗證憑證是否已撤銷
#  AIA（Authority Information Access）：
#    用戶端透過此 URL 下載 CA 憑證以建立信任鏈
# ============================================================

#region ── 參數區（統一從 CAConfig.psd1 讀取，請至該檔案修改參數）──
# 本腳本用到的區塊：Global（CRL發布目錄、CDP/AIA URL）、
# CRLPolicy（CRL/Delta CRL 基本週期，與01對照的同一份設定）、
# CDPAIA（CRL重疊緩衝期、憑證最大有效期）
#
# 【提醒】原本這裡的 CAName 參數其實從未在本腳本內被使用
# （CA 是透過下方 certutil -getconfig 動態取得，不是靠這個參數），
# 已一併移除，避免誤導。
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
$Params = Merge-CAConfig -Sections 'Global','CRLPolicy','CDPAIA'
#endregion

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  設定 CDP / AIA 延伸模組"                          -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

function Invoke-CertutilWithCheck {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter(Mandatory)]
        [string] $ActionDescription
    )

    $Output = & certutil @Arguments 2>&1
    $ExitCode = $LASTEXITCODE

    if ($ExitCode -ne 0) {
        Write-Host "      [ERROR] $ActionDescription 失敗（退出碼：$ExitCode）" -ForegroundColor Red
        if ($Output) {
            $Output | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
        }
        throw "certutil $($Arguments -join ' ') 執行失敗。"
    }

    return $Output
}

function Normalize-CertutilRegistryValue {
    param(
        [AllowNull()]
        [string] $Value
    )

    if ($null -eq $Value) {
        return ''
    }

    return ($Value -replace "`r`n|`n|`r", ' ' -replace '\s+', ' ').Trim()
}

function Set-CertutilRegistryIfNeeded {
    param(
        [Parameter(Mandatory)]
        [string] $RegistryName,

        [Parameter(Mandatory)]
        [string] $ExpectedValue,

        [Parameter(Mandatory)]
        [string] $ActionDescription
    )

    $CurrentOutput = & certutil -getreg $RegistryName 2>&1
    $CurrentValue = ''

    if ($LASTEXITCODE -eq 0) {
        $CurrentValue = ($CurrentOutput | Out-String)
        $CurrentValue = $CurrentValue -replace '.*?=\s*', ''
    }

    $CurrentNormalized = Normalize-CertutilRegistryValue -Value $CurrentValue
    $ExpectedNormalized = Normalize-CertutilRegistryValue -Value $ExpectedValue

    if ($CurrentNormalized -and $CurrentNormalized -eq $ExpectedNormalized) {
        Write-Host "      [SKIP] $ActionDescription 已符合設定，未重寫。" -ForegroundColor DarkGray
        return
    }

    Invoke-CertutilWithCheck -Arguments @('-setreg', $RegistryName, $ExpectedValue) -ActionDescription $ActionDescription | Out-Null
    Write-Host "      [OK] $ActionDescription 已更新。" -ForegroundColor Green
}

# ── 確認 CertSvc 服務已啟動 ──────────────────────────────────
$SvcStatus = (Get-Service CertSvc -ErrorAction SilentlyContinue).Status
if ($SvcStatus -ne 'Running') {
    Write-Host "[INFO] CertSvc 尚未啟動，嘗試啟動中..." -ForegroundColor Yellow
    Start-Service CertSvc -ErrorAction Stop
    Start-Sleep -Seconds 3
}

# ── 取得 CA 設定路徑 ─────────────────────────────────────────
# certutil -getconfig 輸出格式為 "伺服器名稱\CA名稱"
# 使用 Where-Object 篩選含有反斜線的行來取得正確路徑
# 修正：原本使用 Select-String 'Config:' 會因輸出格式不符而回傳 null
$CAConfig = (certutil -getconfig) |
    Where-Object { $_ -match '\\\w' } |
    Select-Object -First 1
$CAConfig = $CAConfig.Trim()

if ([string]::IsNullOrWhiteSpace($CAConfig)) {
    Write-Host "[ERROR] 無法取得 CA Config，請確認 CertSvc 服務已啟動。" -ForegroundColor Red
    Write-Host "        執行：Start-Service CertSvc" -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] CA Config：$CAConfig" -ForegroundColor Gray
Write-Host ""

New-Item -Path $Params.CRLPublishPath -ItemType Directory -Force | Out-Null

# ── Step 1：設定 CDP 延伸模組 ────────────────────────────────
Write-Host "[1/5] 設定 CDP 延伸模組..." -ForegroundColor Yellow
#
# 旗標說明：
#   0x1  = 發布至本機 CertEnroll 目錄（CSURL_SERVERPUBLISH）
#   0x2  = 包含在簽發的憑證 CDP 延伸中（CSURL_ADDTOCERTCDP）
#   0x4  = 包含在 CRL 的 Freshest CRL 延伸中（CSURL_ADDTOFRESHESTCRL）
#   0x8  = 發布 Delta CRL 至此位置（CSURL_ADDTOCRLCDP）
#   0x40 = 發布至本機 CertEnroll 目錄（僅 Delta CRL）
#
# 注意：原本使用 CertAdm.CCertAdmin COM 物件清除舊設定，
#       但該 COM 元件在 CA 服務啟動前無法使用（REGDB_E_CLASSNOTREG）。
#       改為直接使用 certutil -setreg 覆寫設定，效果相同。

$CDPList = @(
    # 本機 CertEnroll 預設目錄（保留，供本機發布）
    "1:C:\Windows\System32\CertSrv\CertEnroll\%3%8%9.crl",
    # 本機自訂 CRL 發布目錄（IIS 靜態檔案目錄）
    "1:$($Params.CRLPublishPath)\%3%8%9.crl",
    # HTTP URL：寫入簽發憑證的 CDP 延伸欄位
    "2:$($Params.CDPHttpUrl)/%3%8%9.crl"
)

Set-CertutilRegistryIfNeeded -RegistryName 'CA\CRLPublicationURLs' -ExpectedValue ($CDPList -join '\n') -ActionDescription '設定 CDP 延伸模組'
Write-Host "      CDP 設定完成：" -ForegroundColor Gray
$CDPList | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }

# ── Step 2：設定 AIA 延伸模組 ────────────────────────────────
Write-Host ""
Write-Host "[2/5] 設定 AIA 延伸模組..." -ForegroundColor Yellow

$AIAList = @(
    # 本機 CertEnroll 預設目錄
    "1:C:\Windows\System32\CertSrv\CertEnroll\%1_%3%4.crt",
    # 本機自訂發布目錄
    "1:$($Params.CRLPublishPath)\%1_%3%4.crt",
    # HTTP URL：寫入簽發憑證的 AIA 延伸欄位
    "2:$($Params.AIAHttpUrl)/%1_%3%4.crt"
)

Set-CertutilRegistryIfNeeded -RegistryName 'CA\CACertPublicationURLs' -ExpectedValue ($AIAList -join '\n') -ActionDescription '設定 AIA 延伸模組'
Write-Host "      AIA 設定完成：" -ForegroundColor Gray
$AIAList | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }

# ── Step 3：設定 CRL 更新週期 ────────────────────────────────
Write-Host ""
Write-Host "[3/5] 設定 CRL 更新週期..." -ForegroundColor Yellow

Set-CertutilRegistryIfNeeded -RegistryName 'CA\CRLPeriodUnits' -ExpectedValue ([string]$Params.CRLPeriodUnits) -ActionDescription '設定 CRLPeriodUnits'
Set-CertutilRegistryIfNeeded -RegistryName 'CA\CRLPeriod' -ExpectedValue ([string]$Params.CRLPeriod) -ActionDescription '設定 CRLPeriod'
Set-CertutilRegistryIfNeeded -RegistryName 'CA\CRLOverlapUnits' -ExpectedValue ([string]$Params.CRLOverlapUnits) -ActionDescription '設定 CRLOverlapUnits'
Set-CertutilRegistryIfNeeded -RegistryName 'CA\CRLOverlapPeriod' -ExpectedValue ([string]$Params.CRLOverlapPeriod) -ActionDescription '設定 CRLOverlapPeriod'
Set-CertutilRegistryIfNeeded -RegistryName 'CA\CRLDeltaPeriodUnits' -ExpectedValue ([string]$Params.CRLDeltaPeriodUnits) -ActionDescription '設定 CRLDeltaPeriodUnits'
Set-CertutilRegistryIfNeeded -RegistryName 'CA\CRLDeltaPeriod' -ExpectedValue ([string]$Params.CRLDeltaPeriod) -ActionDescription '設定 CRLDeltaPeriod'

Write-Host "      CRL 有效期  ：$($Params.CRLPeriodUnits) $($Params.CRLPeriod)" -ForegroundColor Gray
Write-Host "      Delta CRL   ：$($Params.CRLDeltaPeriodUnits) $($Params.CRLDeltaPeriod)" -ForegroundColor Gray
Write-Host "      重疊緩衝期  ：$($Params.CRLOverlapUnits) $($Params.CRLOverlapPeriod)" -ForegroundColor Gray

# ── Step 4：設定 CA 簽發憑證的最大有效期 ─────────────────────
Write-Host ""
Write-Host "[4/5] 設定 CA 憑證最大有效期（$($Params.ValidityPeriodUnits) $($Params.ValidityPeriod)）..." -ForegroundColor Yellow
Set-CertutilRegistryIfNeeded -RegistryName 'CA\ValidityPeriodUnits' -ExpectedValue ([string]$Params.ValidityPeriodUnits) -ActionDescription '設定 ValidityPeriodUnits'
Set-CertutilRegistryIfNeeded -RegistryName 'CA\ValidityPeriod' -ExpectedValue ([string]$Params.ValidityPeriod) -ActionDescription '設定 ValidityPeriod'
Write-Host "      [OK]" -ForegroundColor Green

# ── Step 5：重啟 CA 服務並立即發布新 CRL ─────────────────────
Write-Host ""
Write-Host "[5/5] 重啟 CA 服務並發布初始 CRL..." -ForegroundColor Yellow
Restart-Service CertSvc -Force
Start-Sleep -Seconds 5

Invoke-CertutilWithCheck -Arguments @('-crl') -ActionDescription '立即發布 CRL' | Out-Null
Write-Host "      [OK] CRL 已發布至：$($Params.CRLPublishPath)" -ForegroundColor Green

# ── 驗證 CDP/AIA 設定 ────────────────────────────────────────
Write-Host ""
Write-Host "[驗證] 目前 CDP 設定：" -ForegroundColor Yellow
certutil -getreg CA\CRLPublicationURLs

Write-Host ""
Write-Host "[驗證] 目前 AIA 設定：" -ForegroundColor Yellow
certutil -getreg CA\CACertPublicationURLs

Write-Host ""
Write-Host "[驗證] CRL 發布目錄內容：" -ForegroundColor Yellow
Get-ChildItem $Params.CRLPublishPath | Select-Object Name, LastWriteTime, Length

Write-Host @"

==================================================
  CDP / AIA 設定完成！
  下一步：執行 04_create_templates.ps1 建立 EAP-TLS 憑證範本
==================================================
"@ -ForegroundColor Green
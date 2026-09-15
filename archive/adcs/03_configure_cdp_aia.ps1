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

#region ── 參數區（請依實際環境修改） ────────────────────────
$Params = @{
    # ── CA 識別名稱（需與安裝時設定一致）────────────────────
    CAName          = 'corp-foo-bar-tw-SubCA'

    # ── CRL 發布目錄（IIS 需指向此目錄提供靜態下載）─────────
    CRLPublishPath  = 'C:\CRLPublish'

    # ── 對外 HTTP 發布 URL（需可被所有用戶端存取）────────────
    CDPHttpUrl      = 'http://crl.corp.foo.bar.tw/CRL'
    AIAHttpUrl      = 'http://crl.corp.foo.bar.tw/AIA'

    # ── CRL 更新設定 ─────────────────────────────────────────
    # CRL 有效期：建議 1~4 週
    CRLPeriodUnits      = 1
    CRLPeriod           = 'Weeks'    # Days / Weeks / Months
    CRLOverlapUnits     = 12         # CRL 重疊緩衝期（小時），確保新舊 CRL 銜接
    CRLOverlapPeriod    = 'Hours'

    # Delta CRL：更頻繁發布的差異 CRL，降低撤銷延遲
    CRLDeltaPeriodUnits = 1
    CRLDeltaPeriod      = 'Days'

    # ── 憑證有效期上限（CA 不可簽發超過此期限的憑證）────────
    # Computer 憑證 1 年，User 憑證 2 年，設為 2 年以容納兩者
    ValidityPeriodUnits = 2
    ValidityPeriod      = 'Years'
}
#endregion

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  設定 CDP / AIA 延伸模組"                          -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

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

certutil -setreg CA\CRLPublicationURLs ($CDPList -join '\n') | Out-Null
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

certutil -setreg CA\CACertPublicationURLs ($AIAList -join '\n') | Out-Null
Write-Host "      AIA 設定完成：" -ForegroundColor Gray
$AIAList | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }

# ── Step 3：設定 CRL 更新週期 ────────────────────────────────
Write-Host ""
Write-Host "[3/5] 設定 CRL 更新週期..." -ForegroundColor Yellow

certutil -setreg CA\CRLPeriodUnits  $Params.CRLPeriodUnits  | Out-Null
certutil -setreg CA\CRLPeriod       $Params.CRLPeriod        | Out-Null
certutil -setreg CA\CRLOverlapUnits  $Params.CRLOverlapUnits  | Out-Null
certutil -setreg CA\CRLOverlapPeriod $Params.CRLOverlapPeriod | Out-Null
certutil -setreg CA\CRLDeltaPeriodUnits $Params.CRLDeltaPeriodUnits | Out-Null
certutil -setreg CA\CRLDeltaPeriod      $Params.CRLDeltaPeriod      | Out-Null

Write-Host "      CRL 有效期  ：$($Params.CRLPeriodUnits) $($Params.CRLPeriod)" -ForegroundColor Gray
Write-Host "      Delta CRL   ：$($Params.CRLDeltaPeriodUnits) $($Params.CRLDeltaPeriod)" -ForegroundColor Gray
Write-Host "      重疊緩衝期  ：$($Params.CRLOverlapUnits) $($Params.CRLOverlapPeriod)" -ForegroundColor Gray

# ── Step 4：設定 CA 簽發憑證的最大有效期 ─────────────────────
Write-Host ""
Write-Host "[4/5] 設定 CA 憑證最大有效期（$($Params.ValidityPeriodUnits) $($Params.ValidityPeriod)）..." -ForegroundColor Yellow
certutil -setreg CA\ValidityPeriodUnits $Params.ValidityPeriodUnits | Out-Null
certutil -setreg CA\ValidityPeriod      $Params.ValidityPeriod      | Out-Null
Write-Host "      [OK]" -ForegroundColor Green

# ── Step 5：重啟 CA 服務並立即發布新 CRL ─────────────────────
Write-Host ""
Write-Host "[5/5] 重啟 CA 服務並發布初始 CRL..." -ForegroundColor Yellow
Restart-Service CertSvc -Force
Start-Sleep -Seconds 5

certutil -crl | Out-Null
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
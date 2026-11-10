# ============================================================
#  03_configure_cdp_aia.ps1
#  設定 Subordinate CA 的 CDP（CRL發布點）與 AIA（授權資訊存取）
#  執行時機：Sub CA 憑證安裝完成後（02_install_subcacert.ps1 之後），
#            且【必須在簽發任何憑證之前】完成，因為 CDP/AIA 會被寫入
#            每張已簽發憑證，事後無法更正。
#
#  CDP（CRL Distribution Point）：
#    用戶端透過此 URL 下載 CRL 驗證憑證是否已撤銷
#  AIA（Authority Information Access）：
#    用戶端透過此 URL 下載 CA 憑證以建立信任鏈
#
#  修正記錄：
#    - 【CDP 旗標修正】原版本機路徑用 1、HTTP 用 2，導致：
#        (a) Delta CRL 從未發布到任何位置（缺 0x40）
#        (b) 簽發憑證不含 Freshest CRL 延伸（缺 0x4），用戶端找不到 Delta CRL
#      已改為：本機路徑 65（1+64）、HTTP 6（2+4）。
#    - 旗標說明改為依 certutil / CSURL_* 官方定義重寫
#    - 冪等判斷改為直接讀 CA 登錄檔（原版解析 certutil -getreg 輸出，
#      對多行值永遠不相等，SKIP 邏輯形同虛設）
#    - CA 名稱改讀登錄檔 Active 值（原版解析 certutil -getconfig 文字，
#      會取到整行 "Config String: ..." 且在非英文系統不可靠）
#    - 重啟 CertSvc 後改用 certutil -ping 等待就緒，不再固定 sleep
#    - 設定有變更才重啟；新增 CRL/AIA 檔案發布結果驗證
#    - 參數合理性檢查（URL 格式、週期單位）；Transcript 記錄
# ============================================================
#requires -Version 5.1
#requires -RunAsAdministrator

#region ── 參數區（統一從 CAConfig.psd1 讀取，請至該檔案修改參數）──
# 本腳本用到的區塊：Global（CRL發布目錄、CDP/AIA URL、記錄目錄）、
# CRLPolicy（CRL/Delta CRL 基本週期，與01對照的同一份設定）、
# CDPAIA（CRL重疊緩衝期、憑證最大有效期）、
# CRLPublish（僅取用 CertEnrollPath，本機預設 CertEnroll 目錄）
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
$Params = Merge-CAConfig -Sections 'Global','CRLPolicy','CDPAIA','CRLPublish'
#endregion

$ErrorActionPreference = 'Stop'

# ── 記錄檔 ───────────────────────────────────────────────────
$LogDir = Join-Path $Params.CAConfigDir 'Logs'
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
$LogFile = Join-Path $LogDir ('03_configure_cdp_aia_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
Start-Transcript -Path $LogFile | Out-Null

$script:ChangeCount = 0

#region ── 輔助函式 ──────────────────────────────────────────
# Invoke-CertutilChecked / Wait-CertSvcReady 已移至共用的 Import-CAConfig.ps1
$PSDefaultParameterValues['Invoke-CertutilChecked:Indent'] = '      '

function Set-CARegistryIfNeeded {
    <#
      比對 CA 登錄檔目前值與預期值，不同才以 certutil -setreg 寫入。
      Expected 可為單一值或陣列（REG_MULTI_SZ，如 CDP/AIA 清單）。
      寫入時多值以字面 \n 串接，這是 certutil -setreg 對 MULTI_SZ 的要求。
    #>
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)]         $Expected,
        [Parameter(Mandatory)][string] $ActionDescription
    )

    $Current  = (Get-ItemProperty -Path $CAKey -Name $Name -ErrorAction SilentlyContinue).$Name
    $CurText  = (@($Current)  | ForEach-Object { [string]$_ }) -join "`n"
    $ExpText  = (@($Expected) | ForEach-Object { [string]$_ }) -join "`n"

    if ($CurText -eq $ExpText) {
        Write-Host "      [SKIP] $ActionDescription 已符合設定，未重寫。" -ForegroundColor DarkGray
        return
    }

    $Value = (@($Expected) | ForEach-Object { [string]$_ }) -join '\n'
    Invoke-CertutilChecked -Arguments @('-setreg', "CA\$Name", $Value) -FailureMessage "$ActionDescription 失敗" -Quiet
    $script:ChangeCount++
    Write-Host "      [OK] $ActionDescription 已更新。" -ForegroundColor Green
}
#endregion

try {
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  設定 CDP / AIA 延伸模組"                         -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  記錄檔：$LogFile" -ForegroundColor Gray
    Write-Host ""

    # ── 參數合理性檢查 ───────────────────────────────────────
    foreach ($Url in @($Params.CDPHttpUrl, $Params.AIAHttpUrl)) {
        if ($Url -notmatch '^http://[^/]+(/.*[^/])?$') {
            throw "URL 格式不正確（需為 http://… 且結尾不可有斜線）：$Url"
        }
    }
    $ValidUnits = @('Hours','Days','Weeks','Months','Years')
    foreach ($Unit in @($Params.CRLPeriod, $Params.CRLDeltaPeriod, $Params.CRLOverlapPeriod, $Params.ValidityPeriod)) {
        if ($ValidUnits -notcontains $Unit) { throw "不支援的週期單位：$Unit（可用：$($ValidUnits -join ', ')）" }
    }

    # ── 確認 CertSvc 已啟動並可回應 ──────────────────────────
    $Svc = Get-Service CertSvc -ErrorAction SilentlyContinue
    if ($null -eq $Svc) { throw "找不到 CertSvc 服務，請確認 AD CS 已安裝（01、02 已完成）。" }
    if ($Svc.Status -ne 'Running') {
        Write-Host "[INFO] CertSvc 尚未啟動，嘗試啟動中..." -ForegroundColor Yellow
        Start-Service CertSvc
    }
    if (-not (Wait-CertSvcReady)) {
        throw "CA 未在 60 秒內回應 certutil -ping，請先確認 02 已成功完成（Sub CA 憑證已安裝）。"
    }

    # ── 取得 CA 名稱與登錄檔路徑 ─────────────────────────────
    $CertSvcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
    $CAName      = (Get-ItemProperty -Path $CertSvcRoot -ErrorAction Stop).Active
    if ([string]::IsNullOrWhiteSpace($CAName)) { throw "無法從登錄檔取得作用中的 CA 名稱，請確認 CA 已設定完成。" }
    $CAKey = "$CertSvcRoot\$CAName"
    Write-Host "[INFO] CA 名稱：$CAName" -ForegroundColor Gray
    Write-Host ""

    New-Item -Path $Params.CRLPublishPath -ItemType Directory -Force | Out-Null
    $CertEnroll = $Params.CertEnrollPath
    $Publish    = $Params.CRLPublishPath

    # ── Step 1：設定 CDP 延伸模組 ────────────────────────────
    Write-Host "[1/5] 設定 CDP 延伸模組..." -ForegroundColor Yellow
    #
    # CRLPublicationURLs 旗標（CSURL_*，可相加）：
    #    1  = CSURL_SERVERPUBLISH       將「完整 CRL」發布（寫入）到此位置
    #    2  = CSURL_ADDTOCERTCDP        寫入簽發憑證的 CDP 延伸
    #    4  = CSURL_ADDTOFRESHESTCRL    寫入簽發憑證的 Freshest CRL 延伸（指向 Delta CRL）
    #    8  = CSURL_ADDTOCRLCDP         寫入 CRL 本身的 CDP（IDP）延伸
    #   64  = CSURL_SERVERPUBLISHDELTA  將「Delta CRL」發布（寫入）到此位置
    #
    # 本設計：
    #   - 本機兩個目錄：65 = 1+64（完整 CRL + Delta CRL 都發布）
    #   - HTTP URL    ：6  = 2+4 （進入憑證 CDP 與 Freshest CRL，用戶端才找得到 Delta）
    #   - 刻意不含 LDAP CDP：用戶端一律走 HTTP。若需要網域內 LDAP 發布，
    #     可另加 79:ldap:///CN=%7%8,CN=%2,CN=CDP,CN=Public Key Services,CN=Services,%6%10
    #
    # 檔名範本：%3 = CA 名稱、%8 = CRL 名稱尾碼、%9 = Delta 標記（"+"）
    # 【IIS 注意】Delta CRL 檔名含 "+"，IIS 需啟用 allowDoubleEscaping，否則 404。
    #
    $CDPList = @(
        "65:$CertEnroll\%3%8%9.crl",
        "65:$Publish\%3%8%9.crl",
        "6:$($Params.CDPHttpUrl)/%3%8%9.crl"
    )
    Set-CARegistryIfNeeded -Name 'CRLPublicationURLs' -Expected $CDPList -ActionDescription '設定 CDP 延伸模組'
    $CDPList | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }

    # ── Step 2：設定 AIA 延伸模組 ────────────────────────────
    Write-Host ""
    Write-Host "[2/5] 設定 AIA 延伸模組..." -ForegroundColor Yellow
    #
    # CACertPublicationURLs 旗標：
    #    1  = 將 CA 憑證發布（寫入）到此位置
    #    2  = 寫入簽發憑證的 AIA 延伸（CA Issuers）
    #   32  = 寫入簽發憑證的 AIA 延伸（OCSP）— 本設計未使用 OCSP
    # 檔名範本：%1 = 伺服器 DNS 名稱、%3 = CA 名稱、%4 = CA 憑證尾碼
    #
    $AIAList = @(
        "1:$CertEnroll\%1_%3%4.crt",
        "1:$Publish\%1_%3%4.crt",
        "2:$($Params.AIAHttpUrl)/%1_%3%4.crt"
    )
    Set-CARegistryIfNeeded -Name 'CACertPublicationURLs' -Expected $AIAList -ActionDescription '設定 AIA 延伸模組'
    $AIAList | ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }

    # ── Step 3：設定 CRL 更新週期 ────────────────────────────
    Write-Host ""
    Write-Host "[3/5] 設定 CRL 更新週期..." -ForegroundColor Yellow
    Set-CARegistryIfNeeded -Name 'CRLPeriodUnits'      -Expected ([string]$Params.CRLPeriodUnits)      -ActionDescription '設定 CRLPeriodUnits'
    Set-CARegistryIfNeeded -Name 'CRLPeriod'           -Expected ([string]$Params.CRLPeriod)           -ActionDescription '設定 CRLPeriod'
    Set-CARegistryIfNeeded -Name 'CRLOverlapUnits'     -Expected ([string]$Params.CRLOverlapUnits)     -ActionDescription '設定 CRLOverlapUnits'
    Set-CARegistryIfNeeded -Name 'CRLOverlapPeriod'    -Expected ([string]$Params.CRLOverlapPeriod)    -ActionDescription '設定 CRLOverlapPeriod'
    Set-CARegistryIfNeeded -Name 'CRLDeltaPeriodUnits' -Expected ([string]$Params.CRLDeltaPeriodUnits) -ActionDescription '設定 CRLDeltaPeriodUnits'
    Set-CARegistryIfNeeded -Name 'CRLDeltaPeriod'      -Expected ([string]$Params.CRLDeltaPeriod)      -ActionDescription '設定 CRLDeltaPeriod'

    Write-Host "      CRL 有效期  ：$($Params.CRLPeriodUnits) $($Params.CRLPeriod)" -ForegroundColor Gray
    Write-Host "      Delta CRL   ：$($Params.CRLDeltaPeriodUnits) $($Params.CRLDeltaPeriod)" -ForegroundColor Gray
    Write-Host "      重疊緩衝期  ：$($Params.CRLOverlapUnits) $($Params.CRLOverlapPeriod)" -ForegroundColor Gray

    # ── Step 4：設定 CA 簽發憑證的最大有效期 ─────────────────
    Write-Host ""
    Write-Host "[4/5] 設定 CA 憑證最大有效期（$($Params.ValidityPeriodUnits) $($Params.ValidityPeriod)）..." -ForegroundColor Yellow
    Set-CARegistryIfNeeded -Name 'ValidityPeriodUnits' -Expected ([string]$Params.ValidityPeriodUnits) -ActionDescription '設定 ValidityPeriodUnits'
    Set-CARegistryIfNeeded -Name 'ValidityPeriod'      -Expected ([string]$Params.ValidityPeriod)      -ActionDescription '設定 ValidityPeriod'

    # ── Step 5：套用設定並發布 CRL ───────────────────────────
    Write-Host ""
    Write-Host "[5/5] 套用設定並發布 CRL..." -ForegroundColor Yellow
    if ($script:ChangeCount -gt 0) {
        Write-Host "      共 $($script:ChangeCount) 項設定變更，重啟 CertSvc 使其生效..." -ForegroundColor Gray
        Restart-Service CertSvc -Force
        if (-not (Wait-CertSvcReady)) { throw "重啟後 CA 在 60 秒內未回應，請檢查事件檢視器。" }
    } else {
        Write-Host "      [SKIP] 設定無變更，不需重啟 CertSvc。" -ForegroundColor DarkGray
    }

    Invoke-CertutilChecked -Arguments @('-crl') -FailureMessage '立即發布 CRL 失敗' -Quiet
    Write-Host "      [OK] 已執行 certutil -crl" -ForegroundColor Green

    # CA 憑證（AIA 用）：若發布目錄缺少 .crt，從 CertEnroll 補複製
    Get-ChildItem -Path $CertEnroll -Filter '*.crt' -ErrorAction SilentlyContinue | ForEach-Object {
        $Target = Join-Path $Publish $_.Name
        if (-not (Test-Path -LiteralPath $Target)) {
            Copy-Item -LiteralPath $_.FullName -Destination $Target -Force
            Write-Host "      [OK] 已補複製 CA 憑證至發布目錄：$($_.Name)" -ForegroundColor Green
        }
    }

    # ── 驗證 ─────────────────────────────────────────────────
    Write-Host ""
    Write-Host "[驗證] 目前 CA 登錄檔設定：" -ForegroundColor Yellow
    foreach ($Name in 'CRLPublicationURLs','CACertPublicationURLs') {
        Write-Host "  $Name" -ForegroundColor Cyan
        @((Get-ItemProperty -Path $CAKey -Name $Name).$Name) | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
    }

    Write-Host ""
    Write-Host "[驗證] CRL 發布目錄內容：" -ForegroundColor Yellow
    $Files = Get-ChildItem $Params.CRLPublishPath | Select-Object Name, LastWriteTime, Length
    $Files | Format-Table -AutoSize | Out-String | Write-Host

    if ($Params.CRLDeltaPeriodUnits -gt 0 -and -not ($Files | Where-Object { $_.Name -like '*+.crl' })) {
        Write-Host "[WARN] 發布目錄中找不到 Delta CRL（檔名含 '+'）。" -ForegroundColor Yellow
        Write-Host "       Delta CRL 可能需等 CA 實際簽發/撤銷憑證後才會產生；若持續缺少，請檢查 CDP 旗標是否含 64。" -ForegroundColor Yellow
    }
    if (-not ($Files | Where-Object { $_.Name -like '*.crl' -and $_.Name -notlike '*+.crl' -and $_.Name -like "$($CAName -replace '[^\w\-]','*')*" })) {
        Write-Host "[WARN] 發布目錄中找不到本 CA 的完整 CRL，請檢查 certutil -crl 的結果與目錄權限。" -ForegroundColor Yellow
    }
    if (-not ($Files | Where-Object { $_.Name -like '*.crt' })) {
        Write-Host "[WARN] 發布目錄中沒有 CA 憑證（.crt），AIA URL 將無法下載。" -ForegroundColor Yellow
    }

    Write-Host @"

==================================================
  CDP / AIA 設定完成！

  【請務必接著確認】
    1. IIS：http://crl.corp.foo.bar.tw 的 /CRL 與 /AIA 虛擬目錄
       已對應到 $($Params.CRLPublishPath)，且 DNS 已建立。
    2. IIS 需允許 Delta CRL 檔名中的 "+"：
         %windir%\system32\inetsrv\appcmd set config "Default Web Site" ^
           -section:system.webServer/security/requestFiltering ^
           -allowDoubleEscaping:true
    3. 以 pkiview.msc 或下列指令檢查各 URL 是否可被擷取：
         certutil -URL <CA 憑證檔>
    4. 確認 Root CA 簽發的 Sub CA 憑證內 CDP/AIA 網址，
       與離線 Root CA 的 HTTP 發布位置一致且已可連線。

  下一步：執行 04_create_templates.ps1 建立 EAP-TLS 憑證範本
==================================================
"@ -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "        詳細記錄：$LogFile" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
Stop-Transcript | Out-Null
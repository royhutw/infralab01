# ============================================================
#  02_install_subcacert.ps1
#  安裝由離線 Root CA 簽回的 Subordinate CA 憑證
#  執行時機：Root CA 簽回 .crt 憑證後，複製到本機再執行此腳本
#  用法：初次安裝  .\02_install_subcacert.ps1
#        憑證更新  .\02_install_subcacert.ps1 -Renewal   （讀取 SubCA_renewal.crt，見 07）
#
#  需求：以系統管理員身分執行；步驟 4 的 dspublish 需要
#        Enterprise Admins 權限（請以具備該權限的帳號登入執行）
#
#  修正記錄：
#    - Invoke-CertutilChecked 改用 [string[]] 參數陣列傳給 certutil
#      （原版把整串參數當成單一字串，且 \" 在 PowerShell 不是跳脫，
#        導致所有 certutil 呼叫都會失敗）
#    - 移除 Get-PfxCertificate 讀取 .crl 的無效判斷，改用
#      certutil -addstore -f（可重複執行）
#    - 新增前置檢查：簽回憑證的 Issuer 必須等於 Root CA Subject、
#      必須是 CA 憑證、有效期不得超過 Root CA
#    - 等待 CertSvc 真正可回應（certutil -ping）再繼續，不再只看服務狀態
#    - 發布後驗證 Sub CA 憑證確實進入 AD NTAuthCertificates
#    - 檔案比對改用 SHA256 雜湊；加入 Transcript 記錄
# ============================================================
#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param(
    # Sub CA 憑證更新（07 產生新金鑰 CSR 後）：改讀 SubCARenewal.RenewalSignedCertPath，
    # 安裝後重啟 CertSvc 並重新發布 CRL
    [switch] $Renewal
)

#region ── 參數區（統一從 CAConfig.psd1 讀取，請至該檔案修改參數）──
# 本腳本用到的區塊：Global（CRL 發布目錄、記錄目錄）、
# ExchangePaths（Root CA / Sub CA 憑證交換路徑，與 01 共用同一份）、
# SubCARenewal（僅 -Renewal 時使用的簽回憑證路徑）
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
$Params = Merge-CAConfig -Sections 'Global','ExchangePaths','SubCARenewal'
if ($Renewal) { $Params.SignedCertPath = $Params.RenewalSignedCertPath }

# 共用函式 Invoke-CertutilChecked 的縮排與本腳本輸出對齊
$PSDefaultParameterValues['Invoke-CertutilChecked:Indent'] = '      '
#endregion

$ErrorActionPreference = 'Stop'

# ── 記錄檔（PKI 建置建議保留完整執行記錄）─────────────────────
$LogDir = Join-Path $Params.CAConfigDir 'Logs'
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
$LogFile = Join-Path $LogDir ('02_install_subcacert_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
Start-Transcript -Path $LogFile | Out-Null

#region ── 輔助函式 ──────────────────────────────────────────
# Invoke-CertutilChecked / Wait-CertSvcReady 已移至共用的 Import-CAConfig.ps1

function Test-FileSame {
    param([string] $Source, [string] $Target)
    if (-not (Test-Path -LiteralPath $Target)) { return $false }
    return ((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash)
}
#endregion

try {
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  安裝 Subordinate CA 憑證"                        -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  記錄檔：$LogFile" -ForegroundColor Gray
    Write-Host ""

    # ── Step 0：前置檢查 ─────────────────────────────────────
    Write-Host "[0/5] 前置檢查（檔案存在、憑證鏈與有效期）..." -ForegroundColor Yellow

    foreach ($File in @($Params.SignedCertPath, $Params.RootCACertPath, $Params.RootCACRLPath)) {
        if (-not (Test-Path -LiteralPath $File)) { throw "找不到檔案：$File" }
    }

    $RootCert   = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Params.RootCACertPath)
    $SignedCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Params.SignedCertPath)

    if ($SignedCert.Issuer -ne $RootCert.Subject) {
        throw ("簽回憑證的 Issuer 與 Root CA Subject 不符。`n  Issuer ：$($SignedCert.Issuer)`n  Root   ：$($RootCert.Subject)`n" +
               "  請確認 SubCA.crt 是由正確的 Root CA 簽發。")
    }

    $BasicConstraints = $SignedCert.Extensions |
        Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension] }
    if ($null -eq $BasicConstraints -or -not $BasicConstraints.CertificateAuthority) {
        throw "簽回憑證不是 CA 憑證（Basic Constraints: CA=TRUE 缺失）。請檢查 Root CA 簽發時使用的 extension 區段。"
    }

    $Now = Get-Date
    if ($SignedCert.NotAfter -lt $Now) { throw "簽回憑證已過期（NotAfter：$($SignedCert.NotAfter)）。" }
    if ($SignedCert.NotBefore -gt $Now) {
        Write-Host "      [WARN] 簽回憑證尚未生效（NotBefore：$($SignedCert.NotBefore)），請檢查本機與 Root CA 的時間是否一致。" -ForegroundColor Yellow
    }
    if ($SignedCert.NotAfter -gt $RootCert.NotAfter) {
        throw "Sub CA 憑證有效期（$($SignedCert.NotAfter)）超過 Root CA（$($RootCert.NotAfter)），不符合 PKI 規範。"
    }
    Write-Host "      Subject  ：$($SignedCert.Subject)" -ForegroundColor Gray
    Write-Host "      Thumbprint：$($SignedCert.Thumbprint)" -ForegroundColor Gray
    Write-Host "      有效期   ：$($SignedCert.NotBefore.ToString('yyyy-MM-dd')) ~ $($SignedCert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor Gray
    Write-Host "      [OK]" -ForegroundColor Green

    # ── Step 1：確認 Root CA 憑證與 CRL 已在信任存放區 ──────
    # -f 可重複執行：已存在則覆蓋，不會報錯。
    # Root CRL 必須「有效且未過期」，否則下一步 -installcert 會因無法驗證鏈而失敗。
    Write-Host "[1/5] 匯入 Root CA 憑證與 CRL 至信任存放區..." -ForegroundColor Yellow
    Invoke-CertutilChecked -Arguments @('-addstore','-f','Root',$Params.RootCACertPath) `
        -SuccessMessage 'Root CA 憑證已在 Root 信任存放區' -FailureMessage 'Root CA 憑證加入信任存放區失敗'
    Invoke-CertutilChecked -Arguments @('-addstore','-f','Root',$Params.RootCACRLPath) `
        -SuccessMessage 'Root CA CRL 已加入' -FailureMessage 'Root CA CRL 加入失敗（請確認 CRL 檔案有效且未過期）'

    # ── Step 2：安裝簽回的 Sub CA 憑證 ──────────────────────
    Write-Host "[2/5] 安裝 Subordinate CA 憑證..." -ForegroundColor Yellow
    $InstalledCert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Thumbprint -eq $SignedCert.Thumbprint -and $_.HasPrivateKey }
    $NewlyInstalled = $false
    if ($null -ne $InstalledCert) {
        Write-Host "      [SKIP] Subordinate CA 憑證已安裝（含私鑰），跳過重複安裝" -ForegroundColor DarkGray
    } else {
        # certutil -installcert 會將憑證與 01（或 07 -renewcert）產生的 CA 私鑰配對
        Invoke-CertutilChecked -Arguments @('-installcert',$Params.SignedCertPath) `
            -SuccessMessage 'Subordinate CA 憑證安裝成功' `
            -FailureMessage '憑證安裝失敗！請確認：(1) 憑證與本機 CSR 金鑰相符 (2) Root CA CRL 未過期 (3) 01（或 07）已完成'
        $NewlyInstalled = $true
    }

    # ── Step 3：啟動 CA 服務並等待就緒 ──────────────────────
    Write-Host "[3/5] 啟動 CertSvc（AD CS 服務）..." -ForegroundColor Yellow
    $CertSvc = Get-Service -Name 'CertSvc' -ErrorAction SilentlyContinue
    if ($null -eq $CertSvc) { throw "找不到 CertSvc 服務，請確認此機器已安裝 AD CS。" }

    Set-Service -Name 'CertSvc' -StartupType Automatic
    if ($CertSvc.Status -ne 'Running') {
        Start-Service -Name 'CertSvc'
        Write-Host "      [OK] CertSvc 已啟動" -ForegroundColor Green
    } elseif ($NewlyInstalled) {
        # 更新情境：CA 一直在執行中，需重啟才會改用新憑證
        Restart-Service -Name 'CertSvc' -Force
        Write-Host "      [OK] CertSvc 已重啟（載入新的 CA 憑證）" -ForegroundColor Green
    } else {
        Write-Host "      [SKIP] CertSvc 已在執行中" -ForegroundColor DarkGray
    }

    if (-not (Wait-CertSvcReady)) {
        throw "CertSvc 已啟動但 CA 在 60 秒內仍未回應 certutil -ping，請檢查事件檢視器（Application / CertificationAuthority）。"
    }
    Write-Host "      [OK] CA 已就緒（certutil -ping 成功）" -ForegroundColor Green

    if ($Renewal) {
        # 以新金鑰簽署並發布新的 CRL（檔名含金鑰索引，如 <CA名稱>(1).crl）
        Invoke-CertutilChecked -Arguments @('-crl') -SuccessMessage '已發布新金鑰簽署的 CRL' -FailureMessage 'CRL 發布失敗'
    }

    # ── Step 4：發布憑證至 AD DS 並驗證 NTAuth ──────────────
    Write-Host "[4/5] 發布憑證至 AD（需要 Enterprise Admins 權限）..." -ForegroundColor Yellow
    # RootCA：發布至 Certification Authorities 容器（讓網域成員信任 Root）
    Invoke-CertutilChecked -Arguments @('-dspublish','-f',$Params.RootCACertPath,'RootCA') `
        -SuccessMessage 'Root CA 憑證已發布至 AD（Certification Authorities 容器）' `
        -FailureMessage 'Root CA 憑證發布至 AD 失敗（請確認登入帳號為 Enterprise Admins）'
    # SubCA：發布至 AIA 容器
    Invoke-CertutilChecked -Arguments @('-dspublish','-f',$Params.SignedCertPath,'SubCA') `
        -SuccessMessage 'Sub CA 憑證已發布至 AD（AIA 容器）' `
        -FailureMessage 'Sub CA 憑證發布至 AD 失敗'

    # NTAuthCertificates：Enterprise CA 安裝時通常會自動加入，但若安裝帳號
    # 權限不足會「靜默略過」，因此這裡主動驗證，缺少時補發布。
    # 注意：使用 -enterprise -store 輸出文字；-viewstore 會跳出 GUI 視窗。
    $NTAuthText = (& certutil -enterprise -store NTAuth 2>&1 | Out-String) -replace '\s',''
    if ($NTAuthText -match $SignedCert.Thumbprint) {
        Write-Host "      [OK] Sub CA 憑證已存在於 NTAuthCertificates" -ForegroundColor Green
    } else {
        Write-Host "      [WARN] NTAuthCertificates 中找不到 Sub CA 憑證，補發布..." -ForegroundColor Yellow
        Invoke-CertutilChecked -Arguments @('-dspublish','-f',$Params.SignedCertPath,'NTAuthCA') `
            -SuccessMessage 'Sub CA 憑證已發布至 NTAuthCertificates' `
            -FailureMessage '發布至 NTAuthCertificates 失敗'
    }

    # ── Step 5：將 Root CA 憑證 / CRL 複製到 CRL 發布目錄 ───
    Write-Host "[5/5] 複製 Root CA 憑證與 CRL 到發布目錄..." -ForegroundColor Yellow
    New-Item -Path $Params.CRLPublishPath -ItemType Directory -Force | Out-Null
    foreach ($Source in @($Params.RootCACRLPath, $Params.RootCACertPath)) {
        $Target = Join-Path $Params.CRLPublishPath (Split-Path $Source -Leaf)
        if (Test-FileSame -Source $Source -Target $Target) {
            Write-Host "      [SKIP] 已是最新：$Target" -ForegroundColor DarkGray
        } else {
            Copy-Item -LiteralPath $Source -Destination $Target -Force
            Write-Host "      [OK] 已複製：$Target" -ForegroundColor Green
        }
    }

    # ── 驗證 ─────────────────────────────────────────────────
    Write-Host ""
    Write-Host "[驗證] CA 服務狀態：" -ForegroundColor Yellow
    Get-Service -Name 'CertSvc' | Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-String | Write-Host

    $ActiveCA = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration' -ErrorAction SilentlyContinue).Active
    Write-Host "[驗證] 作用中的 CA 名稱：$ActiveCA" -ForegroundColor Yellow

    Write-Host @"

==================================================
  Subordinate CA 憑證安裝完成！
  下一步：執行 03_configure_cdp_aia.ps1 設定 CDP/AIA
  （注意：請務必在簽發任何憑證之前完成 03，
    否則已簽發憑證內的 CDP/AIA 無法事後更正）
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
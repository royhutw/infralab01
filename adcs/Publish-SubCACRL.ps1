# ============================================================
#  Publish-SubCACRL.ps1
#  Subordinate CA CRL 定期發布腳本
#  執行方式：Windows Task Scheduler 每週定時執行
#
#  功能：
#    1. 確認 CertSvc 服務運作中
#    2. 產生新的 CRL 與 Delta CRL
#    3. 複製 CRL 到 IIS 發布目錄
#    4. 記錄執行結果至 Log 檔案
# ============================================================

#region ── 參數區（請依實際環境修改） ────────────────────────
$Params = @{
    # ── CRL 發布目錄（需與 03_configure_cdp_aia.ps1 一致）──
    CRLPublishPath  = 'C:\CRLPublish'

    # ── Log 檔案路徑 ─────────────────────────────────────────
    LogPath         = 'C:\CAConfig\Logs\CRL_Publish.log'

    # ── Log 保留天數（超過此天數的 Log 自動清除）────────────
    LogRetentionDays = 90

    # ── CRL 來源目錄（CA 預設輸出位置）──────────────────────
    CertEnrollPath  = 'C:\Windows\System32\CertSrv\CertEnroll'

    # ── 警告閾值：CRL 到期前幾天發出警告 ────────────────────
    CRLExpiryWarningDays = 3
}
#endregion

# ── 初始化 Log ────────────────────────────────────────────────
$LogDir = Split-Path $Params.LogPath -Parent
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null

function Write-Log {
    param(
        [string] $Message,
        [string] $Level = 'INFO'   # INFO / WARN / ERROR / OK
    )
    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $LogEntry  = "[$Timestamp] [$Level] $Message"

    # 輸出至 Console
    $Color = switch ($Level) {
        'OK'    { 'Green'  }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red'    }
        default { 'Gray'   }
    }
    Write-Host $LogEntry -ForegroundColor $Color

    # 寫入 Log 檔案
    Add-Content -Path $Params.LogPath -Value $LogEntry -Encoding UTF8
}

# ── 執行開始 ─────────────────────────────────────────────────
Write-Log "========================================" 'INFO'
Write-Log "Subordinate CA CRL 定期發布作業開始" 'INFO'
Write-Log "========================================" 'INFO'

$ErrorCount = 0

try {
    # ── Step 1：確認 CertSvc 服務狀態 ────────────────────────
    Write-Log "Step 1：確認 CertSvc 服務狀態..."

    $Svc = Get-Service -Name 'CertSvc' -ErrorAction Stop
    if ($Svc.Status -ne 'Running') {
        Write-Log "CertSvc 未執行，嘗試啟動..." 'WARN'
        Start-Service -Name 'CertSvc' -ErrorAction Stop
        Start-Sleep -Seconds 5

        $Svc = Get-Service -Name 'CertSvc'
        if ($Svc.Status -ne 'Running') {
            Write-Log "CertSvc 啟動失敗，作業中止！" 'ERROR'
            exit 1
        }
    }
    Write-Log "CertSvc 服務運作正常。" 'OK'

    # ── Step 2：取得 CA Config ────────────────────────────────
    Write-Log "Step 2：取得 CA 設定..."

    $CAConfig = (certutil -getconfig) |
        Where-Object { $_ -match '"(.+\\.+)"' } |
        ForEach-Object { $_ -replace '.*"(.+)".*', '$1' } |
        Select-Object -First 1
    $CAConfig = $CAConfig.Trim()

    if ([string]::IsNullOrWhiteSpace($CAConfig)) {
        Write-Log "無法取得 CA Config！" 'ERROR'
        exit 1
    }
    Write-Log "CA Config：$CAConfig" 'OK'

    # ── Step 3：確認目前 CRL 到期狀態 ────────────────────────
    Write-Log "Step 3：確認目前 CRL 到期狀態..."

    $CRLFiles = Get-ChildItem -Path $Params.CRLPublishPath `
        -Filter '*.crl' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'rootCA*' -and $_.Name -notlike 'RootCA*' }

    foreach ($CRLFile in $CRLFiles) {
        try {
            $CRL        = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
                              $CRLFile.FullName)
            # 注意：X509Certificate2 無法直接解析 CRL，
            # 改用 certutil 取得到期時間
            $CertutilOut = certutil -dump $CRLFile.FullName 2>$null |
                Select-String 'Next Update'
            Write-Log "目前 CRL：$($CRLFile.Name)（$CertutilOut）"
        }
        catch {
            Write-Log "無法讀取 CRL 檔案：$($CRLFile.Name)" 'WARN'
        }
    }

    # ── Step 4：產生新的 CRL 與 Delta CRL ────────────────────
    Write-Log "Step 4：產生新的 CRL..."

    # certutil -crl：立即產生並發布新 CRL 與 Delta CRL
    # 執行後 CA 會將新 CRL 輸出至 CertEnroll 目錄
    $CRLResult = certutil -config $CAConfig -crl 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "CRL 產生成功。" 'OK'
    } else {
        Write-Log "CRL 產生失敗：$CRLResult" 'ERROR'
        $ErrorCount++
    }

    # ── Step 5：複製 CRL 到發布目錄 ──────────────────────────
    Write-Log "Step 5：複製 CRL 到發布目錄：$($Params.CRLPublishPath)..."

    # 複製所有 .crl 檔案（排除 RootCA.crl）
    $NewCRLFiles = Get-ChildItem -Path $Params.CertEnrollPath -Filter '*.crl' |
        Where-Object { $_.Name -notlike 'RootCA*' -and $_.Name -notlike 'rootCA*' }

    foreach ($File in $NewCRLFiles) {
        $Dest = Join-Path $Params.CRLPublishPath $File.Name
        Copy-Item -Path $File.FullName -Destination $Dest -Force
        Write-Log "已複製：$($File.Name)（$($File.Length) bytes）" 'OK'
    }

    # 同時複製 .crt（AIA 用）
    $NewCRTFiles = Get-ChildItem -Path $Params.CertEnrollPath -Filter '*.crt' |
        Where-Object { $_.Name -notlike 'RootCA*' -and $_.Name -notlike 'rootCA*' }

    foreach ($File in $NewCRTFiles) {
        $Dest = Join-Path $Params.CRLPublishPath $File.Name
        Copy-Item -Path $File.FullName -Destination $Dest -Force
        Write-Log "已複製：$($File.Name)（$($File.Length) bytes）" 'OK'
    }

    # ── Step 6：驗證發布目錄內容 ─────────────────────────────
    Write-Log "Step 6：驗證發布目錄..."

    $PublishedFiles = Get-ChildItem -Path $Params.CRLPublishPath
    foreach ($File in $PublishedFiles) {
        Write-Log "  $($File.Name) | $($File.LastWriteTime) | $($File.Length) bytes"
    }

    # ── Step 7：確認新 CRL 到期時間 ──────────────────────────
    Write-Log "Step 7：確認新 CRL 到期時間..."

    $PublishedCRLs = Get-ChildItem -Path $Params.CRLPublishPath -Filter '*.crl' |
        Where-Object { $_.Name -notlike 'RootCA*' -and $_.Name -notlike 'rootCA*' }

    foreach ($CRLFile in $PublishedCRLs) {
        $CertutilDump = certutil -dump $CRLFile.FullName 2>$null
        $NextUpdate   = $CertutilDump | Select-String 'Next Update' |
            Select-Object -First 1
        $ThisUpdate   = $CertutilDump | Select-String 'This Update' |
            Select-Object -First 1
        Write-Log "[$($CRLFile.Name)]" 'OK'
        Write-Log "  $ThisUpdate"
        Write-Log "  $NextUpdate"
    }

}
catch {
    Write-Log "未預期的錯誤：$($_.Exception.Message)" 'ERROR'
    $ErrorCount++
}
finally {
    # ── Step 8：清理舊 Log 檔案 ──────────────────────────────
    Write-Log "Step 8：清理 $($Params.LogRetentionDays) 天前的 Log..."

    $OldLogs = Get-ChildItem -Path $LogDir -Filter '*.log' |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$Params.LogRetentionDays) }

    foreach ($OldLog in $OldLogs) {
        Remove-Item $OldLog.FullName -Force
        Write-Log "已清除舊 Log：$($OldLog.Name)"
    }

    # ── 執行結果總結 ─────────────────────────────────────────
    Write-Log "========================================" 'INFO'
    if ($ErrorCount -eq 0) {
        Write-Log "CRL 發布作業完成，無錯誤。" 'OK'
    } else {
        Write-Log "CRL 發布作業完成，發生 $ErrorCount 個錯誤，請檢查 Log！" 'ERROR'
    }
    Write-Log "========================================" 'INFO'
}
# ============================================================
#  Publish-SubCACRL.ps1
#  Subordinate CA CRL 定期發布腳本
#  執行方式：Windows Task Scheduler 每週定時執行
#
#  功能：
#    1. 確認 CertSvc 服務運作中
#    2. 產生新的 CRL 與 Delta CRL
#    3. 複製 CRL 到 IIS 發布目錄
#    4. 完整 CRL 剩餘天數低於 CRLExpiryWarningDays 時記錄 ERROR 並以非 0 結束碼結束
#    5. 記錄執行結果至 Log 檔案（任何錯誤皆以結束碼 1 回報給 Task Scheduler）
#
#  部署注意：本腳本需與 Import-CAConfig.ps1、CAConfig.psd1 放在同一目錄
#           （Register-CRLScheduledTask.ps1 會檢查）。
# ============================================================
#requires -Version 5.1

#region ── 參數區（統一從 CAConfig.psd1 讀取，請至該檔案修改參數）──
# 本腳本用到的區塊：Global（CRL 發布目錄，與 03 腳本共用同一份，
# 不會出現兩邊各自維護、彼此不一致的情況）、
# CRLPublish（Log 路徑/保留天數/CRL來源目錄）
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
$Params = Merge-CAConfig -Sections 'Global','CRLPublish'
#endregion

# ── 初始化 Log ────────────────────────────────────────────────
$LogDir = Split-Path $Params.LogPath -Parent
New-Item -Path $LogDir -ItemType Directory -Force | Out-Null

# Log 超過 5 MB 時輪替（舊檔由 Step 8 依保留天數清理）
if ((Test-Path -LiteralPath $Params.LogPath) -and (Get-Item -LiteralPath $Params.LogPath).Length -gt 5MB) {
    $RotatedName = '{0}_{1:yyyyMMdd_HHmmss}{2}' -f [IO.Path]::GetFileNameWithoutExtension($Params.LogPath), (Get-Date), [IO.Path]::GetExtension($Params.LogPath)
    Rename-Item -LiteralPath $Params.LogPath -NewName $RotatedName
}

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
            $ErrorCount++
            exit 1
        }
    }
    Write-Log "CertSvc 服務運作正常。" 'OK'

    # ── Step 2：取得 CA Config ────────────────────────────────
    Write-Log "Step 2：取得 CA 設定..."

    $CAConfig = Get-LocalCAConfigString
    Write-Log "CA Config：$CAConfig" 'OK'

    # ── Step 3：記錄目前 CRL 狀態（發布前）──────────────────
    Write-Log "Step 3：確認目前 CRL 狀態..."

    $CRLFiles = Get-ChildItem -Path $Params.CRLPublishPath `
        -Filter '*.crl' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'RootCA*' }

    foreach ($CRLFile in $CRLFiles) {
        Write-Log "目前 CRL：$($CRLFile.Name)（最後寫入 $($CRLFile.LastWriteTime)）"
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

    # ── Step 7：確認新 CRL 到期時間，並在剩餘天數不足時警示 ──
    Write-Log "Step 7：確認新 CRL 到期時間..."

    $PublishedCRLs = Get-ChildItem -Path $Params.CRLPublishPath -Filter '*.crl' |
        Where-Object { $_.Name -notlike 'RootCA*' }

    foreach ($CRLFile in $PublishedCRLs) {
        $CertutilDump = certutil -dump $CRLFile.FullName 2>$null
        $NextUpdateLine = $CertutilDump | Select-String -Pattern '^\s*(NextUpdate|Next Update|下次更新)\s*:' |
            Select-Object -First 1
        $ThisUpdateLine = $CertutilDump | Select-String -Pattern '^\s*(ThisUpdate|This Update|此次更新)\s*:' |
            Select-Object -First 1
        Write-Log "[$($CRLFile.Name)]" 'OK'
        if ($ThisUpdateLine) { Write-Log "  $($ThisUpdateLine.Line.Trim())" }
        if ($NextUpdateLine) { Write-Log "  $($NextUpdateLine.Line.Trim())" }

        # Delta CRL（檔名含 '+'）週期短，只對完整 CRL 做到期警示
        if ($CRLFile.Name -like '*+.crl' -or -not $NextUpdateLine) { continue }
        $NextUpdate = [datetime]::MinValue
        $RawValue   = ($NextUpdateLine.Line -split ':', 2)[1].Trim()
        if ([datetime]::TryParse($RawValue, [ref]$NextUpdate)) {
            $DaysLeft = ($NextUpdate - (Get-Date)).TotalDays
            if ($DaysLeft -lt $Params.CRLExpiryWarningDays) {
                Write-Log "$($CRLFile.Name) 將於 $([math]::Round($DaysLeft, 1)) 天後到期（警示門檻 $($Params.CRLExpiryWarningDays) 天）！" 'ERROR'
                $ErrorCount++
            }
        } else {
            Write-Log "無法解析 $($CRLFile.Name) 的 Next Update（'$RawValue'），略過到期警示。" 'WARN'
        }
    }

}
catch {
    Write-Log "未預期的錯誤：$($_.Exception.Message)" 'ERROR'
    $ErrorCount++
}
finally {
    # ── Step 8：清理舊 Log 檔案（僅限本腳本的 CRL_Publish*.log，不動 01～08 的安裝記錄）──
    Write-Log "Step 8：清理 $($Params.LogRetentionDays) 天前的 CRL 發布 Log..."

    $LogLeafBase = [IO.Path]::GetFileNameWithoutExtension($Params.LogPath)
    $OldLogs = Get-ChildItem -Path $LogDir -Filter "$LogLeafBase*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $Params.LogPath -and $_.LastWriteTime -lt (Get-Date).AddDays(-$Params.LogRetentionDays) }

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

# 非 0 結束碼讓 Task Scheduler 的「上次執行結果」能反映失敗
if ($ErrorCount -gt 0) { exit 1 }
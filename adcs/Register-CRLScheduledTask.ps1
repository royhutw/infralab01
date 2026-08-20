# ============================================================
#  Register-CRLScheduledTask.ps1
#  建立 Windows Task Scheduler 排程，每週定時執行 CRL 發布
#  執行地點：AD CS 伺服器
#  執行身份：SYSTEM（具備 CA 管理權限）
# ============================================================

#region ── 參數區（請依實際環境修改） ────────────────────────
$TaskParams = @{
    # ── 排程工作名稱 ─────────────────────────────────────────
    TaskName        = 'PKI - Publish Subordinate CA CRL'
    TaskDescription = '每週定時發布 Subordinate CA CRL，確保憑證撤銷清單持續有效'
    TaskPath        = '\PKI\'          # Task Scheduler 資料夾路徑

    # ── 腳本路徑 ─────────────────────────────────────────────
    ScriptPath      = 'C:\CAConfig\Publish-SubCACRL.ps1'

    # ── 排程設定 ─────────────────────────────────────────────
    # 每週一 上午 02:00 執行（避開業務時段）
    # CRL 有效期為 1 週，每週更新確保不過期
    TriggerDay      = 'Monday'
    TriggerTime     = '02:00'

    # ── 執行身份（SYSTEM 帳號具備 CA 管理權限）─────────────
    RunAsUser       = 'SYSTEM'
}
#endregion

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  建立 CRL 定期發布排程工作"                        -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

# ── 確認腳本檔案存在 ─────────────────────────────────────────
if (-not (Test-Path $TaskParams.ScriptPath)) {
    Write-Host "[ERROR] 找不到腳本：$($TaskParams.ScriptPath)" -ForegroundColor Red
    Write-Host "        請先將 Publish-SubCACRL.ps1 複製到指定路徑。" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] 腳本檔案確認：$($TaskParams.ScriptPath)" -ForegroundColor Green

# ── 建立 Task Scheduler 資料夾 ───────────────────────────────
$Scheduler = New-Object -ComObject Schedule.Service
$Scheduler.Connect()
$RootFolder = $Scheduler.GetFolder('\')

try {
    $RootFolder.GetFolder($TaskParams.TaskPath) | Out-Null
    Write-Host "[OK] 排程資料夾已存在：$($TaskParams.TaskPath)" -ForegroundColor Green
}
catch {
    $RootFolder.CreateFolder($TaskParams.TaskPath) | Out-Null
    Write-Host "[OK] 已建立排程資料夾：$($TaskParams.TaskPath)" -ForegroundColor Green
}

# ── 移除既有排程（若存在）───────────────────────────────────
$ExistingTask = Get-ScheduledTask -TaskName $TaskParams.TaskName `
    -TaskPath $TaskParams.TaskPath -ErrorAction SilentlyContinue
if ($ExistingTask) {
    Unregister-ScheduledTask -TaskName $TaskParams.TaskName `
        -TaskPath $TaskParams.TaskPath -Confirm:$false
    Write-Host "[INFO] 已移除既有排程，重新建立。" -ForegroundColor Yellow
}

# ── 設定執行動作 ─────────────────────────────────────────────
# 使用 PowerShell 執行腳本
# -NonInteractive：不需要使用者互動
# -ExecutionPolicy Bypass：確保腳本可以執行
# -File：指定腳本路徑
$Action = New-ScheduledTaskAction `
    -Execute    'PowerShell.exe' `
    -Argument   "-NonInteractive -ExecutionPolicy Bypass -File `"$($TaskParams.ScriptPath)`""

# ── 設定觸發條件 ─────────────────────────────────────────────
# 每週固定日期時間執行
$Trigger = New-ScheduledTaskTrigger `
    -Weekly `
    -DaysOfWeek $TaskParams.TriggerDay `
    -At         $TaskParams.TriggerTime

# ── 設定排程工作選項 ─────────────────────────────────────────
$Settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit     (New-TimeSpan -Minutes 30) `  # 最長執行 30 分鐘
    -RestartCount           3 `                            # 失敗時最多重試 3 次
    -RestartInterval        (New-TimeSpan -Minutes 5) `   # 重試間隔 5 分鐘
    -StartWhenAvailable     $true `                        # 錯過時間時盡快執行
    -RunOnlyIfNetworkAvailable $false `                    # 不需要網路連線（本機 CA）
    -MultipleInstances      IgnoreNew                      # 若已在執行則忽略新觸發

# ── 設定執行主體 ─────────────────────────────────────────────
$Principal = New-ScheduledTaskPrincipal `
    -UserId    $TaskParams.RunAsUser `
    -RunLevel  Highest `              # 以最高權限執行
    -LogonType ServiceAccount         # 以服務帳號方式登入

# ── 建立排程工作 ─────────────────────────────────────────────
$Task = New-ScheduledTask `
    -Action      $Action `
    -Trigger     $Trigger `
    -Settings    $Settings `
    -Principal   $Principal `
    -Description $TaskParams.TaskDescription

Register-ScheduledTask `
    -TaskName $TaskParams.TaskName `
    -TaskPath $TaskParams.TaskPath `
    -InputObject $Task | Out-Null

Write-Host "[OK] 排程工作已建立：$($TaskParams.TaskPath)$($TaskParams.TaskName)" -ForegroundColor Green

# ── 驗證排程工作 ─────────────────────────────────────────────
Write-Host ""
Write-Host "[驗證] 排程工作設定：" -ForegroundColor Yellow
$RegisteredTask = Get-ScheduledTask `
    -TaskName $TaskParams.TaskName `
    -TaskPath $TaskParams.TaskPath

Write-Host "  工作名稱 ：$($RegisteredTask.TaskName)"
Write-Host "  執行路徑 ：$($RegisteredTask.TaskPath)"
Write-Host "  執行身份 ：$($RegisteredTask.Principal.UserId)"
Write-Host "  執行動作 ：$($RegisteredTask.Actions.Execute) $($RegisteredTask.Actions.Arguments)"
Write-Host "  觸發條件 ：每週 $($TaskParams.TriggerDay) $($TaskParams.TriggerTime)"
Write-Host "  工作狀態 ：$($RegisteredTask.State)"

# ── 立即測試執行一次 ─────────────────────────────────────────
Write-Host ""
$TestRun = Read-Host "是否立即測試執行一次？(Y/N)"
if ($TestRun -eq 'Y') {
    Write-Host "[測試] 立即執行排程工作..." -ForegroundColor Yellow
    Start-ScheduledTask -TaskName $TaskParams.TaskName -TaskPath $TaskParams.TaskPath

    # 等待執行完成
    Start-Sleep -Seconds 10
    $TaskInfo = Get-ScheduledTaskInfo `
        -TaskName $TaskParams.TaskName `
        -TaskPath $TaskParams.TaskPath

    Write-Host "  上次執行時間   ：$($TaskInfo.LastRunTime)"
    Write-Host "  上次執行結果   ：$($TaskInfo.LastTaskResult)"
    Write-Host "  下次排程時間   ：$($TaskInfo.NextRunTime)"

    if ($TaskInfo.LastTaskResult -eq 0) {
        Write-Host "  [OK] 測試執行成功！" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] 執行結果代碼：$($TaskInfo.LastTaskResult)，請查看 Log。" -ForegroundColor Yellow
        Write-Host "         Log 路徑：C:\CAConfig\Logs\CRL_Publish.log" -ForegroundColor Yellow
    }
}

Write-Host @"

==================================================
  CRL 定期發布排程工作建立完成！

  排程設定：
    執行時間 ：每週 $($TaskParams.TriggerDay) $($TaskParams.TriggerTime)
    執行腳本 ：$($TaskParams.ScriptPath)
    執行身份 ：$($TaskParams.RunAsUser)
    Log 位置 ：C:\CAConfig\Logs\CRL_Publish.log

  手動執行方式：
    Start-ScheduledTask -TaskName '$($TaskParams.TaskName)' ``
        -TaskPath '$($TaskParams.TaskPath)'

  查看 Log：
    Get-Content 'C:\CAConfig\Logs\CRL_Publish.log' -Tail 50

  注意事項：
    CRL 有效期設定為 1 週，排程為每週一執行
    若 CA 服務停止，排程會嘗試自動啟動服務
    建議同時設定 CertSvc 服務為自動啟動
==================================================
"@ -ForegroundColor Green
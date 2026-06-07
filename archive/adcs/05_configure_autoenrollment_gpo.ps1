# ============================================================
#  05_configure_autoenrollment_gpo.ps1
#  建立並設定 GPO 啟用 802.1x EAP-TLS 憑證 Auto-Enrollment
#
#  建立兩個 GPO：
#    GPO-1（電腦設定）：套用至 Domain Computers OU
#      → 啟用電腦 Auto-Enrollment，自動申請 EAP-TLS Computer 憑證
#    GPO-2（使用者設定）：套用至 Domain Users OU 或 Domain 根層級
#      → 啟用使用者 Auto-Enrollment，自動申請 EAP-TLS User 憑證
#
#  Auto-Enrollment 原理：
#    GPO 啟用後，用戶端電腦在群組原則更新時（每 90 分鐘 + 隨機
#    延遲，或 gpupdate /force）會自動向 CA 申請符合範本條件的憑證。
# ============================================================

#region ── 參數區 ────────────────────────────────────────────
$Params = @{
    DomainName      = 'corp.foo.bar.tw'
    DomainDN        = 'DC=corp,DC=foo,DC=bar,DC=tw'

    # ── GPO 名稱 ─────────────────────────────────────────────
    ComputerGPOName = 'PKI - EAP-TLS Computer Auto-Enrollment'
    UserGPOName     = 'PKI - EAP-TLS User Auto-Enrollment'

    # ── 套用 OU（電腦 GPO 套用至整個網域，涵蓋所有電腦） ───
    ComputerGPOTarget = 'DC=corp,DC=foo,DC=bar,DC=tw'  # 網域根層級（含所有子 OU）
    UserGPOTarget     = 'DC=corp,DC=foo,DC=bar,DC=tw'  # 網域根層級（含所有使用者）
}
#endregion

Import-Module GroupPolicy -ErrorAction Stop

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  設定 Auto-Enrollment GPO"                         -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan

# ════════════════════════════════════════════════════════════
#  GPO-1：電腦 Auto-Enrollment
# ════════════════════════════════════════════════════════════
#
#  登錄路徑：
#    HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment
#    值名稱：AEPolicy（DWORD）
#
#  AEPolicy 旗標說明：
#    0 = 停用 Auto-Enrollment
#    1 = 啟用 Auto-Enrollment（僅自動申請）
#    7 = 啟用 Auto-Enrollment + 自動更新 + 移除已撤銷憑證（建議值）
#      = 0x1（啟用）| 0x2（更新到期憑證）| 0x4（移除撤銷/到期憑證）
#
Write-Host ""
Write-Host "[1/2] 建立電腦 Auto-Enrollment GPO..." -ForegroundColor Yellow

$CompGPO = Get-GPO -Name $Params.ComputerGPOName -Domain $Params.DomainName -ErrorAction SilentlyContinue
if ($null -eq $CompGPO) {
    $CompGPO = New-GPO -Name $Params.ComputerGPOName `
                        -Comment '啟用 EAP-TLS 電腦憑證自動申請與更新' `
                        -Domain $Params.DomainName
    Write-Host "      [OK] GPO 已建立：$($Params.ComputerGPOName)" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] GPO 已存在，將更新設定值。" -ForegroundColor Yellow
}

# 設定電腦 Auto-Enrollment 登錄值
# AEPolicy = 7：啟用 + 自動更新 + 移除已撤銷/到期憑證
Set-GPRegistryValue -Name $Params.ComputerGPOName `
    -Key       'HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment' `
    -ValueName 'AEPolicy' `
    -Type      DWord `
    -Value     7 | Out-Null

Write-Host "      [OK] 電腦 AEPolicy = 7（啟用 + 自動更新 + 清理）" -ForegroundColor Green

# 連結 GPO 至網域根層級
$ExistingCompLink = Get-GPInheritance -Target $Params.ComputerGPOTarget -Domain $Params.DomainName |
    Select-Object -ExpandProperty GpoLinks |
    Where-Object { $_.DisplayName -eq $Params.ComputerGPOName }

if ($null -eq $ExistingCompLink) {
    New-GPLink -Guid    $CompGPO.Id `
               -Target  $Params.ComputerGPOTarget `
               -Domain  $Params.DomainName `
               -LinkEnabled Yes | Out-Null
    Write-Host "      [OK] GPO 已連結至：$($Params.ComputerGPOTarget)" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] GPO 連結已存在。" -ForegroundColor Yellow
}

# ════════════════════════════════════════════════════════════
#  GPO-2：使用者 Auto-Enrollment
# ════════════════════════════════════════════════════════════
#
#  登錄路徑：
#    HKCU\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment
#    值名稱：AEPolicy（DWORD）
#
#  注意：使用者 Auto-Enrollment 寫入 HKCU（使用者機碼），
#        需套用在「使用者設定」而非「電腦設定」，因此需要
#        獨立的 GPO 或在同一 GPO 的使用者設定區設定。
#
Write-Host ""
Write-Host "[2/2] 建立使用者 Auto-Enrollment GPO..." -ForegroundColor Yellow

$UserGPO = Get-GPO -Name $Params.UserGPOName -Domain $Params.DomainName -ErrorAction SilentlyContinue
if ($null -eq $UserGPO) {
    $UserGPO = New-GPO -Name $Params.UserGPOName `
                        -Comment '啟用 EAP-TLS 使用者憑證自動申請與更新' `
                        -Domain $Params.DomainName
    Write-Host "      [OK] GPO 已建立：$($Params.UserGPOName)" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] GPO 已存在，將更新設定值。" -ForegroundColor Yellow
}

# 設定使用者 Auto-Enrollment 登錄值（HKCU）
Set-GPRegistryValue -Name $Params.UserGPOName `
    -Key       'HKCU\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment' `
    -ValueName 'AEPolicy' `
    -Type      DWord `
    -Value     7 | Out-Null

Write-Host "      [OK] 使用者 AEPolicy = 7（啟用 + 自動更新 + 清理）" -ForegroundColor Green

# 連結 GPO 至網域根層級
$ExistingUserLink = Get-GPInheritance -Target $Params.UserGPOTarget -Domain $Params.DomainName |
    Select-Object -ExpandProperty GpoLinks |
    Where-Object { $_.DisplayName -eq $Params.UserGPOName }

if ($null -eq $ExistingUserLink) {
    New-GPLink -Guid    $UserGPO.Id `
               -Target  $Params.UserGPOTarget `
               -Domain  $Params.DomainName `
               -LinkEnabled Yes | Out-Null
    Write-Host "      [OK] GPO 已連結至：$($Params.UserGPOTarget)" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] GPO 連結已存在。" -ForegroundColor Yellow
}

# ── 產生 GPO 報告（HTML）────────────────────────────────────
Write-Host ""
Write-Host "[報告] 產生 GPO 設定報告..." -ForegroundColor Yellow
Get-GPOReport -Name $Params.ComputerGPOName -ReportType Html -Path '.\GPO_Computer_AutoEnroll.html' -Domain $Params.DomainName
Get-GPOReport -Name $Params.UserGPOName     -ReportType Html -Path '.\GPO_User_AutoEnroll.html'     -Domain $Params.DomainName
Write-Host "      [OK] 報告已輸出至目前目錄" -ForegroundColor Green

Write-Host @"

==================================================
  Auto-Enrollment GPO 設定完成！

  GPO 摘要：
    電腦 GPO：$($Params.ComputerGPOName)
      AEPolicy = 7（啟用 + 自動更新 + 清理）
      套用對象：所有加入網域的電腦
      憑證範本：EAP-TLS-Computer（1年，自動核准）

    使用者 GPO：$($Params.UserGPOName)
      AEPolicy = 7（啟用 + 自動更新 + 清理）
      套用對象：所有網域使用者
      憑證範本：EAP-TLS-User（2年，自動核准）

  驗證步驟：
    1. 在用戶端執行 gpupdate /force
    2. 在用戶端執行 certlm.msc（電腦憑證）
       確認 Personal\Certificates 中出現 EAP-TLS Computer 憑證
    3. 在用戶端執行 certmgr.msc（使用者憑證）
       確認 Personal\Certificates 中出現 EAP-TLS User 憑證
    4. 在 NPS 伺服器執行 gpupdate /force
       確認 NPS Server 憑證已自動申請

  注意：GPO 套用後，用戶端需等待 GP 更新週期（約 90 分鐘）
        或手動執行 gpupdate /force 才會立即申請憑證。
==================================================
"@ -ForegroundColor Green

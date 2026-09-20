# ============================================================
#  06_configure_radius_clients.ps1
#  批次登記 NPS 的 RADIUS Client（802.1X/MAB 架構中的各台NAS設備）
#
#  涵蓋設備：
#    - SW-HQ-Core-02（Core Switch，VLAN10管理介面）
#    - SW-HQ-Core-3（Core Switch延伸，VLAN10管理介面）
#    - SW-HQ-Edge-200（Edge Switch，VLAN10管理介面）
#    - Aruba IAP-305 Wi-Fi AP（Virtual Controller，VLAN34管理介面）
#
#  技術限制說明（重要）：
#    微軟原生 NPS PowerShell 模組僅提供 RADIUS Client 相關的
#    New/Get/Set/Remove-NpsRadiusClient 這幾個Cmdlet，並未提供
#    可參數化建立 Network Policy / Connection Request Policy 的
#    Cmdlet（不像AD DS有New-ADUser、GPO有New-GPO那樣完整）。
#    因此本腳本僅處理RADIUS Client登記這部分；Network Policy仍
#    須於NPS主控台(nps.msc)手動建立，測試通過後改用
#    Export-NpsConfiguration/Import-NpsConfiguration做備份與
#    複製到未來的NPS-2，詳見07腳本（規劃中）。
#
#  重要提醒（官方文件明確記載）：
#    執行 New-NpsRadiusClient 後，必須重新啟動NPS服務
#    （服務名稱仍沿用歷史名稱 IAS，非NPS）異動才會生效。
#    本腳本會在所有Client異動完成後，統一重啟一次服務。
# ============================================================

#region ── 參數區（請依實際環境修改） ────────────────────────
#
#  安全性提醒：以下SharedSecret皆為Lab測試用途的示意值，
#  Production環境上線前，每一台設備務必更換為獨立、高強度的
#  Shared Secret，不可沿用同一組密碼、也不可維持此處的示意值。
#  且此處的SharedSecret需與各交換器/AP上設定的RADIUS Key完全一致
#  （對照Edge/Core Switch設定檔中 radius server ... key 0 <值> 那一行）。
#
$RadiusClients = @(
    @{
        Name           = 'SW-HQ-Core-02'
        Address        = '192.168.10.2'
        SharedSecret   = 'P@ssw0rd'   # ← Production請更換為高強度密碼，並與交換器設定一致
        VendorName     = 'Cisco'
    },
    @{
        Name           = 'SW-HQ-Core-3'
        Address        = '192.168.10.3'   # ← 請確認實際管理IP是否為此值
        SharedSecret   = 'P@ssw0rd'   # ← Production請更換為高強度密碼，並與交換器設定一致
        VendorName     = 'Cisco'
    },
    @{
        Name           = 'SW-HQ-Edge-200'
        Address        = '192.168.10.200'
        SharedSecret   = 'P@ssw0rd'   # ← Production請更換為高強度密碼，並與交換器設定一致
        VendorName     = 'Cisco'
    },
    @{
        Name           = 'Aruba-IAP305-VC'
        Address        = '192.168.34.10'   # ← 請填入實際的Virtual Controller固定IP（VLAN34網段）
        SharedSecret   = 'P@ssw0rd'   # ← Production請更換為高強度密碼，並與AP上設定一致
        VendorName     = 'RADIUS Standard'   # Aruba Instant此處維持標準RADIUS，不需指定廠牌屬性集
    }
)

# 是否要求NPS對Access-Request驗證Message-Authenticator屬性
# （提升RADIUS請求的完整性驗證，建議Production環境開啟）
$RequireAuthAttribute = $true
#endregion

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  設定 NPS RADIUS Client"                            -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

# ── 確認 NPS 模組可用 ─────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name NPS)) {
    Write-Host "[ERROR] 找不到 NPS PowerShell 模組，請確認此伺服器已安裝 Network Policy Server 角色。" -ForegroundColor Red
    exit 1
}
Import-Module NPS -ErrorAction Stop

# ── 逐一處理每個 RADIUS Client（新增或更新，具備冪等性）────────
$AnyChange = $false

foreach ($Client in $RadiusClients) {
    Write-Host "處理 RADIUS Client：$($Client.Name) ($($Client.Address))" -ForegroundColor Yellow

    $Existing = Get-NpsRadiusClient | Where-Object { $_.Name -eq $Client.Name }

    if ($null -eq $Existing) {
        try {
            New-NpsRadiusClient `
                -Name $Client.Name `
                -Address $Client.Address `
                -SharedSecret $Client.SharedSecret `
                -VendorName $Client.VendorName `
                -AuthAttributeRequired $RequireAuthAttribute `
                -ErrorAction Stop | Out-Null

            Write-Host "  [OK] 已新增" -ForegroundColor Green
            $AnyChange = $true
        }
        catch {
            Write-Host "  [ERROR] 新增失敗：$($_.Exception.Message)" -ForegroundColor Red
        }
    }
    else {
        # 已存在，檢查是否有欄位需要更新（避免每次重跑都觸發不必要的服務重啟）
        $NeedsUpdate = (
            $Existing.Address -ne $Client.Address -or
            $Existing.VendorName -ne $Client.VendorName -or
            $Existing.AuthAttributeRequired -ne $RequireAuthAttribute
        )

        if ($NeedsUpdate) {
            try {
                Set-NpsRadiusClient `
                    -Name $Client.Name `
                    -Address $Client.Address `
                    -SharedSecret $Client.SharedSecret `
                    -VendorName $Client.VendorName `
                    -AuthAttributeRequired $RequireAuthAttribute `
                    -ErrorAction Stop | Out-Null

                Write-Host "  [OK] 設定已存在，偵測到差異並更新" -ForegroundColor Green
                $AnyChange = $true
            }
            catch {
                Write-Host "  [ERROR] 更新失敗：$($_.Exception.Message)" -ForegroundColor Red
            }
        }
        else {
            Write-Host "  [SKIP] 設定已存在且一致，略過" -ForegroundColor Gray
        }
    }
}

# ── 重新啟動NPS服務，讓RADIUS Client異動生效 ──────────────────
#    （官方文件明確要求：New/Set-NpsRadiusClient後必須重啟服務，
#     服務名稱沿用歷史命名IAS，非NPS）
if ($AnyChange) {
    Write-Host ""
    Write-Host "[服務] 偵測到異動，重新啟動NPS服務（IAS）..." -ForegroundColor Yellow
    try {
        Restart-Service -Name IAS -ErrorAction Stop
        Write-Host "  [OK] NPS服務已重新啟動" -ForegroundColor Green
    }
    catch {
        Write-Host "  [ERROR] 服務重啟失敗：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "          請手動執行 Restart-Service -Name IAS 或重啟 nps.msc 對應服務" -ForegroundColor Red
    }
}
else {
    Write-Host ""
    Write-Host "[服務] 本次無任何異動，不需要重啟服務" -ForegroundColor Gray
}

# ── 最終確認：列出目前所有RADIUS Client ────────────────────────
Write-Host ""
Write-Host "[最終確認] 目前NPS已登記的RADIUS Client清單：" -ForegroundColor Yellow
Get-NpsRadiusClient | Select-Object Name, Address, VendorName, AuthAttributeRequired, Enabled | Format-Table -AutoSize

Write-Host @"

==================================================
  RADIUS Client 設定完成！

  下一步：
    1. 到各交換器/AP上，確認 radius server 設定的 key
       與本腳本設定的SharedSecret完全一致
    2. 在各交換器上執行 test aaa group <group名稱> ... legacy
       驗證RADIUS通道本身是否正常（詳見SOP「二、事件排錯流程」）
    3. Network Policy（Machine/User/MAB-Registration/MAB-Printers/
       MAB-IoT/Guest/Deny All）仍須於 nps.msc 手動建立，
       建立完成並測試通過後，執行07腳本做Export-NpsConfiguration
       備份，以利未來複製到NPS-2

  重要提醒：
    - Production上線前，務必將所有SharedSecret更換為高強度、
      各設備獨立的密碼，不可沿用本腳本的示意值
    - SW-HQ-Core-3 的管理IP（192.168.10.3）為推測值，
      請務必確認實際IP後再執行本腳本
    - Aruba IAP-305的Virtual Controller IP為佔位值，
      待實際AP上線、VLAN34固定IP確認後，請更新此腳本再執行
==================================================
"@ -ForegroundColor Green
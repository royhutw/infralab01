# ============================================================
#  PowerShell DSC - 本機網路與主機名稱設定
#  設定項目：Hostname、IP Address、Subnet Mask、
#             Default Gateway、DNS1、DNS2
#  需求模組：NetworkingDsc, ComputerManagementDsc
#    Install-Module -Name NetworkingDsc       -Force
#    Install-Module -Name ComputerManagementDsc -Force
# ============================================================

# ── 參數區（請依實際環境修改） ──────────────────────────────
$NetworkParams = @{
    # ── 主機名稱 ───────────────────────────────────────────
    Hostname        = 'SRV-APP-01'           # 電腦名稱（不含網域，15字元以內）

    # ── 網路設定 ───────────────────────────────────────────
    InterfaceAlias  = 'Ethernet'             # 網卡名稱（可用 Get-NetAdapter 查詢）
    IPAddress       = '192.168.1.100'        # 靜態 IP 位址
    PrefixLength    = 24                     # 子網路遮罩前置長度（24 = 255.255.255.0）
    DefaultGateway  = '192.168.1.1'         # 預設閘道
    DNS1            = '192.168.1.10'        # 主要 DNS
    DNS2            = '192.168.1.11'        # 次要 DNS
    AddressFamily   = 'IPv4'

    # ── 重啟選項 ───────────────────────────────────────────
    # 修改 Hostname 後必須重啟才能生效；設為 $true 可讓 DSC 自動重啟
    RebootIfRequired = $true
}

# ── 子網路遮罩對照表（供參考） ─────────────────────────────
# PrefixLength  子網路遮罩
#   8         → 255.0.0.0
#   16        → 255.255.0.0
#   24        → 255.255.255.0
#   25        → 255.255.255.128
#   26        → 255.255.255.192
#   28        → 255.255.255.240

# ── DSC 設定區塊 ─────────────────────────────────────────────
Configuration SetServerBaseline {

    param (
        [Parameter(Mandatory)]
        [string] $NodeName
    )

    # 匯入必要的 DSC 資源模組
    Import-DscResource -ModuleName 'NetworkingDsc'
    Import-DscResource -ModuleName 'ComputerManagementDsc'

    Node $NodeName {

        # ────────────────────────────────────────────────────
        # 1. 設定電腦主機名稱
        #    若 Hostname 與目前名稱不同，DSC 會標記需要重啟
        # ────────────────────────────────────────────────────
        Computer SetHostname {
            Name = $NetworkParams.Hostname
        }

        # ────────────────────────────────────────────────────
        # 2. 確保網卡 IPv4 通訊協定已啟用
        # ────────────────────────────────────────────────────
        NetAdapterBinding EnableIPv4 {
            InterfaceAlias = $NetworkParams.InterfaceAlias
            ComponentId    = 'ms_tcpip'
            State          = 'Enabled'
        }

        # ────────────────────────────────────────────────────
        # 3. 停用 DHCP，設定靜態 IP 與子網路遮罩
        # ────────────────────────────────────────────────────
        IPAddress StaticIP {
            InterfaceAlias = $NetworkParams.InterfaceAlias
            AddressFamily  = $NetworkParams.AddressFamily
            IPAddress      = "$($NetworkParams.IPAddress)/$($NetworkParams.PrefixLength)"
            DependsOn      = '[NetAdapterBinding]EnableIPv4'
        }

        # ────────────────────────────────────────────────────
        # 4. 設定預設閘道
        # ────────────────────────────────────────────────────
        DefaultGatewayAddress SetGateway {
            InterfaceAlias = $NetworkParams.InterfaceAlias
            AddressFamily  = $NetworkParams.AddressFamily
            Address        = $NetworkParams.DefaultGateway
            DependsOn      = '[IPAddress]StaticIP'
        }

        # ────────────────────────────────────────────────────
        # 5. 設定 DNS 伺服器（主要 + 次要）
        # ────────────────────────────────────────────────────
        DnsServerAddress SetDNS {
            InterfaceAlias = $NetworkParams.InterfaceAlias
            AddressFamily  = $NetworkParams.AddressFamily
            Address        = @($NetworkParams.DNS1, $NetworkParams.DNS2)
            Validate       = $false
            DependsOn      = '[IPAddress]StaticIP'
        }
    }
}

# ── LCM 設定（控制重啟行為） ─────────────────────────────────
[DSCLocalConfigurationManager()]
Configuration LCM_RebootConfig {
    Node 'localhost' {
        Settings {
            RebootNodeIfNeeded             = $NetworkParams.RebootIfRequired
            ActionAfterReboot              = 'ContinueConfiguration'
            ConfigurationMode              = 'ApplyAndAutoCorrect'
            ConfigurationModeFrequencyMins = 15
        }
    }
}

# ── 編譯並套用 ───────────────────────────────────────────────

# 顯示即將套用的設定摘要
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  即將套用的設定摘要"                    -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  主機名稱  : $($NetworkParams.Hostname)"
Write-Host "  IP 位址   : $($NetworkParams.IPAddress)/$($NetworkParams.PrefixLength)"
Write-Host "  預設閘道  : $($NetworkParams.DefaultGateway)"
Write-Host "  主要 DNS  : $($NetworkParams.DNS1)"
Write-Host "  次要 DNS  : $($NetworkParams.DNS2)"
Write-Host "  網卡      : $($NetworkParams.InterfaceAlias)"
Write-Host "  自動重啟  : $($NetworkParams.RebootIfRequired)"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Step 1：編譯 LCM 設定
Write-Host "[1/4] 編譯 LCM 設定..." -ForegroundColor Yellow
LCM_RebootConfig -OutputPath '.\NetworkConfig_MOF\LCM' | Out-Null

# Step 2：套用 LCM 設定
Write-Host "[2/4] 套用 LCM 設定..." -ForegroundColor Yellow
Set-DscLocalConfigurationManager -Path '.\NetworkConfig_MOF\LCM' -Verbose

# Step 3：編譯主設定 MOF
Write-Host "[3/4] 編譯網路與主機名稱設定..." -ForegroundColor Yellow
SetServerBaseline -NodeName 'localhost' -OutputPath '.\NetworkConfig_MOF\Config' | Out-Null

Write-Host "[4/4] 套用設定..." -ForegroundColor Yellow
Start-DscConfiguration -Path '.\NetworkConfig_MOF\Config' -Wait -Verbose -Force

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  設定已套用完成！"                      -ForegroundColor Green
if ($NetworkParams.RebootIfRequired) {
    Write-Host "  ⚠ 主機名稱變更需要重啟才能生效"    -ForegroundColor Yellow
    Write-Host "    伺服器即將自動重新啟動..."        -ForegroundColor Yellow
}
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# ── 常用驗證指令 ─────────────────────────────────────────────
# 測試目前設定是否符合期望狀態：
#   Test-DscConfiguration -Path '.\NetworkConfig_MOF\Config' -Verbose
#
# 查詢目前 DSC 套用狀態：
#   Get-DscConfiguration
#
# 確認主機名稱：
#   $env:COMPUTERNAME
#   hostname
#
# 確認 IP 設定：
#   Get-NetIPAddress -InterfaceAlias 'Ethernet' -AddressFamily IPv4
#   Get-NetIPConfiguration
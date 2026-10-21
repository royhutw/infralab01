# ============================================================
#  01_install_cepces_server.ps1 (v2 - 具備冪等性與防呆保護)
#  安裝與設定獨立的 AD CS CEP / CES (憑證註冊原則與 Web 服務)
#  適用作業系統：Windows Server 2022 Standard / Datacenter
# ============================================================

# ── 載入共用參數設定 ────────────────────────────────────────
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
$Params = Merge-CAConfig -Sections 'Global', 'CepCesServer'

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  AD CS CEP / CES 獨立主機基礎安裝與設定 (冪等防護)"   -ForegroundColor Cyan
Write-Host "  目標網域：$($Params.DomainName)"                  -ForegroundColor Cyan
Write-Host "  伺服器 FQDN：$($Params.ServerFQDN)"               -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

# ── 步驟 1：安裝 IIS 與必要網頁角色與 AD CS 憑證網上註冊功能 ──
Write-Host "[1/4] 檢查並安裝 IIS 網頁伺服器與 CEP/CES 角色服務..." -ForegroundColor Yellow

$Features = @(
    'Web-Server',                   # IIS 基礎
    'Web-Mgmt-Tools',               # IIS 管理工具
    'Web-Windows-Auth',             # Windows 整合式驗證 (Kerberos 需要)
    'Web-Asp-Net45',                # WCF/ASP.NET 支援
    'ADCS-Web-Enrollment',          # 網頁註冊角色
    'ADCS-Enroll-Web-Svc',          # CES 憑證註冊 Web 服務
    'ADCS-Policy-Web-Svc'           # CEP 憑證註冊原則 Web 服務
)

foreach ($Feature in $Features) {
    try {
        $Installed = (Get-WindowsFeature -Name $Feature).Installed
        if (-not $Installed) {
            Write-Host "  正在安裝：$Feature" -ForegroundColor Gray
            Install-WindowsFeature -Name $Feature -IncludeManagementTools -ErrorAction Stop | Out-Null
        } else {
            Write-Host "  [略過] 已安裝：$Feature" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "  [ERROR] 安裝功能 $Feature 失敗：$($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
Write-Host "  [OK] 所有角色與功能確認完畢。" -ForegroundColor Green


# ── 步驟 2：確認並設定 IIS HTTPS 繫結與憑證 ──────────────────
Write-Host ""
Write-Host "[2/4] 檢查 IIS 憑證與 HTTPS (Port 443) 繫結..." -ForegroundColor Yellow

try {
    # 尋找對應 ServerFQDN 的憑證 (建議使用專屬 Web Server 憑證)
    $Cert = Get-ChildItem -Path $Params.CertStore | 
            Where-Object { $_.Subject -match $Params.ServerFQDN -and $_.NotAfter -gt (Get-Date) } | 
            Select-Object -First 1

    if ($null -eq $Cert) {
        Write-Host "  [ERROR] 在 $($Params.CertStore) 中找不到對應 FQDN ($($Params.ServerFQDN)) 的有效網頁憑證！" -ForegroundColor Red
        Write-Host "          請確保已為此主機申請並安裝專屬的「網頁伺服器憑證 (Web Server)」後再執行本腳本。" -ForegroundColor Red
        exit 1
    }

    Write-Host "  [OK] 找到有效憑證，Thumbprint: $($Cert.Thumbprint)" -ForegroundColor Green

    Import-Module WebAdministration
    $HttpsBindingPath = 'IIS:\Sites\Default Web Site'
    $ExistingBinding = Get-WebBinding -Name 'Default Web Site' -Protocol 'https'

    if ($null -eq $ExistingBinding) {
        Write-Host "  正在建立 Default Web Site 的 HTTPS (443) 繫結..." -ForegroundColor Gray
        New-WebBinding -Name 'Default Web Site' -Protocol 'https' -Port 443 -IPAddress '*' -ErrorAction Stop | Out-Null
    }

    $ExistingCertHash = (Get-Item "$HttpsBindingPath\bindings\protocol['https']").certHash
    if ($ExistingCertHash -ne $Cert.Thumbprint) {
        Write-Host "  正在將新憑證指紋繫結至 HTTPS 站台..." -ForegroundColor Gray
        Get-Item "$HttpsBindingPath" | Set-ItemProperty -Name certHash -Value $Cert.Thumbprint -ErrorAction Stop
    } else {
        Write-Host "  [略過] IIS 已經正確繫結此憑證。" -ForegroundColor DarkGray
    }
    Write-Host "  [OK] IIS HTTPS 繫結確認完成。" -ForegroundColor Green
}
catch {
    Write-Host "  [ERROR] 設定 IIS HTTPS 繫結時發生異常：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}


# ── 步驟 3：設定 AD CS CEP 與 CES 服務 (具備冪等防護) ──────────
Write-Host ""
Write-Host "[3/4] 檢查並設定 CEP 與 CES 應用程式集區與驗證模式..." -ForegroundColor Yellow

try {
    Import-Module AdcsAdministration

    # 檢查 IIS 中是否已經存在 CEP/CES 虛擬目錄以判斷是否已設定過
    $CepPath = "IIS:\Sites\Default Web Site\ADPolicyProvider_CEP_Kerberos"
    $CesPath = "IIS:\Sites\Default Web Site\ADEnrollmentServer_CES_Kerberos"

    if ((-not (Test-Path $CepPath)) -or (-not (Test-Path $CesPath))) {
        Write-Host "  系統尚未偵測到 CEP/CES 服務，正在進行初始化設定..." -ForegroundColor Gray
        
        Install-AdcsEnrollmentWebSvc -AuthenticationType Kerberos -KeyBasedRenewal $false -Force -ErrorAction Stop
        Install-AdcsEnrollmentPolicyWebSvc -AuthenticationType Kerberos -Force -ErrorAction Stop
        
        Write-Host "  [OK] CEP 與 CES 服務初始化成功。" -ForegroundColor Green
    } else {
        Write-Host "  [略過] 偵測到 CEP 與 CES 服務已經設定存在，略過初始化以保護現有環境。" -ForegroundColor DarkGray
    }
}
catch {
    Write-Host "  [ERROR] 設定 CEP/CES 時發生例外錯誤：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "          請檢查相關日誌或透過伺服器管理員確認 AD CS 組態。" -ForegroundColor Yellow
    exit 1
}


# ── 步驟 4：調整 IIS 查詢限制與完成提示 ────────────────────────
Write-Host ""
Write-Host "[4/4] 調整 IIS 相關 URL 與查詢字串長度上限 (防範大容量 CSR 失敗)..." -ForegroundColor Yellow

try {
    Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/security/requestFiltering/requestLimits" -name "maxQueryString" -value 65534 -ErrorAction Stop
    Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/security/requestFiltering/requestLimits" -name "maxUrl" -value 65534 -ErrorAction Stop

    # 重啟 IIS 以生效
    iisreset /noforce | Out-Null
    Write-Host "  [OK] IIS 參數調整完成並已重啟服務。" -ForegroundColor Green
}
catch {
    Write-Host "  [WARN] 調整 IIS 請求限制時發生警告：$($_.Exception.Message)" -ForegroundColor Yellow
}


# ── 完成提示 ────────────────────────────────────────────────
Write-Host @"

==================================================
  AD CS CEP/CES 基礎環境安裝設定完成！(冪等防護已生效)

  【後續檢查項目】
  1. 網頁檢測：請嘗試從網域內其他主機連線至：
     https://$($Params.ServerFQDN)/ADPolicyProvider_CEP_Kerberos/service.svc/CEP
     https://$($Params.ServerFQDN)/ADEnrollmentServer_CES_Kerberos/service.svc/CES
  2. 請確定後端 Sub CA 已完成權限與對應範本之準備。

  若此階段工作確認成功，請告知，我們將推進下一階段。
==================================================
"@ -ForegroundColor Green
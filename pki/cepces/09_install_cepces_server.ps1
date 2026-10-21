# ============================================================
#  09_install_cepces_server.ps1
#  於獨立的 AD CS CEP / CES 伺服器上執行（具備完整冪等性與 try-catch 防護）
#
#  執行內容：
#    1. 強制更新 GPO 並觸發 Auto-Enrollment 自動取得 CEP-CES-WebServer 憑證
#    2. 安裝 IIS 與 CEP/CES 角色服務
#    3. 設定 IIS HTTPS (443) 繫結，並啟用「憑證更新時自動重新繫結 (Auto-Rebind)」
#    4. 初始化 CEP 與 CES (Kerberos 整合驗證模式) 並開啟 UseAppPoolCredentials
#    5. 調整 IIS URL/Query 長度限制以支援大型 4096-bit CSR
# ============================================================

#region ── 參數區（統一從 CAConfig.psd1 讀取）──────────────────
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')$Params = Merge-CAConfig -Sections 'Global','CepCes'
#endregion

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  AD CS CEP / CES 獨立主機安裝與自動憑證繫結"         -ForegroundColor Cyan
Write-Host "  目標網域：$($Params.DomainName)"                  -ForegroundColor Cyan
Write-Host "  本機 FQDN：$($Params.ServerFQDN)"                 -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

# ════════════════════════════════════════════════════════════
#  [1/5] 觸發 GPO 更新與憑證自動註冊 (Auto-Enrollment)
# ════════════════════════════════════════════════════════════
Write-Host "[1/5] 觸發 GPO 更新並向 Sub CA 自動申請 Web 伺服器憑證..." -ForegroundColor Yellow

try {
    gpupdate /force /target:computer | Out-Null
    certutil -pulse | Out-Null
    Start-Sleep -Seconds 5

    # 從本機電腦憑證存放區尋找由 CEP-CES-WebServer 範本簽發、且具備 Server Authentication (1.3.6.1.5.5.7.3.1) 的有效憑證
    $Cert = Get-ChildItem -Path $Params.CertStore \vert{} Where-Object {$_.NotAfter -gt (Get-Date) -and
        ($_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1') -and
        ($_.Subject -match$Params.ServerFQDN)
    } | Sort-Object NotAfter -Descending | Select-Object -First 1

    if ($null -eq$Cert) {
        Write-Host "  [ERROR] 尚未在本機憑證存放區 ($($Params.CertStore)) 找到對應 $($Params.ServerFQDN) 的有效 Web 憑證！" -ForegroundColor Red
        Write-Host "          請確認已在 Sub CA 執行過 08 腳本，且本機已重新啟動以更新電腦群組權杖 (Kerberos Token)。" -ForegroundColor Yellow
        Write-Host "          （注意：電腦剛被加入安全群組時，必須重開機一次，電腦帳號的 Token 才會包含新群組 SID！）" -ForegroundColor Yellow
        exit 1
    }

    Write-Host "  [OK] 成功取得有效憑證！Subject: $($Cert.Subject)" -ForegroundColor Green
    Write-Host "       Thumbprint: $($Cert.Thumbprint) (到期日: $($Cert.NotAfter.ToString('yyyy-MM-dd')))" -ForegroundColor Gray
}
catch {
    Write-Host "  [ERROR] 憑證自動申請或檢查過程發生異常：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ════════════════════════════════════════════════════════════
#  [2/5] 安裝 IIS 與 AD CS CEP/CES 角色服務
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[2/5] 檢查並安裝 IIS 網頁伺服器與 CEP/CES 角色服務..." -ForegroundColor Yellow

$Features = @(
    'Web-Server',
    'Web-Mgmt-Tools',
    'Web-Windows-Auth',
    'Web-Asp-Net45',
    'ADCS-Enroll-Web-Svc',
    'ADCS-Policy-Web-Svc'
)

foreach ($Feature in$Features) {
    try {
        $Installed = (Get-WindowsFeature -Name$Feature).Installed
        if (-not $Installed) {
            Write-Host "  正在安裝：$Feature" -ForegroundColor Gray
            Install-WindowsFeature -Name $Feature -IncludeManagementTools -ErrorAction Stop | Out-Null
        } else {
            Write-Host "  [SKIP] 已安裝：$Feature" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Host "  [ERROR] 安裝功能 $Feature 失敗：$($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
Write-Host "  [OK] 所有角色與功能確認完畢。" -ForegroundColor Green

# ════════════════════════════════════════════════════════════
#  [3/5] 設定 IIS HTTPS 繫結並啟用「憑證自動重新繫結 (Auto-Rebind)」
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[3/5] 設定 IIS HTTPS (443) 繫結與自動重新繫結 (Certificate Auto-Rebind)..." -ForegroundColor Yellow

try {
    Import-Module WebAdministration -ErrorAction Stop

    $ExistingBinding = Get-WebBinding -Name 'Default Web Site' -Protocol 'https'
    if ($null -eq$ExistingBinding) {
        Write-Host "  正在建立 Default Web Site 的 HTTPS (443) 繫結..." -ForegroundColor Gray
        New-WebBinding -Name 'Default Web Site' -Protocol 'https' -Port 443 -IPAddress '*' -ErrorAction Stop | Out-Null
        $ExistingBinding = Get-WebBinding -Name 'Default Web Site' -Protocol 'https'
    }

    # 使用 AddSslCertificate 方法安全綁定憑證指紋至 0.0.0.0:443
    if ($ExistingBinding.certificateHash -ne$Cert.Thumbprint) {
        Write-Host "  正在將憑證指紋 ($($Cert.Thumbprint)) 綁定至 HTTPS 443..." -ForegroundColor Gray
        $ExistingBinding.AddSslCertificate($Cert.Thumbprint, "my")
        Write-Host "  [OK] HTTPS 憑證綁定完成。" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] IIS HTTPS 已綁定最新憑證。" -ForegroundColor DarkGray
    }

    # 啟用 IIS 內建「憑證更新自動重新繫結 (Certificate Rebind)」排程工作
    # 當 Auto-Enrollment 更新憑證並觸發 Lifecycle Event ID 1001 時，IIS 自動執行 AppCmd renew binding
    $RebindTask = Get-ScheduledTask -TaskName 'System_CertificateServicesClient_IIS-AutoRebind' -ErrorAction SilentlyContinue
    if ($null -eq$RebindTask) {
        Write-Host "  正在註冊 IIS 憑證自動重新繫結 (Auto-Rebind) 事件觸發器..." -ForegroundColor Gray
        $Action  = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\inetsrv\appcmd.exe" `
                                           -Argument 'renew binding /oldcert:$(OldCertHash) /newcert:$(NewCertHash)'
        # 綁定 Windows 憑證生命週期事件 (Event ID 1001: 憑證已取代/更新)
        $CIMTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
        $Trigger = New-CimInstance -CimClass $CIMTriggerClass -ClientOnly
        $Trigger.Enabled = $true
        $Trigger.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-CertificateServicesClient-Lifecycle-System/Operational"><Select Path="Microsoft-Windows-CertificateServicesClient-Lifecycle-System/Operational">*[System[Provider[@Name=''Microsoft-Windows-CertificateServicesClient-Lifecycle-System''] and EventID=1001]]</Select></Query></QueryList>'
        $Trigger.ValueQueries = @(
            [CimInstance](New-CimInstance -CimClass (Get-CimClass -ClassName MSFT_TaskNamedValue -Namespace Root/Microsoft/Windows/TaskScheduler) -Property @{Name='OldCertHash'; Value='Event/UserData/CertNotificationData/OldCertificateDetails/@Thumbprint'} -ClientOnly),
            [CimInstance](New-CimInstance -CimClass (Get-CimClass -ClassName MSFT_TaskNamedValue -Namespace Root/Microsoft/Windows/TaskScheduler) -Property @{Name='NewCertHash'; Value='Event/UserData/CertNotificationData/NewCertificateDetails/@Thumbprint'} -ClientOnly)
        )
        Register-ScheduledTask -TaskName 'System_CertificateServicesClient_IIS-AutoRebind' `
                               -TaskPath '\Microsoft\Windows\CertificateServicesClient\' `
                               -Action $Action `
                               -Trigger $Trigger `
                               -User 'NT AUTHORITY\SYSTEM' `
                               -RunLevel Highest `
                               -Force | Out-Null
        Write-Host "  [OK] 已成功啟用 IIS 憑證到期更新自動重新繫結功能。" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] IIS 憑證自動重新繫結排程已存在。" -ForegroundColor DarkGray
    }
}
catch {
    Write-Host "  [ERROR] 設定 IIS HTTPS 或自動重新繫結時發生異常：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ════════════════════════════════════════════════════════════
#  [4/5] 初始化 CEP 與 CES 服務 (具備冪等防護)
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[4/5] 檢查並初始化 CEP 與 CES Web 服務..." -ForegroundColor Yellow

try {
    Import-Module AdcsAdministration -ErrorAction Stop

    # 組合遠端 Sub CA 的完整 Config 字串 (格式：SubCAFQDN\CACommonName)
    $SubCAFQDN   = "$($Params.SubCAComputerName).$($Params.DomainName)"
    $CAConfigStr = "$SubCAFQDN\$($Params.CACommonName)"

    $CepPath = "IIS:\Sites\Default Web Site\ADPolicyProvider_CEP_Kerberos"
    if (-not (Test-Path $CepPath)) {
        Write-Host "  正在初始化 CEP (憑證註冊原則 Web 服務)..." -ForegroundColor Gray
        Install-AdcsEnrollmentPolicyWebSvc -AuthenticationType Kerberos -Force -ErrorAction Stop | Out-Null
        Write-Host "  [OK] CEP 服務初始化完成。" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] CEP 服務已存在，略過初始化。" -ForegroundColor DarkGray
    }

    # CES 虛擬目錄名稱預設為 <CACommonName>_CES_Kerberos
    $CesPath = "IIS:\Sites\Default Web Site\$($Params.CACommonName)_CES_Kerberos"
    if (-not (Test-Path $CesPath)) {
        Write-Host "  正在初始化 CES (憑證註冊 Web 服務，連結至 $CAConfigStr)..." -ForegroundColor Gray
        Install-AdcsEnrollmentWebSvc -CAConfig $CAConfigStr `
                                     -AuthenticationType Kerberos `
                                     -RenewalOnly $false `
                                     -AllowKeyBasedRenewal $false `
                                     -Force -ErrorAction Stop | Out-Null
        Write-Host "  [OK] CES 服務初始化完成。" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] CES 服務已存在，略過初始化。" -ForegroundColor DarkGray
    }

    # 確保開啟 useAppPoolCredentials，避免 IIS Kerberos 解密票證失敗
    foreach ($AppDir in @("ADPolicyProvider_CEP_Kerberos", "$($Params.CACommonName)_CES_Kerberos")) {
        Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/windowsAuthentication" `
                                     -Name "useAppPoolCredentials" `
                                     -Value "True" `
                                     -PSPath "IIS:\" `
                                     -Location "Default Web Site/$AppDir" `
                                     -ErrorAction SilentlyContinue
    }
    Write-Host "  [OK] 已啟用 Windows 驗證之 useAppPoolCredentials 設定。" -ForegroundColor Green
}
catch {
    Write-Host "  [ERROR] 初始化 CEP/CES 服務失敗：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ════════════════════════════════════════════════════════════
#  [5/5] 調整 IIS URL 與查詢字串限制並重啟服務
# ════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "[5/5] 調整 IIS 請求長度上限並重啟 IIS..." -ForegroundColor Yellow

try {
    Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/security/requestFiltering/requestLimits" -name "maxQueryString" -value 65534 -ErrorAction Stop
    Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/security/requestFiltering/requestLimits" -name "maxUrl" -value 65534 -ErrorAction Stop

    iisreset /noforce | Out-Null
    Write-Host "  [OK] IIS 設定更新並重啟完成。" -ForegroundColor Green
}
catch {
    Write-Host "  [WARN] 調整 IIS 長度限制時發生警告：$($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host @"

==================================================
  AD CS CEP / CES 獨立伺服器建置完成！

  【本機端點網址（供下一階段 Debian 13 cepces 設定使用）】
  - CEP 原則端點：
    https://$($Params.ServerFQDN)/ADPolicyProvider_CEP_Kerberos/service.svc/CEP
  - CES 註冊端點：
    https://$($Params.ServerFQDN)/$($Params.CACommonName)_CES_Kerberos/service.svc/CES
==================================================
"@ -ForegroundColor Green
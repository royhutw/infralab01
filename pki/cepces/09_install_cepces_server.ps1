# ============================================================
#  09_install_cepces_server.ps1 (防剪貼簿吃空白強化版)
#  於獨立的 AD CS CEP / CES 伺服器上執行（具備完整冪等性與 try-catch 防護）
# ============================================================

#region ── 參數區（統一從 CAConfig.psd1 讀取）──────────────────
. (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
$Params = Merge-CAConfig -Sections 'Global','CepCes'
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

    $Cert = Get-ChildItem -Path ($Params.CertStore) | Where-Object {
        $_.NotAfter -gt (Get-Date) -and
        ($_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.1') -and
        ($_.Subject -match ($Params.ServerFQDN))
    } | Sort-Object NotAfter -Descending | Select-Object -First 1

    if ($null -eq $Cert) {
        Write-Host "  [ERROR] 尚未在本機憑證存放區 ($($Params.CertStore)) 找到對應 $($Params.ServerFQDN) 的有效 Web 憑證！" -ForegroundColor Red
        Write-Host "          請確認已在 Sub CA 執行過 08 腳本，且本機已重新啟動以更新電腦群組權杖 (Kerberos Token)。" -ForegroundColor Yellow
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
    'ADCS-Enroll-Web-Pol'
)

# 使用 ($Features) 括號隔離，防止剪貼簿吃掉 in 後方的空白
foreach ($Feature in ($Features)) {
    try {
        $FeatObj = Get-WindowsFeature -Name ($Feature)
        if (-not ($FeatObj.Installed)) {
            Write-Host "  正在安裝：$Feature" -ForegroundColor Gray
            $InstallParams = @{
                Name                   = $Feature
                IncludeManagementTools = $true
                ErrorAction            = 'Stop'
            }
            Install-WindowsFeature @InstallParams | Out-Null
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
    if ($null -eq $ExistingBinding) {
        Write-Host "  正在建立 Default Web Site 的 HTTPS (443) 繫結..." -ForegroundColor Gray
        $BindParams = @{
            Name        = 'Default Web Site'
            Protocol    = 'https'
            Port        = 443
            IPAddress   = '*'
            ErrorAction = 'Stop'
        }
        New-WebBinding @BindParams | Out-Null
        $ExistingBinding = Get-WebBinding -Name 'Default Web Site' -Protocol 'https'
    }

    if ($ExistingBinding.certificateHash -ne ($Cert.Thumbprint)) {
        Write-Host "  正在將憑證指紋 ($($Cert.Thumbprint)) 綁定至 HTTPS 443..." -ForegroundColor Gray
        $ExistingBinding.AddSslCertificate($Cert.Thumbprint, "my")
        Write-Host "  [OK] HTTPS 憑證綁定完成。" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] IIS HTTPS 已綁定最新憑證。" -ForegroundColor DarkGray
    }

    $RebindTask = Get-ScheduledTask -TaskName 'System_CertificateServicesClient_IIS-AutoRebind' -ErrorAction SilentlyContinue
    if ($null -eq $RebindTask) {
        Write-Host "  正在註冊 IIS 憑證自動重新繫結 (Auto-Rebind) 事件觸發器..." -ForegroundColor Gray
        $ActionParams = @{
            Execute  = "$env:SystemRoot\System32\inetsrv\appcmd.exe"
            Argument = 'renew binding /oldcert:$(OldCertHash) /newcert:$(NewCertHash)'
        }
        $Action = New-ScheduledTaskAction @ActionParams

        $CIMTriggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
        $Trigger = New-CimInstance -CimClass ($CIMTriggerClass) -ClientOnly
        $Trigger.Enabled = $true
        $Trigger.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-CertificateServicesClient-Lifecycle-System/Operational"><Select Path="Microsoft-Windows-CertificateServicesClient-Lifecycle-System/Operational">*[System[Provider[@Name=''Microsoft-Windows-CertificateServicesClient-Lifecycle-System''] and EventID=1001]]</Select></Query></QueryList>'

        $NamedValClass = Get-CimClass -ClassName MSFT_TaskNamedValue -Namespace Root/Microsoft/Windows/TaskScheduler
        $Val1 = New-CimInstance -CimClass ($NamedValClass) -Property @{Name='OldCertHash'; Value='Event/UserData/CertNotificationData/OldCertificateDetails/@Thumbprint'} -ClientOnly
        $Val2 = New-CimInstance -CimClass ($NamedValClass) -Property @{Name='NewCertHash'; Value='Event/UserData/CertNotificationData/NewCertificateDetails/@Thumbprint'} -ClientOnly
        $Trigger.ValueQueries = [CimInstance[]]@($Val1, $Val2)

        $RegTaskParams = @{
            TaskName = 'System_CertificateServicesClient_IIS-AutoRebind'
            TaskPath = '\Microsoft\Windows\CertificateServicesClient\'
            Action   = $Action
            Trigger  = $Trigger
            User     = 'NT AUTHORITY\SYSTEM'
            RunLevel = 'Highest'
            Force    = $true
        }
        Register-ScheduledTask @RegTaskParams | Out-Null
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

    $SubCAFQDN   = "$($Params.SubCAComputerName).$($Params.DomainName)"
    $CAConfigStr = "$SubCAFQDN\$($Params.CACommonName)"

    $CepPath = "IIS:\Sites\Default Web Site\ADPolicyProvider_CEP_Kerberos"
    if (-not (Test-Path ($CepPath))) {
        Write-Host "  正在初始化 CEP (憑證註冊原則 Web 服務)..." -ForegroundColor Gray
        $CepParams = @{
            AuthenticationType = 'Kerberos'
            Force              = $true
            ErrorAction        = 'Stop'
        }
        Install-AdcsEnrollmentPolicyWebSvc @CepParams | Out-Null
        Write-Host "  [OK] CEP 服務初始化完成。" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] CEP 服務已存在，略過初始化。" -ForegroundColor DarkGray
    }

    $CesPath = "IIS:\Sites\Default Web Site\$($Params.CACommonName)_CES_Kerberos"
    if (-not (Test-Path ($CesPath))) {
        Write-Host "  正在初始化 CES (憑證註冊 Web 服務，連結至 $CAConfigStr)..." -ForegroundColor Gray
        $CesParams = @{
            CAConfig              = $CAConfigStr
            AuthenticationType    = 'Kerberos'
            RenewalOnly           = $false
            AllowKeyBasedRenewal  = $false
            Force                 = $true
            ErrorAction           = 'Stop'
        }
        Install-AdcsEnrollmentWebSvc @CesParams | Out-Null
        Write-Host "  [OK] CES 服務初始化完成。" -ForegroundColor Green
    } else {
        Write-Host "  [SKIP] CES 服務已存在，略過初始化。" -ForegroundColor DarkGray
    }

    $AppDirs = @("ADPolicyProvider_CEP_Kerberos", "$($Params.CACommonName)_CES_Kerberos")
    foreach ($AppDir in ($AppDirs)) {
        $WinAuthParams = @{
            Filter      = '/system.webServer/security/authentication/windowsAuthentication'
            Name        = 'useAppPoolCredentials'
            Value       = 'True'
            PSPath      = 'IIS:\'
            Location    = "Default Web Site/$AppDir"
            ErrorAction = 'SilentlyContinue'
        }
        Set-WebConfigurationProperty @WinAuthParams
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
    $LimitParams1 = @{
        PSPath      = 'MACHINE/WEBROOT/APPHOST'
        Filter      = 'system.webServer/security/requestFiltering/requestLimits'
        Name        = 'maxQueryString'
        Value       = 65534
        ErrorAction = 'Stop'
    }
    Set-WebConfigurationProperty @LimitParams1

    $LimitParams2 = @{
        PSPath      = 'MACHINE/WEBROOT/APPHOST'
        Filter      = 'system.webServer/security/requestFiltering/requestLimits'
        Name        = 'maxUrl'
        Value       = 65534
        ErrorAction = 'Stop'
    }
    Set-WebConfigurationProperty @LimitParams2

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
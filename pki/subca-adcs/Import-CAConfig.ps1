# ============================================================
#  Import-CAConfig.ps1
#  共用參數載入器（供其餘 .ps1 以 dot-source 方式載入）
#
#  用法（放在各腳本的參數區）：
#    . (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
#    $Params = Merge-CAConfig -Sections 'Global','RootCADN'
#
#  Merge-CAConfig 會依序讀取 CAConfig.psd1 裡指定的區塊（Section），
#  合併成單一 Hashtable 回傳，讓下方腳本本文可以維持原本
#  $Params.XXX 的寫法，不需要逐一改成 $Config.區塊.XXX。
#
#  【重要】CAConfig.psd1 必須與所有 .ps1 放在同一目錄。
#
#  除了 Merge-CAConfig，本檔也提供各腳本共用的函式（避免每支腳本各維護一份）：
#    Start-CATranscript / Stop-CATranscript   記錄檔
#    Invoke-CertutilChecked / Wait-CertSvcReady / Get-LocalCAConfigString
#    ConvertTo-DnValue / New-CADnSuffix       CA DN 組合（01、07）
#    Set-GPRegistryValueIfNeeded              GPO 登錄值（05、06）
#    Set-CertTemplateAcl                      範本 ACL（04、08）
# ============================================================

function Merge-CAConfig {
    param(
        [Parameter(Mandatory)]
        [string[]] $Sections
    )

    $ConfigPath = Join-Path $PSScriptRoot 'CAConfig.psd1'
    if (-not (Test-Path $ConfigPath)) {
        throw "找不到共用參數檔：$ConfigPath（請確認 CAConfig.psd1 與本腳本放在同一目錄）"
    }

    $Config = Import-PowerShellDataFile -Path $ConfigPath
    $Merged = @{}

    foreach ($SectionName in $Sections) {
        if (-not $Config.ContainsKey($SectionName)) {
            throw "CAConfig.psd1 裡找不到區塊：$SectionName（請確認區塊名稱是否打錯，或是否已被移除）"
        }
        foreach ($Key in $Config[$SectionName].Keys) {
            $Merged[$Key] = $Config[$SectionName][$Key]
        }
    }

    # 重要：擋掉未實際填寫的佔位字串，避免腳本在後段才發現憑證設定錯誤。
    $PlaceholderPatterns = @(
        'YOUR_CERTIFICATE_THUMBPRINT_HERE',
        'REPLACE_WITH_REAL_THUMBPRINT',
        '<thumbprint>',
        '0000000000000000000000000000000000000000'
    )

    if ($Merged.ContainsKey('CertificateThumbprint')) {
        $Thumbprint = [string]$Merged['CertificateThumbprint']
        if ([string]::IsNullOrWhiteSpace($Thumbprint)) {
            throw "CAConfig.psd1 的 CertificateThumbprint 為空白，請先填入 DSC 加密憑證指紋後再執行。"
        }

        $PlaceholderHit = $PlaceholderPatterns | Where-Object { $Thumbprint -like "*$_*" } | Select-Object -First 1
        if ($PlaceholderHit) {
            throw "CAConfig.psd1 的 CertificateThumbprint 尚未實際設定（目前值：$Thumbprint）。請先替換為實際憑證指紋，再執行此腳本。"
        }
        if ($Thumbprint -notmatch '^[0-9A-Fa-f]{40}$') {
            throw "CAConfig.psd1 的 CertificateThumbprint 格式不正確（需為 40 位十六進位字元，不含空白；目前值：$Thumbprint）。"
        }
    }

    return $Merged
}

#region ── 共用輔助函式（供 01～08 dot-source 後使用）────────────────

function Start-CATranscript {
    <# 建立記錄檔並開始 Transcript，回傳記錄檔路徑。Params 需含 CAConfigDir（Global 區塊）。 #>
    param(
        [Parameter(Mandatory)][string]    $Name,
        [Parameter(Mandatory)][hashtable] $Params
    )
    $LogDir = Join-Path $Params.CAConfigDir 'Logs'
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    $LogFile = Join-Path $LogDir ('{0}_{1:yyyyMMdd_HHmmss}.log' -f $Name, (Get-Date))
    Start-Transcript -Path $LogFile | Out-Null
    return $LogFile
}

function Stop-CATranscript {
    try { Stop-Transcript | Out-Null } catch { }
}

function Invoke-CertutilChecked {
    <#
      以參數陣列呼叫 certutil 並檢查結束代碼。
      Arguments 必須是「每個參數一個元素」的陣列，不可把整串指令塞成單一字串。
      刻意不回傳 certutil 輸出，避免污染呼叫端的 pipeline。
    #>
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [string] $SuccessMessage = 'certutil 執行成功。',
        [string] $FailureMessage = 'certutil 執行失敗。',
        [string] $Indent = '  ',
        [switch] $Quiet
    )

    $Output   = & certutil @Arguments 2>&1
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne 0) {
        Write-Host "${Indent}[ERROR] $FailureMessage（退出碼：$ExitCode）" -ForegroundColor Red
        foreach ($Line in $Output) { Write-Host "${Indent}$Line" -ForegroundColor Red }
        throw "certutil $($Arguments -join ' ') 執行失敗。"
    }
    if (-not $Quiet) { Write-Host "${Indent}[OK] $SuccessMessage" -ForegroundColor Green }
}

function Wait-CertSvcReady {
    <# 等待 CA 真正可回應（服務 Running 不代表 CA 引擎已可用） #>
    param([int] $MaxTries = 12, [int] $DelaySeconds = 5)

    for ($i = 1; $i -le $MaxTries; $i++) {
        & certutil -ping 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds $DelaySeconds
    }
    return $false
}

function Get-LocalCAConfigString {
    <# 回傳本機 CA 的 certutil -config 字串（主機 FQDN\CA 名稱）。直接讀登錄檔，不解析 certutil 文字輸出（跨語系不可靠）。 #>
    $CertSvcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
    $CAName = (Get-ItemProperty -Path $CertSvcRoot -ErrorAction SilentlyContinue).Active
    if ([string]::IsNullOrWhiteSpace($CAName)) {
        throw "無法從登錄檔取得作用中的 CA 名稱，請確認此機器已完成 AD CS 設定（01、02）。"
    }
    $CS   = Get-CimInstance Win32_ComputerSystem
    $CAHost = if ($CS.PartOfDomain) { "$($CS.DNSHostName).$($CS.Domain)" } else { $CS.DNSHostName }
    return "$CAHost\$CAName"
}

function ConvertTo-DnValue {
    <# 依 RFC 4514 跳脫 DN 屬性值中的特殊字元 #>
    param([string] $Value)
    $Escaped = $Value -replace '([,+"\\<>;=])', '\$1'
    if ($Escaped -match '^[ #]') { $Escaped = '\' + $Escaped }
    if ($Escaped -match ' $')    { $Escaped = $Escaped.Substring(0, $Escaped.Length - 1) + '\ ' }
    return $Escaped
}

function New-CADnSuffix {
    <#
      由 RootCADN 區塊與 DomainName 組合 CADistinguishedNameSuffix（01 與 07 共用）。
      標準順序（最具體在前）：OU, O, L, ST, C, DC…；必填 O、C，選填 OU、L、ST。
    #>
    param([Parameter(Mandatory)][hashtable] $Params)

    if ($Params.CACountry -notmatch '^[A-Za-z]{2}$') { throw "CACountry 必須是兩碼國碼（目前：'$($Params.CACountry)'）。" }
    if ([string]::IsNullOrWhiteSpace($Params.CAOrganization)) { throw "CAOrganization 不可為空。" }

    $Parts = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Params.CAOU))       { $Parts.Add("OU=$(ConvertTo-DnValue $Params.CAOU)") }
    $Parts.Add("O=$(ConvertTo-DnValue $Params.CAOrganization)")
    if (-not [string]::IsNullOrWhiteSpace($Params.CALocality)) { $Parts.Add("L=$(ConvertTo-DnValue $Params.CALocality)") }
    if (-not [string]::IsNullOrWhiteSpace($Params.CAState))    { $Parts.Add("ST=$(ConvertTo-DnValue $Params.CAState)") }
    $Parts.Add("C=$($Params.CACountry)")
    foreach ($Label in $Params.DomainName.Split('.')) { $Parts.Add("DC=$Label") }
    return ($Parts -join ', ')
}

function Set-GPRegistryValueIfNeeded {
    <# 值不同才寫入 GPO 登錄設定；回傳 $true 表示有寫入。#>
    param(
        [Parameter(Mandatory)][string] $GpoName,
        [Parameter(Mandatory)][string] $Key,
        [Parameter(Mandatory)][string] $ValueName,
        [Parameter(Mandatory)][string] $Type,
        [Parameter(Mandatory)]         $Value
    )

    $Normalize = {
        param($V, $T)
        switch ($T) {
            'DWord'  { [int]$V }
            'Binary' { if ($V -is [byte[]]) { ($V | ForEach-Object { $_.ToString('X2') }) -join '' } else { [string]$V } }
            default  { [string]$V }
        }
    }

    $Current = Get-GPRegistryValue -Name $GpoName -Key $Key -ValueName $ValueName -ErrorAction SilentlyContinue
    if ($null -ne $Current -and
        (& $Normalize $Current.Value $Type) -eq (& $Normalize $Value $Type)) {
        return $false
    }

    Set-GPRegistryValue -Name $GpoName -Key $Key -ValueName $ValueName -Type $Type -Value $Value | Out-Null
    return $true
}

function Set-CertTemplateAcl {
    <#
      以 dsacls.exe 設定憑證範本 ACL，並於寫入後驗證；任何一步失敗回傳 $false。
      （[ADSI]...ObjectSecurity.AddAccessRule() 實測不會寫入，故不使用。）
        -Harden：停用繼承（/P:Y），移除繼承而來的 SYSTEM / Authenticated Users，
                 僅保留明確清單（管理群組 Full Control + Authenticated Users Read
                 + 指定對象 Read/Enroll/AutoEnrollment）。
                 Read 必須保留給 Authenticated Users，否則 CA 讀不到範本（Element not found）。
        未指定 -Harden：維持繼承，只替指定對象新增 Read/Enroll/AutoEnrollment。
      dsacls 的 CA; 後面必須用顯示名稱（Enroll / AutoEnrollment），不接受 GUID。
      Principals 一律為「不含網域前綴」的名稱（電腦帳號含結尾 $）。
    #>
    param(
        [Parameter(Mandatory)][string]   $TemplateDN,
        [Parameter(Mandatory)][string]   $NetBIOSDomain,
        [Parameter(Mandatory)][string[]] $EnrollPrincipals,
        [string[]] $FullControlPrincipals = @(),
        [string[]] $ReadOnlyPrincipals    = @(),
        [switch]   $Harden,
        [string]   $Indent = '    '
    )

    $RunDsacls = {
        param([string[]] $DsaclsArgs, [string] $What, [bool] $Tolerant = $false)
        $Out = & dsacls @DsaclsArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            if ($Tolerant) {
                Write-Host "${Indent}[INFO] $What 未變更（$(($Out | Out-String).Trim())）" -ForegroundColor DarkGray
                return $true
            }
            Write-Host "${Indent}[ERROR] $What 失敗：$(($Out | Out-String).Trim())" -ForegroundColor Red
            return $false
        }
        return $true
    }

    if ($Harden) {
        # 順序：先 /P:Y 讓繼承規則轉成此物件的顯式 ACE，之後 /R 才移除得掉。
        if (-not (& $RunDsacls @($TemplateDN, '/P:Y') 'dsacls /P:Y 停用繼承')) { return $false }
        foreach ($Sid in 'NT AUTHORITY\SYSTEM', 'NT AUTHORITY\Authenticated Users') {
            [void](& $RunDsacls @($TemplateDN, '/R', $Sid) "移除 $Sid" $true)
        }
        foreach ($Admin in $FullControlPrincipals) {
            if (-not (& $RunDsacls @($TemplateDN, '/G', "${NetBIOSDomain}\${Admin}:GA") "授予 $Admin Full Control")) { return $false }
        }
        if (-not (& $RunDsacls @($TemplateDN, '/G', 'Authenticated Users:GR') '授予 Authenticated Users Read')) { return $false }
    }

    foreach ($Reader in $ReadOnlyPrincipals) {
        if (-not (& $RunDsacls @($TemplateDN, '/G', "${NetBIOSDomain}\${Reader}:GR") "授予 $Reader Read")) { return $false }
    }
    foreach ($Target in $EnrollPrincipals) {
        foreach ($Grant in 'GR', 'CA;Enroll', 'CA;AutoEnrollment') {
            if (-not (& $RunDsacls @($TemplateDN, '/G', "${NetBIOSDomain}\${Target}:$Grant") "授予 $Target $Grant")) { return $false }
        }
    }

    # ── 寫入後驗證（重試以容忍 AD 讀取延遲）──
    $EnrollGuid     = [Guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
    $AutoEnrollGuid = [Guid]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'
    $Problems = @()
    for ($Try = 1; $Try -le 3; $Try++) {
        Start-Sleep -Seconds 3
        $Acl      = Get-Acl -Path "AD:\$TemplateDN"
        $Problems = @()

        if ($Harden) {
            if (-not $Acl.AreAccessRulesProtected) { $Problems += '繼承未停用' }
            if ($Acl.Access | Where-Object { $_.IdentityReference.Value -like '*\SYSTEM' -and $_.ActiveDirectoryRights -match 'GenericAll' }) {
                $Problems += 'SYSTEM 的 GenericAll 仍存在'
            }
        }
        foreach ($Target in $EnrollPrincipals) {
            foreach ($Right in @{ Name = 'Enroll'; Guid = $EnrollGuid }, @{ Name = 'AutoEnrollment'; Guid = $AutoEnrollGuid }) {
                $Found = $Acl.Access | Where-Object {
                    $_.AccessControlType -eq 'Allow' -and
                    $_.IdentityReference.Value -like "*\$Target" -and
                    $_.ActiveDirectoryRights -match 'ExtendedRight' -and
                    $_.ObjectType -eq $Right.Guid
                }
                if (-not $Found) { $Problems += "$Target 缺少 $($Right.Name)" }
            }
        }

        if ($Problems.Count -eq 0) { return $true }
        Write-Host "${Indent}[重試 $Try/3] 驗證未通過：$($Problems -join '；')" -ForegroundColor Yellow
    }

    Write-Host "${Indent}[ERROR] ACL 寫入後驗證失敗：$($Problems -join '；')" -ForegroundColor Red
    Write-Host "${Indent}        請以全新 PowerShell 視窗查證：(Get-Acl `"AD:\$TemplateDN`").Access" -ForegroundColor Red
    return $false
}

#endregion

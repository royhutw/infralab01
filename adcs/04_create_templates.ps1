# ============================================================
#  04_create_templates.ps1
#  建立 802.1x EAP-TLS 用途的憑證範本
#  範本一：EAP-TLS-Computer  （電腦憑證，有效期 1 年）
#  範本二：EAP-TLS-User      （使用者憑證，有效期 2 年）
#  範本三：EAP-TLS-NPS-Server（NPS 伺服器憑證，有效期 2 年）
#
#  建立方式：
#    複製內建範本再修改屬性（最可靠的方式）
#    Computer 來源範本：Machine（內建電腦範本）
#    User 來源範本    ：User（內建使用者範本）
#    NPS 來源範本     ：WebServer（內建 Web 伺服器範本）
#
#  所有範本設定：
#    - RSA 4096 金鑰
#    - SHA256 雜湊
#    - 自動核准（不需 CA Manager 審核）
#    - 支援 Auto-Enrollment
#
#  修正記錄：
#    v2：修正 pKIExpirationPeriod / pKIOverlapPeriod Bytes 端序問題
#        Windows FILETIME 格式使用小端序（Little-Endian），
#        移除錯誤的 [Array]::Reverse() 呼叫，確保有效期正確寫入
#
#    v3（本次修正，重要，含安全性修正）：
#      1. 【安全性修正】EAP-TLS-User 範本的 msPKI-Certificate-Name-Flag
#         原設定為 0x02000001，其中 0x00000001 依 MS-CRTD 官方規格
#         實際上是 CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT（讓申請端自行指定
#         Subject），而非原註解誤植的「CT_FLAG_SUBJECT_REQUIRE_COMMON_NAME」。
#         此設定搭配 Client Authentication EKU 且開放 Domain Users
#         Enroll 權限，構成 AD CS 已知的 ESC1 提權漏洞條件（任何網域使用者
#         皆可能自行指定憑證 Subject/SAN，偽裝成其他帳號）。
#         已修正為正確值 0x42000000（CT_FLAG_SUBJECT_REQUIRE_COMMON_NAME
#         + CT_FLAG_SUBJECT_ALT_REQUIRE_UPN）。
#      2. 修正 Computer / NPS 範本註解中的位元名稱標示錯誤（實際套用數值
#         0x18000000 本身正確，僅註解對照表寫錯，一併修正說明文字）。
#      3. 【最小權限修正】EAP-TLS-NPS-Server 範本的 Enroll/Autoenroll權限，
#         原設定授予 'Domain Computers'（網域所有電腦帳號），會導致所有
#         加入網域的電腦都嘗試自動申請 NPS 伺服器憑證，範圍過廣。
#         已改為建立專屬安全群組（NPS-Servers），僅將實際 NPS 伺服器的
#         電腦帳號加入此群組，並僅授權此群組 Enroll/Autoenroll。
# ============================================================

#region ── 參數區（請依實際環境修改） ────────────────────────
$Params = @{
    DomainName      = 'corp.foo.bar.tw'
    DomainDN        = 'DC=corp,DC=foo,DC=bar,DC=tw'

    # ── 來源範本名稱（內建範本，複製基礎用）────────────────
    SourceComputer  = 'Machine'     # 內建電腦範本
    SourceUser      = 'User'        # 內建使用者範本
    SourceNPS       = 'WebServer'   # 內建 Web 伺服器範本（含 Server Auth EKU）

    # ── 新範本名稱 ───────────────────────────────────────────
    ComputerTemplateName    = 'EAP-TLS-Computer'
    ComputerTemplateDisplay = 'EAP-TLS Computer Certificate'
    UserTemplateName        = 'EAP-TLS-User'
    UserTemplateDisplay     = 'EAP-TLS User Certificate'
    NPSTemplateName         = 'EAP-TLS-NPS-Server'
    NPSTemplateDisplay      = 'EAP-TLS NPS Server Certificate'

    # ── 金鑰設定 ─────────────────────────────────────────────
    KeyLength               = 4096

    # ── NPS 伺服器專屬安全群組（本次新增，用於最小權限控管）──
    #  請將實際兩台 NPS 伺服器的「電腦帳號名稱」填入下方陣列
    #  （AD Computer Name，不含網域尾碼、不含結尾的 $ 符號）
    NPSServersGroupName     = 'NPS-Servers'
    NPSServerComputerNames  = @('NPS01', 'NPS02')   # ← 請依實際主機名稱修改

    # ── 憑證有效期（Windows FILETIME 負值，單位：100 奈秒）──
    #
    #  格式說明：
    #    Windows 憑證範本使用負值 FILETIME 表示相對時間，
    #    計算公式：天數 × 24 × 3600 × 10,000,000（100奈秒/秒）
    #    並取負值（代表「從現在起往後」的時間間隔）
    #
    #  重要：BitConverter.GetBytes() 在 x64 Windows 上為小端序，
    #         不可再加 [Array]::Reverse()，否則 Windows 無法正確讀取
    #
    # Computer：1 年 = 365 天
    #   365 × 24 × 3600 × 10000000 = 315,360,000,000,000
    ComputerValidityTicks   = [long]-315360000000000

    # Computer Renewal：有效期 80% = 292 天
    #   292 × 24 × 3600 × 10000000 = 252,288,000,000,000
    ComputerRenewalTicks    = [long]-252288000000000

    # User / NPS：2 年 = 730 天
    #   730 × 24 × 3600 × 10000000 = 630,720,000,000,000
    UserValidityTicks       = [long]-630720000000000
    NPSValidityTicks        = [long]-630720000000000

    # User / NPS Renewal：有效期 80% = 584 天
    #   584 × 24 × 3600 × 10000000 = 504,576,000,000,000
    UserRenewalTicks        = [long]-504576000000000
    NPSRenewalTicks         = [long]-504576000000000
}
#endregion

# ── 確認並安裝 RSAT-AD-PowerShell ────────────────────────────
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Host "[前置] 安裝 RSAT-AD-PowerShell..." -ForegroundColor Yellow
    Install-WindowsFeature -Name 'RSAT-AD-PowerShell' -IncludeAllSubFeature | Out-Null
}

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  建立 802.1x EAP-TLS 憑證範本 v3"                  -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

# ── 載入模組 ─────────────────────────────────────────────────
Import-Module ActiveDirectory -ErrorAction Stop

# ── 取得 AD 設定 NC 路徑 ─────────────────────────────────────
$ConfigNC       = ([ADSI]"LDAP://RootDSE").configurationNamingContext
$TemplateBaseDN = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNC"

# ── 取得 CA Config ────────────────────────────────────────────
$CAConfig = (certutil -getconfig) |
    Where-Object { $_ -match '"(.+\\.+)"' } |
    ForEach-Object { $_ -replace '.*"(.+)".*', '$1' } |
    Select-Object -First 1
$CAConfig = $CAConfig.Trim()

if ([string]::IsNullOrWhiteSpace($CAConfig)) {
    Write-Host "[ERROR] 無法取得 CA Config，請確認 CertSvc 服務已啟動。" -ForegroundColor Red
    exit 1
}
Write-Host "[INFO] CA Config：$CAConfig" -ForegroundColor Gray
Write-Host ""

# ════════════════════════════════════════════════════════════
#  輔助函式：將 FILETIME Ticks 轉換為可讀時間（供確認用）
# ════════════════════════════════════════════════════════════
function ConvertFrom-FileTimeTicks {
    param([long]$Ticks)
    $AbsTicks = [Math]::Abs($Ticks)
    $Days     = [Math]::Round($AbsTicks / 10000000 / 86400, 1)
    $Years    = [Math]::Round($Days / 365, 2)
    return "$Days 天（約 $Years 年）"
}

# ════════════════════════════════════════════════════════════
#  核心函式：複製內建範本並修改屬性
# ════════════════════════════════════════════════════════════
function Copy-CertificateTemplate {
    param(
        [string] $SourceTemplateName,   # 來源內建範本名稱
        [string] $NewTemplateName,      # 新範本名稱（CN）
        [string] $NewDisplayName,       # 新範本顯示名稱
        [long]   $ValidityTicks,        # 有效期（負值 FILETIME Ticks，小端序）
        [long]   $RenewalTicks,         # 更新期（負值 FILETIME Ticks，小端序）
        [int]    $KeyLength,            # 金鑰長度
        [array]  $EKUList,              # 延伸金鑰用途 OID 清單
        [int]    $EnrollmentFlag,       # 申請旗標
        [int]    $NameFlag,             # 主體名稱旗標
        [bool]   $AutoEnroll = $true    # 是否啟用 Auto-Enrollment
    )

    Write-Host "  處理範本：$NewDisplayName" -ForegroundColor Gray
    Write-Host "    有效期：$(ConvertFrom-FileTimeTicks $ValidityTicks)" -ForegroundColor Gray
    Write-Host "    更新期：$(ConvertFrom-FileTimeTicks $RenewalTicks)" -ForegroundColor Gray

    # ── 確認目標範本是否已存在，若存在先刪除 ────────────────
    $ExistingDN = "CN=$NewTemplateName,$TemplateBaseDN"
    $Existing   = Get-ADObject -Filter { distinguishedName -eq $ExistingDN } `
                      -SearchBase $TemplateBaseDN -ErrorAction SilentlyContinue
    if ($Existing) {
        Write-Host "    [WARN] 範本已存在，刪除後重建..." -ForegroundColor Yellow
        Remove-ADObject -Identity $ExistingDN -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    # ── 取得來源範本 ──────────────────────────────────────────
    $SourceDN = "CN=$SourceTemplateName,$TemplateBaseDN"
    $Source   = Get-ADObject -Identity $SourceDN -Properties * -ErrorAction SilentlyContinue
    if ($null -eq $Source) {
        Write-Host "    [ERROR] 找不到來源範本：$SourceTemplateName" -ForegroundColor Red
        return $false
    }

    # ── 轉換 FILETIME Ticks 為 Byte Array（小端序，不做 Reverse）
    #
    #  重要修正說明：
    #    Windows 的 pKIExpirationPeriod 與 pKIOverlapPeriod 屬性
    #    儲存格式為 Little-Endian（小端序）FILETIME 負值。
    #    BitConverter.GetBytes() 在 x64 Windows 上預設產生小端序，
    #    因此「不需要」也「不可以」再呼叫 [Array]::Reverse()。
    #    若做了 Reverse 變成大端序，Windows 會讀到錯誤的時間值，
    #    導致 MMC 中顯示有效期為 0 或異常數值。
    #
    $ValidityBytes = [System.BitConverter]::GetBytes($ValidityTicks)
    # ← 不做 Reverse，保持小端序
    $RenewalBytes  = [System.BitConverter]::GetBytes($RenewalTicks)
    # ← 不做 Reverse，保持小端序

    # ── 金鑰用途：Digital Signature (0x80) + Key Encipherment (0x20) = 0xA0
    $KeyUsageBytes = [byte[]](0xA0, 0x00)

    # ── Auto-Enrollment 旗標 ──────────────────────────────────
    # 0x20 = CT_FLAG_AUTO_ENROLLMENT
    # 0x40 = CT_FLAG_AUTO_ENROLLMENT_CHECK_USER_DS_CERTIFICATE
    $FinalEnrollFlag = if ($AutoEnroll) {
        $EnrollmentFlag -bor 0x20
    } else {
        $EnrollmentFlag
    }

    # ── 產生唯一 OID（沿用來源 OID 加隨機後綴）──────────────
    #  OID 必須唯一且有效，CA 透過 OID 識別範本，
    #  格式：<來源 OID>.<隨機數字>
    $SourceOID    = $Source.'msPKI-Cert-Template-OID'
    $NewOIDSuffix = Get-Random -Minimum 1000000 -Maximum 9999999
    $NewOID       = "$SourceOID.$NewOIDSuffix"

    # ── 建立新範本的 AD 屬性集合 ─────────────────────────────
    $NewAttributes = @{

        # ── 基本識別 ─────────────────────────────────────────
        'displayName'   = $NewDisplayName
        'revision'      = '100'

        # flags 旗標說明：
        #   0x00000020 = CT_FLAG_AUTO_ENROLLMENT（允許 Auto-Enrollment）
        #   0x00000040 = CT_FLAG_MACHINE_TYPE（電腦類型範本）
        #   0x00020000 = CT_FLAG_IS_DEFAULT（預設範本）
        #   131680 = 0x00022260（IS_CA + PUBLISH_TO_DS + ADD_TEMPLATE_NAME）
        'flags'         = [int]131680

        # ── OID（必須唯一，CA 透過此欄位識別範本）───────────
        'msPKI-Cert-Template-OID' = $NewOID

        # ── 金鑰設定 ─────────────────────────────────────────
        # msPKI-Minimal-Key-Size：最小金鑰長度（bits）
        'msPKI-Minimal-Key-Size'  = $KeyLength

        # pKIDefaultKeySpec：
        #   1 = AT_KEYEXCHANGE（金鑰交換，用於加密與簽章）
        #   2 = AT_SIGNATURE（僅用於簽章）
        'pKIDefaultKeySpec'       = 1

        # ── 主體名稱旗標 ─────────────────────────────────────
        # 控制憑證的 Subject 與 SAN 來源
        'msPKI-Certificate-Name-Flag' = $NameFlag

        # ── 申請旗標（含 Auto-Enrollment）───────────────────
        # 控制憑證申請行為
        'msPKI-Enrollment-Flag'   = $FinalEnrollFlag

        # ── 核准設定 ─────────────────────────────────────────
        # msPKI-RA-Signature = 0：不需要 RA 簽章，自動核准
        # msPKI-RA-Signature > 0：需要指定數量的 RA 簽章才核准
        'msPKI-RA-Signature'      = 0

        # ── Schema 版本 ───────────────────────────────────────
        # 1 = Windows 2000（不支援 Auto-Enrollment）
        # 2 = Windows Server 2003（支援 Auto-Enrollment）← 本次使用
        # 3 = Windows Server 2008（支援額外功能）
        # 4 = Windows Server 2012（支援額外功能）
        'msPKI-Template-Schema-Version'   = 2
        'msPKI-Template-Minor-Revision'   = 1

        # ── 有效期與更新期（修正版：小端序，不做 Reverse）───
        #
        #  pKIExpirationPeriod：憑證有效期（負值 FILETIME，小端序）
        #  pKIOverlapPeriod   ：到期前多早開始嘗試更新（負值 FILETIME，小端序）
        #
        #  MMC 顯示邏輯：
        #    有效期 = |pKIExpirationPeriod| ÷ 10,000,000 ÷ 86,400（天）
        #    更新期 = |pKIOverlapPeriod|    ÷ 10,000,000 ÷ 86,400（天）
        #
        'pKIExpirationPeriod'     = $ValidityBytes
        'pKIOverlapPeriod'        = $RenewalBytes

        # ── 金鑰用途（KeyUsage）─────────────────────────────
        # 0xA0 = Digital Signature (0x80) + Key Encipherment (0x20)
        # EAP-TLS 需要 Digital Signature 進行相互認證
        # Key Encipherment 用於金鑰交換
        'pKIKeyUsage'             = $KeyUsageBytes

        # pKICriticalExtensions：標記為 Critical 的 OID 清單
        #   2.5.29.15 = KeyUsage（必須 Critical）
        #   2.5.29.19 = BasicConstraints
        'pKICriticalExtensions'   = @('2.5.29.15', '2.5.29.19')

        # ── EKU（延伸金鑰用途）───────────────────────────────
        # pKIExtendedKeyUsage：憑證 EKU 延伸中的 OID
        # msPKI-Certificate-Application-Policy：應用程式原則 OID（與 EKU 對應）
        'pKIExtendedKeyUsage'                   = $EKUList
        'msPKI-Certificate-Application-Policy'  = $EKUList

        # ── 預設 CSP（加密服務提供者）───────────────────────
        # 指定金鑰產生時使用的 CSP，優先順序由數字決定
        'pKIDefaultCSPs'          = @(
            '1,Microsoft RSA SChannel Cryptographic Provider',
            '2,Microsoft Strong Cryptographic Provider'
        )

        # ── 私鑰旗標 ─────────────────────────────────────────
        # 0x00000100 = CT_FLAG_EXPORTABLE_KEY 未設定（私鑰不可匯出）
        # EAP-TLS 安全考量：憑證私鑰不應允許匯出
        'msPKI-Private-Key-Flag'  = 0x00000100
    }

    # ── 在 AD 建立新範本物件 ──────────────────────────────────
    try {
        New-ADObject -Name            $NewTemplateName `
                     -Type            'pKICertificateTemplate' `
                     -Path            $TemplateBaseDN `
                     -OtherAttributes $NewAttributes `
                     -ErrorAction     Stop

        Write-Host "    [OK] 範本建立成功：$NewDisplayName" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "    [ERROR] 範本建立失敗：$($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ════════════════════════════════════════════════════════════
#  建立範本一：EAP-TLS-Computer（電腦憑證，有效期 1 年）
# ════════════════════════════════════════════════════════════
#
#  用途：已加入網域的電腦在使用者尚未登入前進行 802.1x 機器認證
#
#  EKU：
#    1.3.6.1.5.5.7.3.2 = Client Authentication（必要）
#
#  主體名稱旗標（msPKI-Certificate-Name-Flag，依MS-CRTD官方規格）：
#    0x08000000 = CT_FLAG_SUBJECT_ALT_REQUIRE_DNS
#                 （CA 依申請者電腦物件的 dNSHostName 屬性，
#                   將 FQDN 加入 Subject Alternative Name）
#    0x10000000 = CT_FLAG_SUBJECT_REQUIRE_DNS_AS_CN
#                 （Subject 的 CN 同樣採用 DNS 名稱）
#    合計 = 0x18000000
#
#  （此數值本身正確，僅原註解誤標位元名稱，已於本版修正說明文字）
#
#  申請旗標：
#    0x20 = CT_FLAG_AUTO_ENROLLMENT（Auto-Enrollment）
#
Write-Host "[1/3] 建立 EAP-TLS-Computer 範本（有效期 1 年）..." -ForegroundColor Yellow

Copy-CertificateTemplate `
    -SourceTemplateName $Params.SourceComputer `
    -NewTemplateName    $Params.ComputerTemplateName `
    -NewDisplayName     $Params.ComputerTemplateDisplay `
    -ValidityTicks      $Params.ComputerValidityTicks `
    -RenewalTicks       $Params.ComputerRenewalTicks `
    -KeyLength          $Params.KeyLength `
    -EKUList            @('1.3.6.1.5.5.7.3.2') `
    -EnrollmentFlag     0x00 `
    -NameFlag           0x18000000 `
    -AutoEnroll         $true

# ════════════════════════════════════════════════════════════
#  建立範本二：EAP-TLS-User（使用者憑證，有效期 2 年）
# ════════════════════════════════════════════════════════════
#
#  用途：AD 網域使用者登入後進行 802.1x 使用者身份認證
#
#  EKU：
#    1.3.6.1.5.5.7.3.2 = Client Authentication（必要）
#
#  主體名稱旗標（msPKI-Certificate-Name-Flag，依MS-CRTD官方規格）：
#    0x40000000 = CT_FLAG_SUBJECT_REQUIRE_COMMON_NAME
#                 （CN 由 CA 依申請者 AD 物件建構，而非申請端自行提供）
#    0x02000000 = CT_FLAG_SUBJECT_ALT_REQUIRE_UPN
#                 （CA 依申請者 AD 物件的 userPrincipalName 屬性，
#                   將 UPN 加入 Subject Alternative Name，供 NPS 比對）
#    合計 = 0x42000000
#
#  【重要安全性修正】
#    舊版誤用 0x02000001，其中 0x00000001 依官方規格實際上是
#    CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT（允許申請端自行指定 Subject），
#    而非「要求 Common Name」。此設定搭配 Client Authentication EKU
#    且開放 Domain Users 廣泛 Enroll 權限，構成 AD CS 已知的
#    ESC1 提權漏洞條件，任何網域使用者理論上可自行指定憑證 Subject/SAN，
#    偽裝成其他帳號身份。已修正為正確值 0x42000000，
#    確保 Subject/SAN 一律由 CA 依申請者本人的 AD 物件建構，
#    不允許申請端自行指定。
#
Write-Host ""
Write-Host "[2/3] 建立 EAP-TLS-User 範本（有效期 2 年）..." -ForegroundColor Yellow

Copy-CertificateTemplate `
    -SourceTemplateName $Params.SourceUser `
    -NewTemplateName    $Params.UserTemplateName `
    -NewDisplayName     $Params.UserTemplateDisplay `
    -ValidityTicks      $Params.UserValidityTicks `
    -RenewalTicks       $Params.UserRenewalTicks `
    -KeyLength          $Params.KeyLength `
    -EKUList            @('1.3.6.1.5.5.7.3.2') `
    -EnrollmentFlag     0x00 `
    -NameFlag           0x42000000 `
    -AutoEnroll         $true

# ════════════════════════════════════════════════════════════
#  建立範本三：EAP-TLS-NPS-Server（NPS 伺服器憑證，有效期 2 年）
# ════════════════════════════════════════════════════════════
#
#  用途：NPS（RADIUS）伺服器向 802.1x 用戶端出示的伺服器憑證
#        EAP-TLS 交握時用戶端會驗證此憑證以確認 RADIUS 伺服器身份
#
#  EKU：
#    1.3.6.1.5.5.7.3.1 = Server Authentication（NPS 必要）
#    1.3.6.1.5.5.7.3.2 = Client Authentication（部分情境需要）
#
#  主體名稱旗標（msPKI-Certificate-Name-Flag，依MS-CRTD官方規格）：
#    0x08000000 = CT_FLAG_SUBJECT_ALT_REQUIRE_DNS
#    0x10000000 = CT_FLAG_SUBJECT_REQUIRE_DNS_AS_CN
#    合計 = 0x18000000
#    SAN 包含 NPS 伺服器的 FQDN（如 nps01.corp.foo.bar.tw）
#
#  （此數值本身正確，僅原註解誤標位元名稱，已於本版修正說明文字）
#
Write-Host ""
Write-Host "[3/3] 建立 EAP-TLS-NPS-Server 範本（有效期 2 年）..." -ForegroundColor Yellow

Copy-CertificateTemplate `
    -SourceTemplateName $Params.SourceNPS `
    -NewTemplateName    $Params.NPSTemplateName `
    -NewDisplayName     $Params.NPSTemplateDisplay `
    -ValidityTicks      $Params.NPSValidityTicks `
    -RenewalTicks       $Params.NPSRenewalTicks `
    -KeyLength          $Params.KeyLength `
    -EKUList            @('1.3.6.1.5.5.7.3.1', '1.3.6.1.5.5.7.3.2') `
    -EnrollmentFlag     0x00 `
    -NameFlag           0x18000000 `
    -AutoEnroll         $true

# ── 等待 AD 複寫 ─────────────────────────────────────────────
Write-Host ""
Write-Host "[等待] 等待 AD 複寫完成（5 秒）..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# ── 確認三個範本已存在於 AD ──────────────────────────────────
Write-Host ""
Write-Host "[確認] 驗證範本屬性..." -ForegroundColor Yellow
$AllExist = $true

@(
    @{ Name = $Params.ComputerTemplateName; ExpectDays = 365 },
    @{ Name = $Params.UserTemplateName;     ExpectDays = 730 },
    @{ Name = $Params.NPSTemplateName;      ExpectDays = 730 }
) | ForEach-Object {
    $TemplateName = $_.Name
    $ExpectDays   = $_.ExpectDays
    $DN  = "CN=$TemplateName,$TemplateBaseDN"
    $Obj = Get-ADObject -Filter { distinguishedName -eq $DN } `
               -SearchBase $TemplateBaseDN `
               -Properties 'pKIExpirationPeriod','pKIOverlapPeriod','msPKI-Minimal-Key-Size','msPKI-Enrollment-Flag','msPKI-Certificate-Name-Flag' `
               -ErrorAction SilentlyContinue

    if ($Obj) {
        # 將 Byte Array 轉回 Ticks，計算實際天數
        $ExpiryTicks  = [System.BitConverter]::ToInt64($Obj.'pKIExpirationPeriod', 0)
        $RenewalTicks = [System.BitConverter]::ToInt64($Obj.'pKIOverlapPeriod', 0)
        $ActualDays   = [Math]::Round([Math]::Abs($ExpiryTicks) / 10000000 / 86400, 0)
        $ActualRenew  = [Math]::Round([Math]::Abs($RenewalTicks) / 10000000 / 86400, 0)

        Write-Host ""
        Write-Host "  [$TemplateName]" -ForegroundColor Cyan
        Write-Host "    有效期       ：$ActualDays 天（預期 $ExpectDays 天）" -ForegroundColor $(if ($ActualDays -eq $ExpectDays) {'Green'} else {'Red'})
        Write-Host "    更新期       ：$ActualRenew 天前開始更新" -ForegroundColor Gray
        Write-Host "    最小金鑰長度 ：$($Obj.'msPKI-Minimal-Key-Size') bits" -ForegroundColor Gray
        Write-Host "    申請旗標     ：0x$($Obj.'msPKI-Enrollment-Flag'.ToString('X'))" -ForegroundColor Gray
        Write-Host "    主體名稱旗標 ：0x$($Obj.'msPKI-Certificate-Name-Flag'.ToString('X'))" -ForegroundColor Gray

        if ($ActualDays -ne $ExpectDays) {
            Write-Host "    [ERROR] 有效期與預期不符！" -ForegroundColor Red
            $AllExist = $false
        }

        # ── 額外檢查：確認 User 範本沒有殘留危險的 ENROLLEE_SUPPLIES_SUBJECT 旗標
        if ($TemplateName -eq $Params.UserTemplateName) {
            $NameFlagValue = [int]$Obj.'msPKI-Certificate-Name-Flag'
            if ($NameFlagValue -band 0x00000001) {
                Write-Host "    [ERROR] 偵測到 CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT 仍被設定！這是安全性風險，請立即檢查！" -ForegroundColor Red
                $AllExist = $false
            } else {
                Write-Host "    [OK] 未偵測到 ENROLLEE_SUPPLIES_SUBJECT 旗標，Subject 由 CA 依 AD 資訊建構。" -ForegroundColor Green
            }
        }
    } else {
        Write-Host "  [ERROR] 找不到範本：$TemplateName" -ForegroundColor Red
        $AllExist = $false
    }
}

if (-not $AllExist) {
    Write-Host ""
    Write-Host "[ERROR] 部分範本建立失敗或屬性不正確，請檢查上方錯誤訊息。" -ForegroundColor Red
    exit 1
}

# ── 發布範本至 CA ─────────────────────────────────────────────
Write-Host ""
Write-Host "[發布] 將範本加入 CA 發布清單..." -ForegroundColor Yellow

$TemplateList = "$($Params.ComputerTemplateName),$($Params.UserTemplateName),$($Params.NPSTemplateName)"
certutil -config $CAConfig -setcatemplates "+$TemplateList" | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "      [WARN] 嘗試逐一發布..." -ForegroundColor Yellow
    @($Params.ComputerTemplateName, $Params.UserTemplateName, $Params.NPSTemplateName) |
        ForEach-Object {
            certutil -config $CAConfig -setcatemplates "+$_" | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "      [OK] 已發布：$_" -ForegroundColor Green
            } else {
                Write-Host "      [ERROR] 發布失敗：$_" -ForegroundColor Red
            }
        }
} else {
    @($Params.ComputerTemplateName, $Params.UserTemplateName, $Params.NPSTemplateName) |
        ForEach-Object { Write-Host "      [OK] 已發布：$_" -ForegroundColor Green }
}

# ════════════════════════════════════════════════════════════
#  建立 NPS 伺服器專屬安全群組（本次新增，最小權限控管）
# ════════════════════════════════════════════════════════════
#
#  目的：EAP-TLS-NPS-Server 範本僅應由實際的 NPS 伺服器申請，
#        不應開放給 Domain Computers（所有網域電腦）。
#        建立專屬群組，僅將實際 NPS 伺服器的電腦帳號加入，
#        後續範本 ACL 僅授權此群組。
#
Write-Host ""
Write-Host "[群組] 建立 NPS 伺服器專屬安全群組..." -ForegroundColor Yellow

$ExistingGroup = Get-ADGroup -Filter "Name -eq '$($Params.NPSServersGroupName)'" -ErrorAction SilentlyContinue
if ($null -eq $ExistingGroup) {
    New-ADGroup -Name $Params.NPSServersGroupName `
                -SamAccountName $Params.NPSServersGroupName `
                -GroupCategory Security `
                -GroupScope Global `
                -Description 'NPS RADIUS 伺服器電腦帳號 - 僅此群組可申請 EAP-TLS-NPS-Server 憑證' `
                -ErrorAction Stop
    Write-Host "      [OK] 群組已建立：$($Params.NPSServersGroupName)" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] 群組已存在：$($Params.NPSServersGroupName)" -ForegroundColor Yellow
}

foreach ($ComputerName in $Params.NPSServerComputerNames) {
    try {
        $ComputerObj = Get-ADComputer -Identity $ComputerName -ErrorAction Stop
        $IsMember = Get-ADGroupMember -Identity $Params.NPSServersGroupName -ErrorAction SilentlyContinue |
                        Where-Object { $_.SamAccountName -eq $ComputerObj.SamAccountName }
        if ($null -eq $IsMember) {
            Add-ADGroupMember -Identity $Params.NPSServersGroupName -Members $ComputerObj -ErrorAction Stop
            Write-Host "      [OK] 已加入群組：$ComputerName" -ForegroundColor Green
        } else {
            Write-Host "      [SKIP] 已是群組成員：$ComputerName" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "      [ERROR] 找不到電腦帳號或加入失敗：$ComputerName - $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "      [提醒] 請確認 `$Params.NPSServerComputerNames` 內的名稱與實際 AD 電腦帳號名稱相符" -ForegroundColor Yellow
    }
}

# ── 等待 AD 複寫（群組成員異動需要時間生效）───────────────────
Write-Host ""
Write-Host "[等待] 等待 AD 群組成員複寫完成（5 秒）..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# ── 設定範本 ACL ─────────────────────────────────────────────
Write-Host ""
Write-Host "[ACL] 設定範本存取權限..." -ForegroundColor Yellow

# Enroll OID      ：0e10c968-78fb-11d2-90d4-00c04f79dc55
# Auto-Enroll OID ：a05b8cc2-17bc-4802-a710-e7c15ab866a2
$EnrollGUID     = [GUID]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
$AutoEnrollGUID = [GUID]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'

function Set-TemplateACL {
    param(
        [string] $TemplateName,
        [string] $PrincipalName,
        [string] $DomainName
    )

    $TemplateDN  = "LDAP://CN=$TemplateName,$TemplateBaseDN"
    $TemplateObj = [ADSI]$TemplateDN
    $Principal   = New-Object System.Security.Principal.NTAccount($DomainName, $PrincipalName)

    # Read 權限（Auto-Enrollment 需要讀取範本內容）
    $ACE_Read = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $Principal,
        [System.DirectoryServices.ActiveDirectoryRights]::GenericRead,
        [System.Security.AccessControl.AccessControlType]::Allow,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    )

    # Enroll 權限（申請憑證）
    $ACE_Enroll = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $Principal,
        [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
        [System.Security.AccessControl.AccessControlType]::Allow,
        $EnrollGUID,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    )

    # Auto-Enroll 權限（自動申請與更新）
    $ACE_AutoEnroll = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $Principal,
        [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight,
        [System.Security.AccessControl.AccessControlType]::Allow,
        $AutoEnrollGUID,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    )

    $TemplateObj.ObjectSecurity.AddAccessRule($ACE_Read)
    $TemplateObj.ObjectSecurity.AddAccessRule($ACE_Enroll)
    $TemplateObj.ObjectSecurity.AddAccessRule($ACE_AutoEnroll)
    $TemplateObj.CommitChanges()
}

# Computer 範本：Domain Computers → Enroll + Auto-Enroll
# （此範本設計上就是要給所有網域電腦做802.1x機器認證用，Domain Computers 是正確範圍）
Set-TemplateACL -TemplateName  $Params.ComputerTemplateName `
                -PrincipalName 'Domain Computers' `
                -DomainName    $Params.DomainName
Write-Host "      [OK] $($Params.ComputerTemplateName)：Domain Computers → Read + Enroll + Auto-Enroll" -ForegroundColor Green

# User 範本：Domain Users → Enroll + Auto-Enroll
Set-TemplateACL -TemplateName  $Params.UserTemplateName `
                -PrincipalName 'Domain Users' `
                -DomainName    $Params.DomainName
Write-Host "      [OK] $($Params.UserTemplateName)：Domain Users → Read + Enroll + Auto-Enroll" -ForegroundColor Green

# NPS 範本：僅授權 NPS-Servers 專屬群組（最小權限修正，取代原本的 Domain Computers）
Set-TemplateACL -TemplateName  $Params.NPSTemplateName `
                -PrincipalName $Params.NPSServersGroupName `
                -DomainName    $Params.DomainName
Write-Host "      [OK] $($Params.NPSTemplateName)：$($Params.NPSServersGroupName) → Read + Enroll + Auto-Enroll" -ForegroundColor Green
Write-Host "      [安全性修正] NPS範本已改為僅授權專屬群組，不再開放給 Domain Computers" -ForegroundColor Cyan

# ── 最終確認：CA 已發布的範本清單 ────────────────────────────
Write-Host ""
Write-Host "[最終確認] CA 目前已發布的範本清單：" -ForegroundColor Yellow
certutil -config $CAConfig -catemplates

Write-Host @"

==================================================
  憑證範本建立完成！（v3，含安全性修正）
  已建立範本：
    - $($Params.ComputerTemplateName)（1 年，電腦 Auto-Enrollment，範圍：Domain Computers）
    - $($Params.UserTemplateName)（2 年，使用者 Auto-Enrollment，範圍：Domain Users）
      → NameFlag 已修正為 0x42000000，Subject/SAN 一律由 CA 依 AD 資訊建構
    - $($Params.NPSTemplateName)（2 年，NPS 伺服器，範圍：$($Params.NPSServersGroupName) 群組）
      → 已限縮權限，僅群組成員可申請，不再開放給所有網域電腦

  【重要提醒】若此前已使用舊版 v2 腳本建立過範本並已核發憑證：
    1. 請確認是否已有使用者透過舊版 EAP-TLS-User 範本取得憑證
    2. 建議至 CA「Issued Certificates」檢視該期間核發的憑證 Subject/SAN 是否異常
    3. 撤銷舊憑證，待範本修正後透過 Autoenrollment 重新核發
    4. 若先前已將 Domain Computers 加入 NPS 範本 ACL 且已有非 NPS 伺服器的電腦
       取得該憑證，建議一併檢視 CA 核發記錄並考慮撤銷不必要的憑證

  若 MMC 中看不到範本，請在 AD CS MMC 中：
    Certificate Templates → 右鍵 → Refresh

  驗證有效期是否正確（在 MMC 中確認）：
    certtmpl.msc
    → 右鍵範本 → Properties
    → Validity Period 應顯示 1 year / 2 years
    → Renewal Period 應顯示 292 days / 584 days

  驗證 User 範本 Subject Name 頁籤（重要）：
    → 應勾選「Build from this Active Directory information」
    → Subject name format 應顯示「Common name」
    → 「Include this information in alternate subject name」下
      「User principal name (UPN)」應為勾選狀態

  下一步：執行 05_configure_autoenrollment_gpo.ps1 設定 GPO
==================================================
"@ -ForegroundColor Green
# ============================================================
#  CAConfig.psd1
#  AD CS Enterprise Subordinate CA 共用參數設定檔（唯一參數來源）
#
#  【使用規則】
#    1. 所有 01~07、Publish-SubCACRL、Register-CRLScheduledTask
#       等腳本一律從本檔案讀取參數，不要在個別腳本內另外寫死數值。
#    2. 本檔案必須與所有 .ps1 放在同一目錄（各腳本以 $PSScriptRoot
#       自動定位，不需額外設定路徑）。
#    3. 同一個值只在這裡出現一次；例如 DomainName、CACommonName、
#       DN 欄位、DSC 加密憑證指紋，都是多支腳本共用讀取同一個
#       區塊，避免像過去那樣同一個值在好幾個檔案裡各自維護一份、
#       改一處忘了改另一處。
#    4. 區塊（Section）命名對應各腳本用途，各腳本開頭的載入區會
#       註明它實際使用哪幾個區塊，方便追查某個值被誰使用。
# ============================================================

@{
    # ── 全域共用（跨多支腳本）─────────────────────────────────
    Global = @{
        DomainName        = 'corp.foo.bar.tw'
        NetBIOSDomainName = 'CORP'                          # dsacls.exe 等工具需要 NetBIOS 格式網域名稱
        DomainDN          = 'DC=corp,DC=foo,DC=bar,DC=tw'
        CACommonName      = 'corp-foo-bar-tw-SubCA'

        # 前置檔案交換用的本機目錄（CSR / 簽回憑證 / Root CA 憑證存放處）
        CAConfigDir       = 'C:\CAConfig'

        # CRL / AIA 發布
        CRLPublishPath    = 'C:\CRLPublish'                 # IIS 靜態目錄需指向此路徑
        CDPHttpUrl        = 'http://crl.corp.foo.bar.tw/CRL'
        AIAHttpUrl        = 'http://crl.corp.foo.bar.tw/AIA'
    }

    # ── Root CA 憑證 DN 欄位 ─────────────────────────────────
    # 【重要】這裡的值必須與離線 Root CA 那邊 ca-env.bat 的
    # CA_COUNTRY / CA_ORG / CA_STATE / CA_LOCALITY / CA_OU 完全一致
    # （大小寫亦須相符），否則 Root CA 的 openssl-rootca.cnf
    # policy_strict 會拒絕簽署本 Sub CA 的 CSR。
    # 01（初次安裝）與 07（憑證更新）共用此區塊，過去這兩支腳本
    # 各自寫一份，容易改一邊忘了改另一邊，現在統一成一份。
    RootCADN = @{
        CACountry      = 'TW'
        CAOrganization = 'MyOrg Ltd'
        CAState        = ''    # 選填，留空則不加入 DN
        CALocality     = ''    # 選填，留空則不加入 DN
        CAOU           = ''    # 選填，留空則不加入 DN
    }

    # ── DSC Credential 加密憑證（01 安裝 / 07 更新 共用）──────
    DSCCredential = @{
        CertificateThumbprint = 'YOUR_CERTIFICATE_THUMBPRINT_HERE'  # ← 請修改
        CertificatePath       = 'C:\DSC\DSC_Credential_Encryption.cer'
    }

    # ── 前置檔案交換路徑（01 產生 / 02 消費 / 06 亦讀取）─────
    ExchangePaths = @{
        CSROutputPath  = 'C:\CAConfig\SubCA.req'      # 01 產生的 CSR，帶去 Root CA 簽
        SignedCertPath = 'C:\CAConfig\SubCA.crt'      # Root CA 簽回，02 安裝用
        RootCACertPath = 'C:\CAConfig\RootCA.crt'     # 事先從 Root CA VM 複製過來
        RootCACRLPath  = 'C:\CAConfig\RootCA.crl'     # 事先從 Root CA VM 複製過來
    }

    # ── 01_install_adcs_dsc.ps1 專用 ─────────────────────────
    ADCSInstall = @{
        KeyLength     = 4096
        HashAlgorithm = 'SHA256'
    }

    # ── CRL 基本週期（01 DSC 安裝時記錄的預期值 / 03 實際套用）─
    # 【提醒，非修正但請留意】01 的 DSC 設定（AdcsCertificationAuthority
    # 資源）目前並未使用這組 CRL 週期值——AD CS 的 CRL 週期是安裝完
    # 成後才透過 03_configure_cdp_aia.ps1 用 certutil -setreg 寫入，
    # 這裡保留給 01 只是方便對照「稍後 03 會設成多少」，實際生效
    # 位置仍是 03。過去兩邊各寫一份剛好數值一致純屬巧合，現在併成
    # 一份可避免未來改了一邊、另一邊沒同步更新的風險。
    CRLPolicy = @{
        CRLPeriodUnits      = 1
        CRLPeriod           = 'Weeks'      # Days / Weeks / Months
        CRLDeltaPeriodUnits = 1
        CRLDeltaPeriod      = 'Days'
    }

    # ── 03_configure_cdp_aia.ps1 專用（CRLPolicy 之外的設定）─
    CDPAIA = @{
        CRLOverlapUnits     = 12           # CRL 重疊緩衝期（小時），確保新舊 CRL 銜接
        CRLOverlapPeriod    = 'Hours'
        ValidityPeriodUnits = 2            # CA 簽發憑證的最大有效期：Computer 1年 + User 2年，取較大值
        ValidityPeriod      = 'Years'
    }

    # ── 04_create_templates.ps1 專用 ─────────────────────────
    Templates = @{
        # ── 來源範本名稱（內建範本，複製基礎用）────────────
        SourceComputer = 'Machine'
        SourceUser     = 'User'
        SourceNPS      = 'WebServer'

        # ── 新範本名稱 ───────────────────────────────────────
        ComputerTemplateName    = 'EAP-TLS-Computer'
        ComputerTemplateDisplay = 'EAP-TLS Computer Certificate'
        UserTemplateName        = 'EAP-TLS-User'
        UserTemplateDisplay     = 'EAP-TLS User Certificate'
        NPSTemplateName         = 'EAP-TLS-NPS-Server'
        NPSTemplateDisplay      = 'EAP-TLS NPS Server Certificate'

        KeyLength = 4096

        # ── NPS 伺服器專屬安全群組（用於最小權限控管）────────
        # 請將實際 NPS 伺服器的「電腦帳號名稱」填入下方陣列
        # （AD Computer Name，不含網域尾碼、不含結尾的 $ 符號）
        NPSServersGroupName    = 'NPS-Servers'
        NPSServerComputerNames = @('RADIUS1')   # ← 目前僅一台，日後新增請把主機名稱加進此陣列

        # ── 憑證有效期 / 更新期（Windows FILETIME 負值 Ticks）──
        # 計算公式與 75% 更新期上限的說明，保留在 04 腳本本文內
        # （v4 修正記錄），此處只放最終數值，方便與腳本內註解對照。
        ComputerValidityTicks = -315360000000000    # 365 天
        ComputerRenewalTicks  = -236520000000000    # 273.75 天（= 365 天 × 75%）
        UserValidityTicks     = -630720000000000    # 730 天
        NPSValidityTicks      = -630720000000000    # 730 天
        UserRenewalTicks      = -473040000000000    # 547.5 天（= 730 天 × 75%）
        NPSRenewalTicks       = -473040000000000    # 547.5 天（= 730 天 × 75%）
    }

    # ── 05_configure_autoenrollment_gpo.ps1 專用 ─────────────
    # GPO 連結目標一律使用 Global.DomainDN（網域根層級），
    # 不再另外重複定義一份一樣的 DN 字串。
    AutoEnrollGPO = @{
        ComputerGPOName = 'PKI - EAP-TLS Computer Auto-Enrollment'
        UserGPOName     = 'PKI - EAP-TLS User Auto-Enrollment'
    }

    # ── 06_Deploy-RootCACert.ps1 專用 ─────────────────────────
    DeployRootCAGPO = @{
        GPOName    = 'PKI - Deploy Root CA Certificate'
        GPOComment = '部署 Root CA 憑證至所有電腦受信任根憑證存放區'
        # GPO 內部固定使用的登錄路徑，這是 Windows 憑證原則的
        # 標準寫入位置，一般不需修改
        TrustedRootStore = 'HKLM\SOFTWARE\Policies\Microsoft\SystemCertificates\Root\Certificates'
    }

    # ── 07_renew_subcacert.ps1 專用（Renewal 特有路徑）───────
    # CACommonName / DN 欄位 / DSC 憑證均與 01 共用（見上方區塊），
    # 這裡只放 Renewal 流程獨有、且必須與初次安裝路徑區分的設定。
    SubCARenewal = @{
        RenewalCSROutputPath = 'C:\CAConfig\SubCA_renewal.req'
        BackupPath           = 'C:\CAConfig\Backup'
    }

    # ── Publish-SubCACRL.ps1 專用 ─────────────────────────────
    CRLPublish = @{
        LogPath          = 'C:\CAConfig\Logs\CRL_Publish.log'
        LogRetentionDays = 90
        CertEnrollPath   = 'C:\Windows\System32\CertSrv\CertEnroll'

        # 【提醒，非修正但請留意】此值目前未被腳本本文實際使用
        # （腳本只發布 CRL，尚未實作到期前提早警示的邏輯），
        # 保留參數位置以便未來擴充，避免又要重新找地方定義它。
        CRLExpiryWarningDays = 3
    }

    # ── Register-CRLScheduledTask.ps1 專用 ────────────────────
    CRLScheduledTask = @{
        TaskName        = 'PKI - Publish Subordinate CA CRL'
        TaskDescription = '每週定時發布 Subordinate CA CRL，確保憑證撤銷清單持續有效'
        TaskPath        = '\PKI\'
        ScriptPath      = 'C:\CAConfig\Publish-SubCACRL.ps1'
        TriggerDay      = 'Monday'
        TriggerTime     = '02:00'
        RunAsUser       = 'SYSTEM'
    }
}

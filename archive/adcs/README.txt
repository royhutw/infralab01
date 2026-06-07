================================================================
  AD CS Enterprise Subordinate CA 部署指南
  用途：802.1x EAP-TLS 電腦與使用者憑證
  架構：離線 Root CA → Enterprise Sub CA（corp.foo.bar.tw）
================================================================

一、檔案清單與執行順序
────────────────────────────────────────────────────────────────
  01_install_adcs_dsc.ps1          安裝 AD CS 角色，產生 CSR
  02_install_subcacert.ps1         安裝 Root CA 簽回的憑證
  03_configure_cdp_aia.ps1         設定 CDP / AIA 發布點
  04_create_templates.ps1          建立 EAP-TLS 憑證範本
  05_configure_autoenrollment_gpo.ps1  設定 Auto-Enrollment GPO


二、完整部署流程
────────────────────────────────────────────────────────────────

  [AD CS 伺服器] 加入網域、設定靜態 IP、設定 Hostname
        ↓
  [AD CS 伺服器] 準備前置檔案到 C:\CAConfig\：
        - RootCA.crt     （從離線 Root CA VM 複製）
        - RootCA.crl     （從離線 Root CA VM 複製）
        ↓
  [AD CS 伺服器] 執行 01_install_adcs_dsc.ps1
        → 安裝 AD CS 角色
        → 產生 CSR 至 C:\CAConfig\SubCA.req
        ↓
  [USB] 將 SubCA.req 複製到 USB，帶到離線 Root CA VM
        ↓
  [Root CA VM] 將 SubCA.req 複製至 C:\RootCA\requests\intermediateCA.csr
               執行 02_sign_intermediate.bat
               取得簽回的 intermediateCA.crt
        ↓
  [USB] 將 intermediateCA.crt 複製回 AD CS 伺服器
        改名為 C:\CAConfig\SubCA.crt
        ↓
  [AD CS 伺服器] 執行 02_install_subcacert.ps1
        → 安裝 Sub CA 憑證，啟動 CA 服務
        ↓
  [AD CS 伺服器] 執行 03_configure_cdp_aia.ps1
        → 設定 CRL 發布點、AIA、更新週期
        ↓
  [AD CS 伺服器] 設定 IIS 提供 CRL/AIA 靜態下載
        （見下方 IIS 設定說明）
        ↓
  [AD CS 伺服器] 執行 04_create_templates.ps1
        → 建立三個憑證範本
        ↓
  [DC 或 AD CS 伺服器] 執行 05_configure_autoenrollment_gpo.ps1
        → 建立並套用 Auto-Enrollment GPO
        ↓
  [用戶端] gpupdate /force
        → 自動申請 EAP-TLS 電腦與使用者憑證


三、憑證範本說明
────────────────────────────────────────────────────────────────
  ┌────────────────────┬────────┬──────────────────────┬──────────┐
  │ 範本名稱              │ 有效期  │ 套用對象              │ 核准方式  │
  ├────────────────────┼────────┼──────────────────────┼──────────┤
  │ EAP-TLS-Computer    │ 1 年   │ 加入網域的電腦         │ 自動核准  │
  │ EAP-TLS-User        │ 2 年   │ 網域使用者             │ 自動核准  │
  │ EAP-TLS-NPS-Server  │ 2 年   │ NPS/RADIUS 伺服器     │ 自動核准  │
  └────────────────────┴────────┴──────────────────────┴──────────┘

  EKU（延伸金鑰用途）OID：
    電腦 / 使用者憑證：1.3.6.1.5.5.7.3.2（Client Authentication）
    NPS 伺服器憑證   ：1.3.6.1.5.5.7.3.1（Server Authentication）
                       1.3.6.1.5.5.7.3.2（Client Authentication）


四、IIS 設定（CRL/AIA 發布用）
────────────────────────────────────────────────────────────────
  在 AD CS 伺服器（或獨立 Web 伺服器）設定 IIS：

  1. 建立虛擬目錄，實體路徑指向 C:\CRLPublish
     虛擬路徑：/CRL
               /AIA

  2. 開放 .crl 和 .crt 的 MIME 類型：
     .crl → application/pkix-crl
     .crt → application/x-x509-ca-cert

  3. 確認 DNS 解析：
     pki.corp.foo.bar.tw → AD CS 伺服器 IP

  PowerShell 快速設定 IIS：
  ─────────────────────────
    Install-WindowsFeature Web-Server -IncludeManagementTools

    # 建立 CRL 虛擬目錄
    New-WebVirtualDirectory -Site 'Default Web Site' `
        -Name 'CRL' -PhysicalPath 'C:\CRLPublish'

    # 新增 MIME 類型
    Add-WebConfigurationProperty -PSPath 'IIS:\Sites\Default Web Site' `
        -Filter 'system.webServer/staticContent' `
        -Name '.' `
        -Value @{fileExtension='.crl'; mimeType='application/pkix-crl'}

    Add-WebConfigurationProperty -PSPath 'IIS:\Sites\Default Web Site' `
        -Filter 'system.webServer/staticContent' `
        -Name '.' `
        -Value @{fileExtension='.crt'; mimeType='application/x-x509-ca-cert'}


五、NPS 伺服器後續設定（獨立伺服器）
────────────────────────────────────────────────────────────────
  1. 將 NPS 伺服器加入 corp.foo.bar.tw 網域
  2. 執行 gpupdate /force 自動申請 EAP-TLS-NPS-Server 憑證
  3. 在 NPS 中設定 802.1x 原則時，選擇此憑證做為伺服器憑證
  4. 在 NPS 設定「受信任根 CA」為 corp-foo-bar-tw-SubCA


六、CRL 發布排程
────────────────────────────────────────────────────────────────
  Sub CA CRL：每週自動更新（certutil -crl 或排程工作）
  Root CA CRL：每年手動上線更新（執行 Root CA 的 03_renew_crl.bat）

  建議設定 Windows 排程工作定期執行：
    certutil -crl
    xcopy C:\Windows\System32\CertSrv\CertEnroll\*.crl C:\CRLPublish\ /Y


七、驗證指令
────────────────────────────────────────────────────────────────
  # 確認 CA 狀態
  certutil -ping

  # 確認 CRL 有效性
  certutil -verify -urlfetch C:\CRLPublish\*.crl

  # 確認用戶端電腦已申請到憑證
  certlm.msc → Personal → Certificates

  # 確認使用者已申請到憑證
  certmgr.msc → Personal → Certificates

  # 查看 Auto-Enrollment 事件記錄
  Get-WinEvent -LogName 'Microsoft-Windows-CertificateServicesClient-AutoEnrollment/Operational'

================================================================

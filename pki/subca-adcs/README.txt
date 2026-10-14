================================================================
  AD CS Enterprise Subordinate CA 部署指南
  用途：802.1x EAP-TLS 電腦與使用者憑證
  架構：離線 Root CA → Enterprise Sub CA（corp.foo.bar.tw）
================================================================

一、檔案清單與執行順序
────────────────────────────────────────────────────────────────
  CAConfig.psd1                    共用參數設定檔（唯一參數來源，
                                    所有 .ps1 皆從此讀取，請勿在個別
                                    腳本內另外寫死參數）
  Import-CAConfig.ps1              共用參數載入器（各腳本自動呼叫，
                                    不需要手動執行）

  ── 初次部署（依序執行）──────────────────────────────────────
  01_install_adcs_dsc.ps1          安裝 AD CS 角色，產生 CSR
  02_install_subcacert.ps1         安裝 Root CA 簽回的憑證
  03_configure_cdp_aia.ps1         設定 CDP / AIA 發布點
  04_create_templates.ps1          建立 EAP-TLS 憑證範本
  05_configure_autoenrollment_gpo.ps1  設定憑證 Auto-Enrollment GPO
  06_Deploy-RootCACert.ps1         透過 GPO 部署 Root CA 憑證至所有電腦

  ── 上線後定期維運 ────────────────────────────────────────────
  Publish-SubCACRL.ps1             Sub CA CRL 定期發布（供排程呼叫）
  Register-CRLScheduledTask.ps1    建立每週執行 Publish-SubCACRL.ps1
                                    的 Windows 排程工作（只需執行一次）

  ── Sub CA 憑證到期 / 需要換金鑰時 ──────────────────────────
  07_renew_subcacert.ps1           重新產生 Private Key 與 CSR，
                                    完成後回到「二、完整部署流程」的
                                    Root CA 簽發與 02、03 步驟重新走一次

  【重要】所有網域名稱 / CA 名稱 / DN 欄位 / 路徑 / GPO 名稱 /
  排程時間等設定，一律只在 CAConfig.psd1 修改，不要在個別 .ps1
  裡另外修改，以免出現兩份不一致的設定值。CAConfig.psd1 與
  Import-CAConfig.ps1 必須跟所有 .ps1 放在同一個目錄。


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
  [DC 或 AD CS 伺服器] 執行 06_Deploy-RootCACert.ps1
        → 透過 GPO 將 Root CA 憑證部署到網域所有電腦的
          「受信任的根憑證授權單位」存放區
          （用戶端需信任 Root CA，才能真正信任 Sub CA 簽發的憑證）
        ↓
  [AD CS 伺服器] 將 Publish-SubCACRL.ps1 複製到 C:\CAConfig\，
                 執行 Register-CRLScheduledTask.ps1
        → 建立每週一凌晨 02:00 自動發布 Sub CA CRL 的排程工作
          （CRL 有效期僅 1 週，務必設定排程，否則到期後
            用戶端會因無法驗證憑證是否遭撤銷而拒絕連線）
        ↓
  [用戶端] gpupdate /force
        → 自動信任 Root CA、自動申請 EAP-TLS 電腦與使用者憑證


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
  Sub CA CRL：每週自動更新
    → 由 Register-CRLScheduledTask.ps1 建立的排程工作，
      每週一凌晨 02:00 自動執行 Publish-SubCACRL.ps1
      （見「一、檔案清單」的「上線後定期維運」）
    手動立即執行一次：
      Start-ScheduledTask -TaskName 'PKI - Publish Subordinate CA CRL' `
          -TaskPath '\PKI\'
    查看執行紀錄：
      Get-Content 'C:\CAConfig\Logs\CRL_Publish.log' -Tail 50

  Root CA CRL：每年手動上線更新（執行 Root CA 的 03_renew_crl.bat）


七、Sub CA 憑證更新（Renewal）
────────────────────────────────────────────────────────────────
  適用時機：Sub CA 憑證即將到期、需要更換 CDP/AIA URL、
            或基於安全考量主動汰換金鑰時。

  [AD CS 伺服器] 執行 07_renew_subcacert.ps1
        → 停止 CA 服務、備份現有憑證、清除舊憑證與金鑰、
          產生全新 Private Key 與 CSR
        ↓
  [USB] 將新 CSR 複製到離線 Root CA VM：
        C:\RootCA\requests\intermediateCA.csr
        ↓
  [Root CA VM] 若需更換 CDP URL，先修改 ca-env.bat 的 CA_CRL_URL
               （見 Root CA 端 README「八、CRL Distribution Point」）
               若舊憑證仍有效，先執行 04_revoke_cert.bat 撤銷
               執行 02_sign_intermediate.bat 重新簽發
        ↓
  [USB] 將簽回的憑證複製回 AD CS 伺服器，改名為
        C:\CAConfig\SubCA_renewal.crt
        ↓
  [AD CS 伺服器] 執行 02_install_subcacert.ps1 安裝新憑證
                 執行 03_configure_cdp_aia.ps1 更新 CDP/AIA 設定
                （若有異動）


八、驗證指令
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

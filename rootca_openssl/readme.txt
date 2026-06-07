================================================================
  離線 Root CA 建置與維運指南
  環境：Windows x64 + OpenSSL（離線 VM）
  架構：Root CA（離線）→ Intermediate CA（上線）
================================================================

一、檔案清單
────────────────────────────────────────────────────────────────
  openssl-rootca.cnf      Root CA 設定檔（必須先複製到 C:\RootCA\）
  01_init_rootca.bat      初始化 Root CA（只執行一次）
  02_sign_intermediate.bat 簽發 Intermediate CA 憑證（數年一次）
  03_renew_crl.bat        更新 CRL（每年執行一次）
  04_revoke_cert.bat      撤銷憑證（需要時執行）
  05_verify_inspect.bat   狀態檢查工具（每次上線時執行）


二、前置作業
────────────────────────────────────────────────────────────────
  1. 安裝 OpenSSL for Windows x64
     下載：https://slproweb.com/products/Win32OpenSSL.html
     建議安裝路徑：C:\OpenSSL-Win64\

  2. 確認 OpenSSL 版本（建議 1.1.1 以上）
     C:\OpenSSL-Win64\bin\openssl.exe version

  3. 將所有腳本與設定檔複製到 C:\RootCA\

  4. 此 VM 從此保持離線（拔除網路線或停用網卡）


三、首次建置流程（只做一次）
────────────────────────────────────────────────────────────────
  Step 1：將 openssl-rootca.cnf 複製到 C:\RootCA\
  Step 2：以系統管理員身份執行 01_init_rootca.bat
  Step 3：設定私鑰保護密碼（請牢記或安全記錄）
  Step 4：備份以下檔案到離線安全媒體（USB / 保險箱）：
            C:\RootCA\private\rootCA.key
            C:\RootCA\rootCA.crt
  Step 5：將 rootCA.crt 與 rootCA.crl 複製到對外發布位置

  目錄結構建立完成後如下：
  C:\RootCA\
  ├── openssl-rootca.cnf   設定檔
  ├── rootCA.crt           Root CA 憑證（可公開）
  ├── private\
  │   └── rootCA.key       Root CA 私鑰（高度機密！）
  ├── certs\               已簽發的憑證
  ├── crl\
  │   ├── rootCA.pem       CRL（PEM 格式）
  │   └── rootCA.crl       CRL（DER 格式，對外發布用）
  ├── newcerts\            簽發憑證自動備份
  ├── db\
  │   ├── index.txt        憑證資料庫
  │   ├── serial           憑證序號
  │   └── crlnumber        CRL 序號
  └── requests\            CSR 暫存區


四、簽發 Intermediate CA 憑證流程
────────────────────────────────────────────────────────────────
  在 Intermediate CA 機器（另一台）執行：
    openssl genrsa -aes256 -out intermediateCA.key 4096
    openssl req -new -key intermediateCA.key -out intermediateCA.csr

  將 intermediateCA.csr 複製到此 Root CA 的 VM：
    C:\RootCA\requests\intermediateCA.csr

  執行：02_sign_intermediate.bat

  完成後將以下檔案複製回 Intermediate CA 機器：
    C:\RootCA\certs\intermediateCA.crt
    C:\RootCA\rootCA.crt


五、年度維運：更新 CRL
────────────────────────────────────────────────────────────────
  Root CA CRL 有效期設為 400 天（含 35 天緩衝），
  建議每年固定排程上線更新：

  Step 1：啟動此 Root CA VM（保持網路離線）
  Step 2：執行 05_verify_inspect.bat 確認目前狀態
  Step 3：執行 03_renew_crl.bat 更新 CRL
  Step 4：將 C:\RootCA\crl\rootCA.crl 複製到外部 USB
  Step 5：立即關機
  Step 6：在線上機器將 rootCA.crl 複製到 Web 發布目錄


六、憑證撤銷流程
────────────────────────────────────────────────────────────────
  （Root CA 只需撤銷 Intermediate CA 憑證，一般終端憑證
    由 Intermediate CA 負責撤銷）

  Step 1：將欲撤銷的 .crt 憑證複製到 C:\RootCA\certs\
  Step 2：修改 04_revoke_cert.bat 中的 REVOKE_CRT 路徑
  Step 3：執行 04_revoke_cert.bat，輸入撤銷原因
  Step 4：立即執行 03_renew_crl.bat 重新產生 CRL
  Step 5：發布新的 CRL


七、重要安全提醒
────────────────────────────────────────────────────────────────
  [!] rootCA.key 是整個 PKI 架構的信任根，一旦外洩須重建整個 CA
  [!] 此 VM 快照建議在每次操作完成後立即建立
  [!] VM 的磁碟映像檔建議加密（BitLocker / VM 加密）
  [!] Root CA 私鑰密碼請使用密碼管理工具安全儲存
  [!] 每次上線前請確認網路已完全斷開
  [!] 建議準備實體隔離（Air-Gap）環境，不要使用共用的 Hypervisor


八、CRL Distribution Point（CDP）設定說明
────────────────────────────────────────────────────────────────
  在 openssl-rootca.cnf 的 [v3_intermediate_ca] 區塊中，
  取消以下行的註解並填入您的 CRL 發布 URL：

    crlDistributionPoints = URI:http://pki.yourdomain.com/crl/rootCA.crl

  此 URL 必須是 HTTP（不是 HTTPS），且外部用戶端必須可存取。
  建議將 CRL 放在一台簡單的 IIS 或 nginx 上提供靜態檔案下載。


九、子網路遮罩 PrefixLength 對照（供憑證設計參考）
────────────────────────────────────────────────────────────────
  Root CA 憑證有效期：25 年（9131 天）
  Root CA CRL 有效期：400 天（每年更新）
  Intermediate CA   ：10 年（3650 天）
  終端 TLS 憑證     ：最長 825 天（瀏覽器限制）

================================================================
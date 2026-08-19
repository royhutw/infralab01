# 企業級第一個 Forest AD DC 完美落地建置計劃書
## 一、 環境基礎資訊
* **作業系統：** Windows Server 2022 Standard (Desktop Experience)
* **主機名稱：** `dc01`
* **網域 FQDN：** `corp.yourdomain.local`
* **網域 NetBIOS 名稱：** `CORP`
* **網路組態：**
* **IP 位址：** `192.168.10.11`
* **子網路遮罩：** `255.255.255.0`
* **預設閘道：** `192.168.10.1`
* **慣用 DNS 伺服器：** `127.0.0.1`（本機回圈，不可指向外部）


---
## 二、 階段性建置步驟
### 階段 1：OS 初始化與基本網路設定
1. 安裝 Windows Server 2022 完畢後，進入桌面。
2. 以管理員身份開啟 PowerShell 執行以下腳本，調整電腦名稱並固定 IP：
```powershell
# 1. 修改主機名稱
Rename-Computer -NewName "dc01" -Restart:$false
# 2. 設定固定 IP 與 DNS (請確認您的網路介面名稱，預設多為 "Ethernet")
$Interface = "Ethernet"
New-NetIPAddress -InterfaceAlias $Interface -IPAddress "192.168.10.11" -AddressFamily IPv4 -PrefixLength 24 -DefaultGateway "192.168.10.1"
Set-DnsClientServerAddress -InterfaceAlias $Interface -ServerAddresses "127.0.0.1"
# 3. 執行重啟以套用變更
Restart-Computer
```
---
### 階段 2：安裝 AD 角色與樹系晉升 (DC Promo)
1. 伺服器重啟後登入。
2. 執行以下指令安裝網域服務角色，並建立全新樹系。**請注意：執行過程中系統會提示您設定「目錄服務復原模式 (DSRM)」密碼，請務必妥善記錄。**
```powershell
# 1. 安裝 AD-Domain-Services 角色及 RSAT 管理工具
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
# 2. 進行 DC Promo 建立新樹系
Install-ADDSForest `
    -CreateDnsDelegation:$false `
    -DatabasePath "C:\Windows\NTDS" `
    -DomainMode "WinThreshold" `
    -DomainName "corp.yourdomain.local" `
    -DomainNetbiosName "CORP" `
    -ForestMode "WinThreshold" `
    -LogPath "C:\Windows\NTDS" `
    -NoRebootOnCompletion:$false `
    -SysvolPath "C:\Windows\SYSVOL" `
    -Force:$true
```
*系統完成後會自動重新開機，重啟後 `dc01` 正式升格為網域控制站。*
---
### 階段 3：時間同步（PDC 權威 NTP）與 DNS 反向解析配置
此步驟為 802.1x 憑證驗證與網域健康的**核心命脈**。
```powershell
# 1. 配置本機為網域權威時間伺服器，並與國家標準時間同步
w32tm /config /manualpeerlist:"tock.stdtime.gov.tw,0x8 pool.ntp.org,0x8" /syncfromflags:manual /reliable:yes /update
Restart-Service w32time
w32tm /resync
# 2. 建立 DNS 反向解析區域 (以 192.168.10.0/24 網段為例)
Add-DnsServerPrimaryZone -Name "10.168.192.in-addr.arpa" -ReplicationScope "Forest"
```
---
### 階段 4：公司 OU 架構建立與預設容器重導向
建立符合 802.1x 權限控管與部門分流的 OU，並修正「新設備無法直接套用 GPO」的微軟預設盲點。
```powershell
Import-Module ActiveDirectory
$TargetDN = "DC=corp,DC=yourdomain,DC=local"
# 1. 建立公司 Root OU
New-ADOrganizationalUnit -Name "Company_Root" -Path $TargetDN
# 2. 建立功能子 OU
New-ADOrganizationalUnit -Name "Groups" -Path "OU=Company_Root,$TargetDN"
New-ADOrganizationalUnit -Name "Users" -Path "OU=Company_Root,$TargetDN"
New-ADOrganizationalUnit -Name "Computers" -Path "OU=Company_Root,$TargetDN"
# 3. 建立終端設備分類 OU
New-ADOrganizationalUnit -Name "Laptops" -Path "OU=Computers,OU=Company_Root,$TargetDN"
New-ADOrganizationalUnit -Name "Desktops" -Path "OU=Computers,OU=Company_Root,$TargetDN"
# 4. 【關鍵疏漏修正】將新加入網域的電腦預設落點，由 CN=Computers 重新導向至專屬 OU
# 如此新電腦一加入網域，才能立刻吃得到 802.1x 與憑證自動登錄 GPO
redircmp "OU=Laptops,OU=Computers,OU=Company_Root,$TargetDN"
```
---
### 階段 5：群組原則（GPO）配置
請依據以下規劃，於 `gpmc.msc` 中建立群組原則物件，並連結到指定 OU：
#### 1. 網域密碼與賬戶鎖定原則
* **鏈結位置：** 網域根目錄 (`corp.yourdomain.local`)
* **政策修改：** 編輯 `Default Domain Policy`
* `電腦設定` -> `原則` -> `Windows 設定` -> `安全性設定` -> `帳戶原則`
* **密碼原則：** 密碼必須符合複雜性需求（啟用）、密碼長度最短 12 個字元、密碼最長有效期 90 天。
* **帳戶鎖定原則：** 帳戶鎖定閾值 5 次、帳戶鎖定期間 30 分鐘。




#### 2. 停用 USB 儲存媒體原則
* **鏈結位置：** `OU=Computers,OU=Company_Root,DC=corp...`
* **政策設定：** 建立新 GPO 命名為 `Policy_Disable_USB`
* `電腦設定` -> `原則` -> `系統範本` -> `系統` -> `卸除式儲存裝置存取權`
* **所有卸除式儲存裝置類別：拒絕所有存取** ➡️ 設定為 **已啟用**。




#### 3. 檔案存取稽核與日誌空間最佳化原則
由於您的 File Server 未來獨立運作，該原則套用在電腦 OU 上，當 File Server 加入該 OU 時即可生效。
* **鏈結位置：** `OU=Computers,OU=Company_Root,DC=corp...`
* **政策設定：** 建立新 GPO 命名為 `Policy_File_Audit`
* **步驟 A（開啟進階稽核）：** `電腦設定` -> `原則` -> `Windows 設定` -> `安全性設定` -> `進階稽核原則設定` -> `物件存取`
* **稽核檔案系統：** 勾選 **成功** 與 **失敗**。

* **步驟 B（防止日誌爆炸）：** `電腦設定` -> `原則` -> `Windows 設定` -> `安全性設定` -> `事件記錄檔`
* **最大記錄檔大小 (安全性)：** 設定為 **2,048,000 KB (約 2GB)**。
* **保留方法 (安全性)：** 設定為 **需要時覆寫事件**。

* *註：後續需在 File Server 實體資料夾的「進階安全性設定」->「稽核」標籤中，新增想要監控的用戶群組（例如 Everyone 或 Authenticated Users），檔案稽核才會正式運作。*


---
### 階段 6：AD DC 資安強化 (Security Hardening)
防範內部網路常見的身分憑證竊取與中繼攻擊。
```powershell
# 1. 停用 SMBv1 (防範舊式協議漏洞)
Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoReboot
# 2. 停用 LLMNR 名稱解析 (防範 Responder 攔截攻擊)
New-Item -Path "HKLM:\Software\Policies\Microsoft\Windows NT" -Name "DNSClient" -Force
New-ItemProperty -Path "HKLM:\Software\Policies\Microsoft\Windows NT\DNSClient" -Name "EnableMulticast" -Value 0 -PropertyType Dword -Force
# 3. 提高 NTLM 驗證層級 (僅允許 NTLMv2，拒絕 LM 與 NTLMv1)
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "LmCompatibilityLevel" -Value 5
# 4. 強制執行 LDAP 簽章 (防範 NTLM 中繼至 LDAP 攻擊)
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -Name "LDAPServerIntegrity" -Value 2
```
---
## 三、 專為 802.1x 認證落地之架構預備（核心考量）
由於您的 `adcs` 與 `radiussvr` 將獨立運作，且要求「登入成功後才能使用網路」，必須在 `dc01` 建立時鋪設好以下基礎：
### 1. 建立 802.1x 專用安全群組
未來 `radiussvr` (NPS) 將以此群組作為准入原則（Network Policies）的判斷依據。
```powershell
# 建立 802.1x 認證合法設備與人員群組
New-ADGroup -Name "8021X_Allowed_Computers" -GroupScope Global -GroupCategory Security -Path "OU=Groups,OU=Company_Root,$TargetDN"
New-ADGroup -Name "8021X_Allowed_Users" -GroupScope Global -GroupCategory Security -Path "OU=Groups,OU=Company_Root,$TargetDN"
```
### 2. 網域中斷點與首次開箱（Out-of-Box）網路規劃
* **核心痛點：** 新電腦未加入網域、沒有憑證 ➡️ 因為沒有憑證被 802.1x 擋在牆外 ➡️ 因為被擋在牆外，所以無法連線到 `dc01` 加入網域。
* **最佳實踐落地建議：**
1. **建置 Provisioning VLAN (部署專用網路)：** 網路切換器（Switch/AP）應規劃一個受限的網段。未認證的設備或新電腦可以連入此網段，此網段「僅開放存取 `dc01` 與 `adcs`」。
2. **加入網域並取得憑證：** 新電腦在部署網段完成 Domain Join 並重新開機。
3. **自動登錄與觸發：** 重啟時，電腦因重導向落入 `OU=Laptops`，自動套用憑證自動登錄 GPO，向 `adcs` 取得電腦憑證。下次開機即可順利通過 802.1x 認證進入 Production VLAN。
4. **開啟 Windows 快取登入：** 確保網域電腦在離線（例如員工帶回家，完全沒有 DC 可連線）時，仍能利用 GPO 預設允許的快取認證（預設 10 次）登入 Windows 案頭

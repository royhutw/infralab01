# 🛠️ 企業級第一個 Forest AD DC 完美落地建置計劃書（改良版）

## 一、環境基礎資訊

- **作業系統：** Windows Server 2022 Standard (Desktop Experience)
- **主機名稱：** `dc01`
- **網域 FQDN：** `corp.yourdomain.local`
- **網域 NetBIOS 名稱：** `CORP`
- **網路組態：**
  - **IP 位址：** `192.168.10.10`（統一採用 .10 作為第一台 DC）
  - **子網路遮罩：** `255.255.255.0`
  - **預設閘道：** `192.168.10.1`
  - **慣用 DNS 伺服器：** `192.168.10.10`（**不使用 127.0.0.1**，利於維運與封包追蹤）

---

# 二、階段性建置步驟

## 🔹 階段 1：OS 初始化與基本網路設定

```powershell
# 1. 修改主機名稱
Rename-Computer -NewName "dc01" -Restart:$false

# 2. 設定固定 IP 與 DNS
$Interface = "Ethernet"
New-NetIPAddress -InterfaceAlias $Interface -IPAddress "192.168.10.10" -AddressFamily IPv4 -PrefixLength 24 -DefaultGateway "192.168.10.1"
Set-DnsClientServerAddress -InterfaceAlias $Interface -ServerAddresses "192.168.10.10"

# 3. 重啟
Restart-Computer
```

---

## 🔹 階段 2：安裝 AD 角色與樹系晉升 (DC Promo)

```powershell
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

Install-ADDSForest `
    -CreateDnsDelegation:$false `
    -DatabasePath "C:\Windows\NTDS" `
    -DomainMode "WinThreshold" `
    -DomainName "corp.yourdomain.local" `
    -DomainNetbiosName "CORP" `
    -ForestMode "WinThreshold" `
    -LogPath "C:\Windows\NTDS" `
    -SysvolPath "C:\Windows\SYSVOL" `
    -NoRebootOnCompletion:$false `
    -Force:$true
```

---

## 🔹 階段 3：時間同步（PDC 權威 NTP）與 DNS 反向解析

> **註：此設定僅適用於 PDC Emulator 角色所在之 DC。**
> 目前只有一台 DC → `dc01` 即為 PDCe。

```powershell
# 設定外部 NTP 來源
w32tm /config /manualpeerlist:"tock.stdtime.gov.tw,0x8" /syncfromflags:manual /reliable:yes /update
Restart-Service w32time
w32tm /resync

# 建立反向解析區域
Add-DnsServerPrimaryZone -Name "10.168.192.in-addr.arpa" -ReplicationScope "Forest"
```

---

## 🔹 階段 4：OU 架構建立與預設容器重導向（改良版）

> **重大改良：不再將新電腦直接丟到 Laptops OU，而是導向 Staging OU。**
> 這是企業常用的彈性架構，避免未來 OU 變動造成混亂。

```powershell
Import-Module ActiveDirectory
$TargetDN = "DC=corp,DC=yourdomain,DC=local"

# Root OU
New-ADOrganizationalUnit -Name "Company_Root" -Path $TargetDN

# 功能 OU
New-ADOrganizationalUnit -Name "Groups" -Path "OU=Company_Root,$TargetDN"
New-ADOrganizationalUnit -Name "Users" -Path "OU=Company_Root,$TargetDN"
New-ADOrganizationalUnit -Name "Computers" -Path "OU=Company_Root,$TargetDN"

# 終端設備 OU
New-ADOrganizationalUnit -Name "Laptops" -Path "OU=Computers,OU=Company_Root,$TargetDN"
New-ADOrganizationalUnit -Name "Desktops" -Path "OU=Computers,OU=Company_Root,$TargetDN"

# 新增 Staging OU（改良）
New-ADOrganizationalUnit -Name "Staging" -Path "OU=Computers,OU=Company_Root,$TargetDN"

# 將新加入網域的電腦導向 Staging OU
redircmp "OU=Staging,OU=Computers,OU=Company_Root,$TargetDN"
```

---

## 🔹 階段 5：群組原則（GPO）配置

### 1. 密碼與帳戶鎖定原則（維持在 Default Domain Policy）

> **註：Default Domain Policy 僅修改帳戶原則，不放其他設定。**

### 2. USB 禁用政策（建議以 GPO 管理，而非本機設定）

- 位置：`OU=Computers,OU=Company_Root,...`
- GPO 名稱：`Policy_Disable_USB`
- 設定：拒絕所有卸除式儲存裝置存取

### 3. 檔案稽核與事件記錄最佳化

- GPO 名稱：`Policy_File_Audit`
- 套用於 File Server 所在 OU

---

## 🔹 階段 6：AD DC 資安強化（改良版：全部改用 GPO）

> **重大改良：不再直接修改 Registry，而是建議使用 GPO 套用。**

### 建議建立 GPO：`Policy_DC_Security_Hardening`

內容包含：

- 停用 SMBv1
- 停用 LLMNR
- NTLM 限制（LmCompatibilityLevel = 5）
- LDAP Signing（LDAPServerIntegrity = 2）

> **註：NTLMv1/LM 與 unsigned LDAP 可能會影響舊系統，請先做相容性評估。**

---

# 三、802.1X 認證落地之架構預備（保留 + 補強）

## 1. 建立 802.1X 專用安全群組

```powershell
New-ADGroup -Name "8021X_Allowed_Computers" -GroupScope Global -GroupCategory Security -Path "OU=Groups,OU=Company_Root,$TargetDN"
New-ADGroup -Name "8021X_Allowed_Users" -GroupScope Global -GroupCategory Security -Path "OU=Groups,OU=Company_Root,$TargetDN"
```

## 2. Provisioning VLAN（部署 VLAN）規劃（補強版）

- 未認證設備 → 進入 Provisioning VLAN
- 允許連線：
  - `dc01`（LDAP/Kerberos/DNS）
  - `adcs`（HTTP/CertEnroll）
- 不允許：
  - Internet
  - 其他伺服器

流程：

1. 新電腦 → 進入 Provisioning VLAN
2. Domain Join → 重導向至 Staging OU
3. 套用憑證自動註冊 GPO → 取得電腦憑證
4. 下次開機 → 通過 802.1X → 進入 Production VLAN

---
### 🧩 VLAN Roles（完整 NAC 分層）
| VLAN | 用途 | 來源 | 能存取 |
| --- | --- | --- | --- |
| **Registration VLAN** | 未加入網域的 PC | MAB | 僅 AD/DC（有限 ACL） |
| **Machine VLAN** | 登入前 | Machine Auth | AD/DC/DNS |
| **4F VLAN** | 4F使用者登入後 | User Auth | 內部資源 + Internet |
| **5F VLAN** | 5F使用者登入後 | User Auth | 內部資源 + Internet |
| **Guest VLAN** | 訪客/未授權 | 802.1X Fail | 只有 Internet |
| **Critical VLAN** | RADIUS 掛掉 | Fail‑Open | Internet（有限） |
| **Server VLAN** | AD / NPS / PKI | — | 受 FW 控制 |
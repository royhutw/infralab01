# Privileged Access Security Architecture Standard

* **Document Version:** 1.0
* **Classification:** Internal Use Only
* **Owner:** IT Infrastructure & Security Team

---

## 1. 目的

為保護企業 Tier 0、Tier 1 關鍵資產，降低憑證竊取、橫向移動（Lateral Movement）、Pass-the-Hash、Ransomware 及內部濫用風險，建立特權存取（Privileged Access）標準架構。

**本標準適用於：**

* Active Directory
* Active Directory Certificate Services (AD CS)
* NPS / RADIUS
* Hyper-V
* 管理伺服器
* 核心網路設備
* Tier 0 / Tier 1 特權帳號
* Privileged Access Workstation (PAW)
* Bastion Host

---

## 2. 安全設計原則

### 2.1 最小權限原則（Least Privilege）

所有人員應以一般使用者帳號完成日常工作。

**禁止行為：**

* 使用 Tier 0 帳號閱讀郵件
* 使用 Tier 0 帳號瀏覽網站
* 使用 Tier 0 帳號登入一般工作站

### 2.2 管理平面與使用平面分離

管理活動不得直接於使用者工作站進行。

```text
IT Workstation ➔ Bastion Host ➔ PAW ➔ Target System
```

### 2.3 Tier 隔離

#### Tier 0：身份服務與信任根基礎設施

* Active Directory Domain Services (AD DS)
* Domain Controller (DC)
* Active Directory Certificate Services (AD CS)
* Enterprise CA / Offline Root CA
* NPS
* DNS

#### Tier 1：伺服器與虛擬化平台

* Hyper-V
* 管理伺服器
* 檔案伺服器
* 備份伺服器
* 監控平台

#### Tier 2：一般使用者設備

* Windows Client
* Notebook
* VDI

---

## 3. 網路分區設計

### VLAN 規劃

| VLAN              | 用途           |
| ----------------- | -------------- |
| **VLAN 20** | Tier 0 PAW     |
| **VLAN 21** | Tier 1 PAW     |
| **VLAN 25** | Tier 0 Bastion |
| **VLAN 26** | Tier 1 Bastion |
| **VLAN 60** | IT 管理工作站  |

---

## 4. 存取路徑

### Tier 0 存取路徑

```text
IT 工作站 (VLAN 60)
       ↓
Tier 0 Bastion (VLAN 25)
       ↓
Tier 0 PAW (VLAN 20)
       ↓
Tier 0 Assets
```

### Tier 1 存取路徑

```text
IT 工作站 (VLAN 60)
       ↓
Tier 1 Bastion (VLAN 26)
       ↓
Tier 1 PAW (VLAN 21)
       ↓
Tier 1 Assets
```

---

## 5. Firewall 存取控制

### IT Workstation

* **允許：**
* DNS
* Kerberos
* LDAP / LDAPS
* NTP
* CRL
* 存取 Bastion
* **禁止：**
* 直接存取 Tier 0
* 直接存取 Tier 1 管理介面
* RDP 至 Domain Controller
* WinRM 至 Domain Controller

### Bastion

* **允許：**
* RDP
* Remote Console
* Session Recording
* File Transfer
* **禁止：**
* 直接管理 Tier 0 資產（必須透過 PAW）

### PAW

* **允許：**
* Tier 對應管理服務
* **禁止：**
* 跨 Tier 存取

---

## 6. 特權帳號標準

| 帳號類別              | 命名格式範例   | 用途與權限                          | 限制與禁止事項     |
| --------------------- | -------------- | ----------------------------------- | ------------------ |
| **一般帳號**    | `roy`        | Email、Teams、Office、VPN、日常工作 | 無管理權限         |
| **Tier 1 帳號** | `t1-adm-roy` | Tier 1 伺服器與服務管理             | • 禁止登入 Tier 0 |

• 禁止登入一般工作站 |
| **Tier 0 帳號** | `t0-adm-roy` | Tier 0 核心身分基礎設施管理 | • 禁止登入 Tier 1

• 禁止登入一般工作站

• 禁止登入 Bastion 外之任何設備 |

---

## 7. PAW 標準

* **僅允許：**
* RSAT
* PowerShell
* Windows Admin Center
* Hyper-V Manager
* 專用管理工具
* **嚴格禁止：**
* Outlook / 郵件客戶端
* Teams
* Office 文件編輯
* 社群網站
* 一般網頁瀏覽

---

## 8. PAW 網際網路存取

採**嚴格白名單模式**，預設為 `Deny All`。

### 白名單允許目標：

* Windows Update
* Microsoft Defender Update
* CRL Distribution Point
* 企業內部網站
* Microsoft Learn
* Cisco Support
* Fortinet Support
* PowerShell Gallery

---

## 9. Bastion 安全要求

### 必須啟用：

* MFA（多因素驗證）
* Session Recording（連線側錄）
* Session Log（審計日誌）
* File Transfer Tracking（檔案傳輸追蹤）

### 禁止啟用/使用：

* Credential Delegation
* Credential Caching
* Saved Password

---

## 10. Emergency Access 設計（Break-Glass）

### Emergency Admin

* **帳號範例：** `t0-breakglass-01`
* **安全要求：**
* 採用超長隨機密碼
* 實體保險箱密封封存
* 平時嚴格禁止使用

### Emergency PAW

* 專用獨立緊急工作站。
* **安全要求：**
* 正常營運情況下不使用
* 每月固定執行驗證測試一次

### Emergency Port

* 專用獨立網路接口。
* **安全要求：**
* 僅供 Emergency PAW 連接使用
* 平時維持網路監控
* 偵測到異常接線立即觸發告警

---

## 附錄：Emergency PAW Monthly Checklist

* **Frequency:** Every 30 Days

### 基本資訊

| 項目                   | 內容               |
| ---------------------- | ------------------ |
| **檢查日期**     | `YYYY / MM / DD` |
| **檢查人員**     |                    |
| **PAW 名稱**     |                    |
| **Windows 版本** |                    |

### 一、開機驗證

| 檢查項目             | 確認狀態 |
| -------------------- | -------- |
| 可正常開機           | [ ]      |
| BitLocker 狀態正常   | [ ]      |
| Secure Boot 啟用正常 | [ ]      |
| TPM 狀態正常         | [ ]      |

### 二、網域信任驗證

| 檢查項目                    | 確認狀態 |
| --------------------------- | -------- |
| 可正常登入網域              | [ ]      |
| 無 Trust Relationship Error | [ ]      |
| Computer Account 正常       | [ ]      |
| Machine Password 已更新     | [ ]      |

**驗證指令：**

```powershell
Test-ComputerSecureChannel -Verbose
```

*執行結果記錄：*

```text
______________________________________________________________________
```

### 三、網路連線驗證

| 檢查項目                 | 確認狀態 |
| ------------------------ | -------- |
| 可正常解析 DNS           | [ ]      |
| 可連線 Domain Controller | [ ]      |
| 可連線 CRL 配發點        | [ ]      |
| 可連線至指定管理網段     | [ ]      |

### 四、更新狀態

| 檢查項目                  | 確認狀態 |
| ------------------------- | -------- |
| Windows Update 更新完成   | [ ]      |
| Defender Signature 最新版 | [ ]      |
| RSAT 工具運作正常         | [ ]      |
| 相關管理工具正常          | [ ]      |

### 五、認證與憑證

| 檢查項目               | 確認狀態 |
| ---------------------- | -------- |
| 電腦憑證有效           | [ ]      |
| Tier 0 管理憑證有效    | [ ]      |
| CRL 憑證撤銷清單可下載 | [ ]      |
| 各項管理憑證均未過期   | [ ]      |

### 六、管理工具驗證

#### Tier 0

| 檢查項目                                           | 確認狀態 |
| -------------------------------------------------- | -------- |
| ADUC (Active Directory Users and Computers) 可開啟 | [ ]      |
| DNS Console 運作正常                               | [ ]      |
| GPMC (Group Policy Management) 運作正常            | [ ]      |
| CA Console 運作正常                                | [ ]      |

#### Tier 1

| 檢查項目                      | 確認狀態 |
| ----------------------------- | -------- |
| Hyper-V Manager 運作正常      | [ ]      |
| Windows Admin Center 運作正常 | [ ]      |
| RDP 連線服務正常              | [ ]      |

### 七、Emergency Path 驗證

| 檢查項目                               | 確認狀態 |
| -------------------------------------- | -------- |
| Emergency Port 實體/邏輯介面可正常使用 | [ ]      |
| Emergency PAW 可連通至管理網段         | [ ]      |
| Break Glass Account 登入身分驗證正常   | [ ]      |
| Bastion 故障情境下可成功繞過連線       | [ ]      |

### 八、稽核紀錄

| 檢查項目                            | 狀態確認 |
| ----------------------------------- | -------- |
| Windows Event Log 運作正常          | [ ]      |
| Microsoft Defender 無異常安全性告警 | [ ]      |
| Session Recording 連線側錄正常      | [ ]      |

### 九、查核結論

* [ ] **通過**
* [ ] **需改善**
* [ ] **不通過**

**改善事項與備註：**

```text
1. __________________________________________________________________

2. __________________________________________________________________

3. __________________________________________________________________
```

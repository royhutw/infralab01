# 資訊系統資安架構說明書 (FortiGate 核心與部門別動態 802.1X 整合版)

## 1. 系統環境總覽與網路劃分 (Infrastructure & Network Segmentation)

本系統採用微軟階層化模型 (Tier Model) 架構原則。除了核心伺服器使用**靜態 VLAN** 外，邊界實體網路孔全面啟用 **IEEE 802.1X / MAB 動態 VLAN 配置**，由 RADIUS (NPS) 依據設備身分與使用者所屬「AD 部門群組」即時調度網段。所有跨網段及對外網路流量，一律由 **FortiGate 硬體防火牆** 進行硬體級 SPU 加速轉發與深度應用層安全審查 (NGFW)。

為了確保維運特權不被逆向污染，本架構引入 **Apache Guacamole** 作為唯一的特權網頁存取閘道器（堡壘機），全面強制執行 **多因素驗證 (MFA)**。所有 IT 管理員禁止從辦公網段直接發起 RDP/SSH 管理連線，必須統一經由 Guacamole 進行權限中轉。

### 🏷️ 完整 VLAN 規劃表 (VLAN Assignment Matrix)

#### A. 核心基礎建設與維運網段 (靜態配置 - Static VLANs)

| VLAN ID           | 網段名稱 (Zone Name)                | 機敏等級      | 允許的通訊/路由原則 (Routing Policy)                                                                                                                                                 |
| ----------------- | ----------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **VLAN 30** | **Tier 0 - 管理核心網段**     | 👑 最高機敏   | 1. 僅允許來自**VLAN 25 (Guacamole)** 的代行 RDP/SSH 管理流量。<br />2. 僅放行特定伺服器的 Log 收集流量 (Wazuh Agent)。<br />3. ❌ 嚴禁其餘任何網段直連。                       |
| **VLAN 25** | **Bastion Zone - 堡壘機專區** | 🛡️ 特權中轉 | 1.**唯一特權大門**：允許來自 VLAN 60 (RD/IT) 的 HTTPS (443) 網頁存取與 MFA 認證。<br />2. 經認證後，允許代行發起前往 VLAN 30 (T0 PAW) 與 VLAN 20 (T1 PAW) 的 RDP (3389) 流量。 |
| **VLAN 20** | **Tier 1 - 運維跳板網段**     | 🔒 高度機敏   | 1. 僅允許來自**VLAN 25 (Guacamole)** 的代行管理流量連往 `pawt1-1`。<br />2. 允許 RD/IT 部門經認證後存取生產力工具 (Gitea/Redmine)。                                          |
| **VLAN 10** | **Tier 1 - 企業應用網段**     | 🔷 中度機敏   | 1. 允許經 802.1X 認證成功之部門網段存取基礎服務 (File Server / OCS Agent)。                                                                                                          |

#### B. 邊界存取與部門網段 (802.1X / MAB 動態配置 - Dynamic VLANs)

| VLAN ID           | 網段名稱 (Zone Name)                   | 認證模式 (Auth Mode)              | 預期服務對象 (Target)                              | AD群組        | 防火牆路由與 Internet 限制 (Firewall ACLs)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ----------------- | -------------------------------------- | --------------------------------- | -------------------------------------------------- | ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **VLAN 40** | **Registration VLAN**            | **MAB** (MAC認證)           | 未加入網域的內部電腦                               |               | 1.**極度限縮**：僅允許連往 `dc01` / `adcs` 進行Join Domain或憑證申請。<br />2. ❌ 阻斷 Internet 與其他所有內網。                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| **VLAN 50** | **Machine VLAN**                 | **Machine Auth**            | 電腦已開機、使用者未登入前                         |               | 1. 僅允許連往 `dc01` 進行 DNS、網域腳本執行。<br />2. 允許連往 `crl` 容器下載憑證黑名單 (Port 80)。<br />3. ❌ 阻斷 Internet。                                                                                                                                                                                                                                                                                                                                                                                                                               |
| **VLAN 60** | **RD/IT Dept VLAN**              | **User Auth** (憑證/帳密)   | 研發與資訊技術部門群組                             | GG_RD_IT      | 1.放行 Internet 存取。<br />2. 允許存取 VLAN 10 (`fs01`)、VLAN 20 (`gitea`, `redmine`) 與 **VLAN 25 (Guacamole 網頁後台)**。<br />3. ❌ 嚴禁直連 VLAN 20/30 的維運電腦與管理核心。                                                                                                                                                                                                                                                                                                                                                                   |
| **VLAN 70** | **General Dept VLAN**            | **User Auth** (憑證/帳密)   | 一般行政、人事、業務等部門                         | GG_General    | 1.放行 Internet 存取。<br />2. 僅允許存取開放VLAN 30 `dc01`的UDP/TCP 53 (DNS), UDP/TCP 88 (Kerberos), UDP/TCP 464 (密碼變更協定), TCP 389 / 636 (LDAP/LDAPS), TCP 3268 / 3269 (Global Catalog), TCP 445 (SMB), UDP 123 (NTP), TCP 135(RPC Endpoint Mapper), TCP 49152-65535(RPC Dynamic Port), `adcs`的TCP 135, `crl`的TCP 80 (HTTP), VLAN 10 (`fs01` 檔案伺服器)。<br />3. ❌ 阻斷 VLAN 20/25/30 核心與特權區域。                                                                                                                                       |
| **VLAN 75** | **Wireless Meeting Laptop VLAN** | **MAB** (MAC認證)           | 會議室專用無線筆電 (含 Windows / macOS 不加域設備) |               | 1. 放行 Internet 存取。<br />2. 🛡️**微隔離防線**：僅允許存取開放 VLAN 30 `dc01` 的 UDP/TCP 53 (DNS), UDP/TCP 88 (Kerberos), TCP 389 / 636 (LDAP/LDAPS), TCP 3268 / 3269 (Global Catalog), 以及 VLAN 10 (`fs01` 檔案伺服器) 的 TCP 445 (SMB)。當下主管需手動輸入個別 AD 帳號密碼驗證。<br />3. ❌ 阻斷 VLAN 20/25/30 核心與特權區域，並強制啟用 AP 隔離。                                                                                                                                                                                             |
| **VLAN 80** | **Secure Dept VLAN**             | **User Auth** (憑證/帳密)   | **高機敏單位 (如財務、核心研發)**            | GG_SecureDept | 1. 🛡️**限定上網 (白名單)**：利用 FortiGate **ISDB 與 Web Filter** 技術，僅放行微軟/Azure 雲端、foundrymode.com 以及指定的政府機關網站。<br />2. 僅允許存取開放VLAN 30 `dc01`的UDP/TCP 53 (DNS), UDP/TCP 88 (Kerberos), UDP/TCP 464 (密碼變更協定), TCP 389 / 636 (LDAP/LDAPS), TCP 3268 / 3269 (Global Catalog), TCP 445 (SMB), UDP 123 (NTP), TCP 135(RPC Endpoint Mapper), TCP 49152-65535(RPC Dynamic Port), `adcs`的TCP 135, `crl`的TCP 80 (HTTP), VLAN 10 (`fs01` 檔案伺服器)。<br />3. ❌ 嚴禁直連 VLAN 20/30 的維運電腦與管理核心。 |
| **VLAN 83** | **IoT**                          | **MAB** (MAC認證)           | 門禁, 考勤, IPCam, NVR                             |               | 1.放行 VLAN 60, 70, 75, 80 存取 VLAN 85 必要Port (廠商提供)<br />2. ❌ 阻斷 Internet 與所有內部企業 VLAN。                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| **VLAN 85** | **Printer VLAN**                 | **MAB** (MAC認證)           | 印表機, 印表機伺服器                               |               | 1.放行 VLAN 60, 70, 75, 80 存取 VLAN 85 的 UDP 137, 138, TCP 80, 139, 443, 445, 515, 3702, 9100 。<br />2. 僅允許印表機監控系統的IP存取Internet<br />3. ❌ 100% 阻斷所有內部企業 VLAN。                                                                                                                                                                                                                                                                                                                                                                          |
| **VLAN 90** | **Guest VLAN**                   | **802.1X Fail**             | 訪客或認證失敗之設備                               |               | 1.**僅限外網**：只放行連往 Internet (NAT)。<br />2. ❌ 100% 阻斷所有內部企業 VLAN。                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| **VLAN 99** | **Critical VLAN**                | **Fail‑Open** (RADIUS失效) | 當 `radius` 伺服器當機時                         |               | 1.**業務連續性保證**：暫時放行 Internet 供日常辦公。<br />2. ❌ 阻斷所有核心內部資源。                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |

---

### 🧱 實體與虛擬化架構運載 (Topology & Department Auth Flow)

* **Internet Firewall (FortiGate)**: 擔任全網實體與虛擬邊界的核心防火牆。與下層網管型 Switch 建立 **LACP 網卡流量聚合（Link Aggregation / Trunk）**，以高頻寬承載 Inter-VLAN 安全路由、機敏單位的應用層白名單過濾，以及 **VLAN 25 堡壘機區** 的進出剪票。
* **RADIUS Server (radius)**: 運行 Windows Network Policy Server (NPS)。與 Switch 建立 RADIUS 溝通，比對 AD 帳號部門群組，核發對應的動態 VLAN 標籤（Tunnel-Tag）。
* **Backup Server (bak01)**: 實體備份伺服器。不加入網域，透過專用隔離網段備份 vmhost01/02。
* **Root CA (rootca)**: 企業獨立根憑證。實體 Windows Server 2022，100% Air-gapped (完全離線)。

#### Tier 0 / Tier 1 管理員帳號模型（ADM 帳號）

* Tier 0 : admin.t0（只能登入 PAW‑T0）
* Tier 1 : admin.t1（只能登入 PAW‑T1）

#### 💻 vmhost01 (核心與應用服務宿主機)

* 承載 VMs: `dc01` (T0), `adcs` (T0), `radius` (T0), `dockerhost-t0` (T0), `dockerhost-t1` (T1), `fs01` (T1), `db01` (T1)

#### 💻 vmhost02 (特權維運與中轉安全宿主機)

* 承載 VMs: `guacamole` (VLAN 25), `pawt0-1` (T0 PAW - VLAN 30), `pawt1-1` (T1 PAW - VLAN 20), `webfilet0` (T0中轉站), `webfilet1` (T1中轉站)
* *架構安全註記*：雖然 `guacamole` 與 PAW 運維電腦共處於 `vmhost02` 實體機內，但其虛擬網卡依據 **微軟 Tier 隔離原則** 劃分至獨立的 **VLAN 25**。在 Hyper-V 內部不進行任何橫向虛擬交換，所有進出流量必須強制作業爬出至實體 **FortiGate 防火牆** 進行狀態化（Stateful）安全過濾。
* guacamole session recording錄影存放180日

```
[ IT管理員於 VLAN 60 辦公孔 ] 
            │
            ▼ (發起連線：HTTPS Port 443)
   [ FortiGate 防火牆 ] 
            │
            ▼ (放行進入獨立網段)
   [ Apache Guacamole (VLAN 25) ] ──► 強制要求 帳密 + 綁定手機 TOTP (MFA)
            │
            ├─► 認證成功：管理員於網頁上點選 RDP 連線
            │
            ▼ (代行發起 RDP Port 3389 請求)
   [ FortiGate 防火牆 ] ──► 檢查特權剪票規則 (僅允許 Guacamole IP 發起 RDP)
            │
            ├─► 通往 Tier 1 運維 ➔ [ pawt1-1 (VLAN 20) ]
            └─► 通往 Tier 0 核心 ➔ [ pawt0-1 (VLAN 30) ]

```

---

## 2. 核心基礎設施與管理層 (Tier 0 - Identity & Management)

本層級為企業最高控制平面。此層級所有資產的管理權限**僅允許來自特權安全閘道器（Guacamole）代理中轉後的連線**，並嚴禁存取任何外部或低階層的網頁與服務。

### 2.1 虛擬機與實體主機 (Tier 0 & Bastion VMs & Hosts)

| 主機名稱 (Hostname)     | 作業系統 (OS)           | 所屬網段          | 功能用途 (Function)                             | 管理限制與安全策略 (Access Control / ACL)                                                                                                                                                                             |
| ----------------------- | ----------------------- | ----------------- | ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **vmhost01**      | Windows Server 2022 Std | **VLAN 30** | 核心虛擬化主機                                  | 1. 僅允許來自**VLAN 30 (pawt0-1)** 的 `RDP` 存取。<br />2. 保持 Workgroup 狀態，不加入 AD 網域。                                                                                                              |
| **vmhost02**      | Windows Server 2022 Std | **VLAN 30** | 維運虛擬化主機                                  | 1. 僅允許來自**VLAN 30 (pawt0-1)** 的 `RDP` 存取。<br />2. 保持 Workgroup 狀態，不加入 AD 網域。                                                                                                              |
| **guacamole**     | Ubuntu/Debian Linux     | **VLAN 25** | 特權安全閘道器(堡壘機 Jump Server)              | 1. 開放**VLAN 60** 之 HTTPS (443) 連入，並強制執行 **TOTP MFA**。<br />2. 本機連線帳密由系統加密預埋，不對管理員透露實體特權密碼。<br />3. 全面啟用 **Session Recording (連線錄影)** 以供資安審計。 |
| **pawt0-1**       | Windows 11 Enterprise   | **VLAN 30** | Tier 0 特權工作站(Privileged Admin Workstation) | 1.**最高控制台**：僅允許來自 **VLAN 25 (guacamole IP)** 的 `RDP` 存取。<br />2. ❌ 100% 斷絕 Internet，嚴禁安裝任何非管理用生產力工具。                                                                 |
| **pawt1-1**       | Windows 11 Enterprise   | **VLAN 20** | Tier 1 特權工作站(Privileged Admin Workstation) | 1.**應用維運台**：僅允許來自 **VLAN 25 (guacamole IP)** 的 `RDP` 存取。<br />2. ❌ 100% 斷絕 Internet。                                                                                                 |
| **dc01**          | Windows Server 2022 Std | **VLAN 30** | Active Directory 網域控制站                     | 僅允許來自**VLAN 30 (pawt0-1)** 的 `RDP` 與 `RSAT` 管理流量。                                                                                                                                               |
| **adcs**          | Windows Server 2022 Std | **VLAN 30** | AD CS 次級發證 CA                               | 僅允許來自**VLAN 30 (pawt0-1)** 的 `RDP` 與 `RSAT` 管理流量。                                                                                                                                               |
| **radius**        | Windows Server 2022 Std | **VLAN 30** | RADIUS 認證伺服器 (NPS)                         | 僅允許來自**VLAN 30 (pawt0-1)** 的 `RDP` 管理流量。                                                                                                                                                           |
| **rootca**        | Windows Server 2022 Std | **離線**    | 企業內根憑證 (Root CA)                          | 不接網路，利用專用實體隨身碟人工轉存 Root CRL 檔案。                                                                                                                                                                  |
| **dockerhost-t0** | Debian Linux            | **Trunk**   | 核心安全容器宿主機                              | 透過 Hyper-V 派發多張虛擬網卡，分別綁定 `macvlan` 連接不同 Zone。僅允許 **pawt0-1** 的 `SSH`。                                                                                                              |

### 2.2 核心容器服務 (Docker Containers on dockerhost-t0)

| 服務名稱 (Service)     | 映像檔/工具                  | 分配網卡/網段                | 功能用途 (Function)                                                                                                                            | 管理與存取策略 (Access Control / ACL)                                                                                                            |
| ---------------------- | ---------------------------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| **crl** (caddy)  | `eth0` / **VLAN 30** | CRL 憑證撤銷清單 Web         | **802.1X 特殊放行**：除了 AD/RADIUS 外，必須允許來自 **VLAN 50 (Machine VLAN)** 的 HTTP Port 80 存取，供開機階段之憑證有效性驗證。 |                                                                                                                                                  |
| **wazuh**        | Wazuh                        | `eth2` / **VLAN 30** | SIEM / 日誌分析系統                                                                                                                            | 1.**管理後台**：僅允許 **VLAN 30 (pawt0-1)** 存取 WebUI 後台。<br />2. **日誌收集**：放行各伺服器連往此 IP 的 Port 1514/1515。 |
| **portainer-t0** | Portainer                    | 內部 /**VLAN 30**      | T0 容器管理平台                                                                                                                                | 僅允許來自**VLAN 30 (pawt0-1)** 存取 WebUI。                                                                                               |
| **npm-t0**       | Nginx Proxy Manager          | 內部 /**VLAN 30**      | T0 反向代理伺服器                                                                                                                              | 僅允許來自**VLAN 30 (pawt0-1)** 存取管理後台。                                                                                             |

---

## 3. 應用程式與企業服務層 (Tier 1 - Applications & Services)

此層級系統運維與管理僅允許來自 **PAWT1 VLAN (VLAN 20)** 且經由 Guacamole 代理轉發之連線。

### 3.1 虛擬機 (Tier 1 VMs)

| 主機名稱 (Hostname)     | 作業系統 (OS)           | 所屬網段          | 功能用途 (Function) | 管理限制與安全策略 (Access Control / ACL)                                                                                             |
| ----------------------- | ----------------------- | ----------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| **fs01**          | Windows Server 2022 Std | **VLAN 10** | 企業檔案伺服器      | 1. 僅允許來自**VLAN 20 (pawt1-1)** 的 `RDP` 維運流量。<br />2. 允許全公司 Client 網段存取 `SMB (Port 445)` 檔案共享。       |
| **db01**          | Windows Server 2022 Std | **VLAN 10** | MSSQL 核心資料庫    | 1. 僅允許來自**VLAN 20 (pawt1-1)** 的 `RDP` 存取。<br />2. 僅放行來自 **VLAN 60 (RD/IT 網段)** 的 `SSMS` 資料庫連線。 |
| **dockerhost-t1** | Debian Linux            | **VLAN 20** | 應用容器宿主機      | 1. 僅允許來自**VLAN 20 (pawt1-1)** 的 `SSH` 存取。<br />2. 負責運載開發小組使用的所有 Docker 生產力工具。                     |

### 3.2 應用容器服務 (Docker Containers on dockerhost-t1)

| 服務名稱 (Service)      | 映像檔/工具   | 所屬網段          | 功能用途 (Function)      | 管理與存取策略 (Access Control / ACL)                                                                                                                                            |
| ----------------------- | ------------- | ----------------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **gitea**         | Gitea         | **VLAN 20** | 原始碼版本控制系統 (Git) | 1. 允許**VLAN 60 (RD/IT 小組)** 與 **VLAN 20 (pawt1-1)** 存取 WebUI 與 SSH Code 提交。<br />2. ❌ **嚴禁 pawt0-1 存取** (防止網頁木馬逆向污染 T0)。            |
| **redmine**       | Redmine       | **VLAN 20** | 專案與 Issue 追蹤管理    | 1. 允許**VLAN 60** 與 **VLAN 20** 存取 WebUI。<br />2. ❌ **嚴禁 pawt0-1 存取**。                                                                              |
| **grafana**       | Grafana       | **VLAN 20** | 環境效能监控數據看板     | 1. 允許**RD/IT 小組** 與 **pawt1-1** 檢視數據。<br />2. ❌ **嚴禁 pawt0-1 存取**。                                                                             |
| **ocs-inventory** | OCS Inventory | **VLAN 10** | IT 資產自動盤點系統      | 1.**Agent 收集**：利用 `macvlan` 對應到 **VLAN 10**，接收全公司電腦回報的資產資料 (Port 443)。<br />2. **管理後台**：僅允許 **pawt1-1** 存取其 WebUI。 |

---

## 4. 網路邊界與動態資安控管防線 (FortiGate Firewall IPv4 Policy 核心規則)

為落實動態網段控管與高機敏單位限制外網之需求，FortiGate 防火牆策略必須依據 **Top-Down (由上至下)** 嚴格排序建立以下安全原則：

### 4.1 Apache Guacamole (VLAN 25) 堡壘機專區特權流量鏈

1. **【規則一：放行管理員對堡壘機的 HTTPS 請求與 MFA 驗證】**

* **Incoming**: `VLAN 60 (RD/IT)` ➔ **Outgoing**: `VLAN 25 (Guacamole VM)`
* **Service**: `HTTPS (443)`
* **Action**: `ACCEPT` （經此通道進行 Google Authenticator TOTP 雙因素審查）

2. **【規則二：放行堡壘機代行通往 Tier 1 特權維運區】**

* **Incoming**: `VLAN 25 (Guacamole IP Only)` ➔ **Outgoing**: `VLAN 20`
* **Source**: `guacamole_static_IP` ➔ **Destination**: `pawt1-1_static_IP`
* **Service**: `RDP (3389)`
* **Action**: `ACCEPT`

3. **【規則三：放行堡壘機代行通往 Tier 0 核心控制區】**

* **Incoming**: `VLAN 25 (Guacamole IP Only)` ➔ **Outgoing**: `VLAN 30`
* **Source**: `guacamole_static_IP` ➔ **Destination**: `pawt0-1_static_IP`
* **Service**: `RDP (3389)`
* **Action**: `ACCEPT`

4. **【規則四：阻斷其餘所有直連特權工作站之流量】**

* 任何企圖從 **VLAN 60/70/80/90** 繞過 Guacamole 直連 `pawt0-1` 或 `pawt1-1` 之流量，一律落入預設 `DENY`，確保特權通道的唯一性。

### 4.2 高機敏單位 (VLAN 80) 防外洩與精準白名單策略

5. **【規則五：放行指定內部資源】**

* **Incoming Interface**: `VLAN 80` ➔ **Outgoing Interface**: `VLAN 10`
* **Source**: `VLAN 80 Subnet` ➔ **Destination**: `fs01 IP / 指定內部資源`
* **Action**: `ACCEPT`

6. **【規則六：放行微軟與 Azure 雲端生態系其它必要雲端系統（利用 ISDB）】**

* **Incoming Interface**: `VLAN 80` ➔ **Outgoing Interface**: `WAN`
* **Source**: `VLAN 80 Subnet`
* **Destination**: 啟用 FortiGate 內建 **Internet Service Database (ISDB)** 物件：
* `Microsoft-Office365`
* `Microsoft-Azure`
* `Microsoft-Windows.Update`
* `Cisco-Webex`
* **Action**: `ACCEPT`

7. **【規則七：網頁精準白名單放行（利用 Web Filter）】**

* **Incoming Interface**: `VLAN 80` ➔ **Outgoing Interface**: `WAN`
* **Source**: `VLAN 80 Subnet` ➔ **Destination**: `all (任意外部 IP)`
* **Service**: `HTTP / HTTPS / DNS`
* **Security Profiles (安全設定檔)**: 載入專屬 Web Filter Profile：
* *Static URL Filter 白名單豁免*：`*foundrymode.com` (Exempt)、`*.gov.tw` (Exempt)、`*.gov` (Exempt)
* *FortiGuard Categories 類別過濾*：**預設全部勾選阻擋 (Block All Categories)**
* **Action**: `ACCEPT`

8. **【規則八：高機敏預設全面阻斷】**

* 任何未符合上述三條規則之流量（如同儕網段互連、其餘外網網站），直接觸發隱含預設規則進行 `DENY / DROP`，徹底防範機敏資料透過未授權管道外洩。

### 4.3 行政/商務網段、會議無線與訪客網段安全鏈

9. 【規則九：會議室無線筆電 (VLAN 75) 精準微隔離】

* **Incoming Interface**: `VLAN 75` ➔ **Outgoing Interface**: `VLAN 30 (核心網域)` / `VLAN 10 (企業應用)`
* **Source**: `VLAN 75 Subnet` (僅限 MAB 白名單設備)
* **Destination**:
  * `dc01 IP`: 放行 `UDP/TCP 53 (DNS)`, `UDP/TCP 88 (Kerberos)`, `TCP 389/636 (LDAP)`, `TCP 3268/3269 (Global Catalog)`
  * `fs01 IP`: 放行 `TCP 445 (SMB)`
* **Action**: `ACCEPT`
* ❌ 隱含預設規則阻斷 `VLAN 75` ➔ 通往其餘任何內部網段。

10. 【規則十：一般行政 (VLAN 70) 權限限制】

* 允許 `VLAN 70` ➔ `WAN` (正常放行上網)。
* 允許 `VLAN 70` ➔ `VLAN 10` (僅限存取 `fs01` 檔案伺服器，Port 445)。
* ❌ 隱含阻斷 `VLAN 70` ➔ `VLAN 20`（行政人員不可存取 Gitea 程式碼主機）。

11. 【規則十一：訪客與主管 BYOD 隔離 (VLAN 90) 淨空策略】

* 允許 `VLAN 90` ➔ `WAN` (Internet Only)。
* 服務對象：外部訪客、廠商、上課講師，以及高階主管之個人行動設備 (BYOD)。
* 路由原則：僅放行 `VLAN 90` ➔ `WAN (Internet-Only)`，並透過 FortiGate 開啟 AV/IPS 安全審查。
* ❌ `DENY` ➔ `VLAN 90` ➔ `所有內部企業網段 (RFC1918 轉發阻斷)`。

#### 針對您這套 802.1X 規劃的維運強烈建議（避坑指南）

實務落地注意事項：

1. **Machine VLAN (VLAN 50) 的 DHCP Lease Time（租期）不要設太長：**
   原因：當一台電腦開機時，它會先在 Machine VLAN 拿到一個 IP。當使用者敲鍵盤登入成功後，Switch 會立刻把孔切到 User VLAN (VLAN 41/51)，電腦會再次發送 DHCP 索取新 IP。
   後果：這意味著「每台電腦登入一次，就會同時佔用兩個 VLAN 的 IP 各一個」。如果 Machine VLAN 的 DHCP 租期設成 8 天，您的 IP 相對容易被耗盡。
   建議：將 Machine VLAN 的 DHCP 租期設短（例如 1 ~ 2 小時），人登入走後，IP 就能快速回收。
2. **Critical VLAN (VLAN 99) 的 Fail-Open 機制是雙面刃：**
   優點：RADIUS 真的死機時，員工不會暴動，因為還能上網工作。
   潛在風險：萬一有內鬼或駭客知道你們有設 Fail-Open，他只要對 RADIUS 伺服器發動 DoS 攻擊（拒絕服務攻擊） 讓 RADIUS 癱瘓，整間公司的 Switch 就會全部自動退化到 VLAN 99（Fail-Open）。這時駭客就可以繞過 802.1X 認證，直接插線點進你們的網路。
   防範：請務必在 wazuh (SIEM) 上設定監控：一旦 RADIUS 服務停止、或是發現突然有大量流量湧入 VLAN 99，必須立刻發出高警示（High Alert）簡訊或 Mail 報警。技術人員必須立刻介入檢查是硬體故障還是遭受黑客攻擊。
3. **「802.1X Auth Fail」直接導向法:**
   原因：當憑證過期的外派員工回到公司，Laptop插上網路線時，因為憑證失效，會無法通過 802.1X 的 User/Machine Auth。
   建議：您可以修改 Cisco Switch 的設定，調整為：當設備發起 802.1X 認證但「因為憑證過期/錯誤而失敗」時， **不用比對 MAB** ，直接用 `authentication event fail action authorize vlan 40` 指令，把認證失敗的網域電腦直接踢進 VLAN 40。
   優點：出差回來的員工一插線，就會自動被關進 VLAN 40 沙盒，員工自己敲 `gpupdate /force` 或等一下，憑證更新完重新插拔就修好了
4. **Apple 設備（VLAN 75/90）隨機 MAC 機制防範**：
   由於 iOS 與 macOS 現代版本預設啟用「私有 Wi-Fi 位址/專用位址」功能，會導致設備 MAC 定期隨機變更，進而引發 MAB 認證失敗。IT 人員在對會議室 MacBook 或主管 iPhone 進行無線綁定時，**必須手動進入該 Wi-Fi 的進階設定，將「專用位址 (Private Address)」功能關閉**，固定使用實體網卡 MAC 登錄於 RADIUS (NPS) 中

---

## 5. 實體交換器邊界防護與反私接策略 (Cisco Switch Edge Port Security)

為防止人員私接未授權之 Unmanaged Switch（傻瓜交換器）進行集線偷渡，或串接無線路由器（AP）繞過 802.1X 機制，全公司所有邊界實體網路孔（Edge Ports）皆必須實施 Cisco 實體層安全防禦。

### 🛡️ 實體埠口安全配置標準 (Switchport Security Baseline)

對於所有連接員工電腦、印表機、IP 電話的實體 Port，一律強制執行以下安全設定：

1. **單一 MAC 位址限制 (Max MAC Count = 1)**：

* 每個實體 Port **最多僅允許學習到 1 個 MAC 位址**。
* 當使用者通過 802.1X 認證後，該 Port 即被該電腦的網卡鎖定。

2. **違規懲罰機制：觸發鎖孔 (Violation Mode = Shutdown)**：

* 違反規則時（例如實體孔被拔下接上傻瓜交換器，導致 Switch 偵測到第 2 個 MAC 位址時），交換器必須**立刻將該 Port 切換至 `Err-Disable` (Shutdown) 狀態**，直接斷開實體連線。
* 必須由資訊人員排查確認安全後，於資訊中控台手動輸入 `shutdown` / `no shutdown` 才能恢復連線，達到警告與阻斷效果。

3. **防止惡意交換器接入 (Spanning-Tree BPDU Guard)**：

* 所有 Edge Port全面啟用 `bpduguard enable`。
* 一旦有人嘗試接入私自帶來的網管型交換器或會發送 BPDU 封包的設備，Cisco Switch 會在 1 秒內識別並永久關閉該埠口，防範網路拓撲被惡意篡改或產生網路迴圈 (Loop)。

---

### 💻 Cisco Switch 實務設定指令參照 (IOS Configuration Guide)

以下為資深工程師於實體交換器部署時之標準設定腳本：

```text
interface range gigabitEthernet 1/0/1 - 48
 description Edge_User_Ports_with_802.1X
 switchport mode access
 
 ! --- 啟用 802.1X 動態 VLAN 與 MAB 支援 ---
 authentication port-control auto
 dot1x pae authenticator
 mab
 
 ! --- 啟用 Port Security 反私接防禦 ---
 switchport port-security
 switchport port-security maximum 1
 switchport port-security violation shutdown
 switchport port-security mac-address sticky
 
 ! --- 啟用 迴圈與非法交換器防護 ---
 spanning-tree portfast
 spanning-tree bpduguard enable
 exit
 ! =======================================================
 ! 1. 啟用 DHCP Snooping (核心基礎)
 ! =======================================================
 ip dhcp snooping
 ip dhcp snooping vlan 10,15,20,25,30,60,70,75,80,90
 no ip dhcp snooping information option (註：這行必打，否則 pfSense 有時會不發 IP)
 
 ! =======================================================
 ! 2. 啟用 DAI (防 ARP 欺騙) 與 IPSG (防私改IP)
 ! =======================================================
 ip arp inspection vlan 10,15,20,25,30,60,70,75,80,90
 
 ! =======================================================
 ! 3. 設定「信任孔」：通往 pfSense 防火牆的大水管 (以 Port-Channel 1 為例)
 ! =======================================================
 interface port-channel 1
 description Link_to_pfSense_Firewall_Trunk
 ip dhcp snooping trust
 ip arp inspection trust
 exit
 
 ! =======================================================
 ! 4. 設定「員工/會議室實體孔」：嚴格執法
 ! =======================================================
 interface range gigabitEthernet 1/0/1 - 48
 description Edge_User_Ports
 
 ! --- 啟動 IP Source Guard (防偽造 IP/MAC) ---
 ip verify source tracking port-security
 
 ! --- 設定 DAI 的速率限制 (防止黑客發動 ARP DoS 癱瘓 Switch) ---
 ip arp inspection limit rate 50 log
 ! --- 

 ! --- 1. 一般員工桌面的實體孔（單一孔只有一台電腦）：維持 15-20，防禦力最強 ---
interface range gigabitEthernet 1/0/1 - 40
 ip arp inspection limit rate 15
 exit
 
 ! --- 2. 專門插無線 AP 的實體孔（一孔多設備）：調大上限，防止誤殺 ---
 interface range gigabitEthernet 1/0/41 - 45
 description Link_to_Wireless_AP
 ip arp inspection limit rate 100 log
 exit

```

---

### 💡 實務運作的小提醒（資訊主管的維運心法）

這套設定下去後，內網的實體安全性直接拉到最高。但有兩個日常辦公的情境會觸發「誤殺」，建議您先放在心上：

1. **辦公桌底下的「IP 電話（IP Phone）」共用孔情境**：

* **狀況**：很多公司習慣把網路線插在 IP 電話上，再從 IP 電話後面拉一條線插到員工電腦（這在 Cisco 叫 Voice VLAN 串接）。這時候同一個交換器 Port 其實會看到 **2 個 MAC**（一個是電話、一個是電腦）。
* **調整**：如果你們公司未來有這種環境，該 Port 的 `switchport port-security maximum` 必須從 `1` 改為 `2`（設定為 1 張 Voice MAC + 1 張 Data MAC），否則員工一開機，孔就會直接被 Shutdown。

2. **使用者更換新筆電、新網卡**：

* **狀況**：因為我們開了 `sticky`（黏性 MAC），當某個座位的員工換了新電腦，插上網路線時，Switch 會認為出現了第 2 個 MAC 而把孔鎖死。
* **維運**：這完全是正常且預期的資安防護。這時資訊人員需要登入 Switch，對該 Port 執行 `no switchport port-security mac-address sticky` 清除舊網卡紀錄，即可重新綁定。

```

```

# InfraLab01

---

> Infrastructure as Code for Real-World SMEs
>
> 以有限預算建置具備企業級管理能力與安全性的基礎架構環境。
>
> 涵蓋 Active Directory、PKI、Docker、Network Infrastructure、Windows Security Baseline 。逐步向自動化邁進。

---

## 專案簡介

InfraLab01 是一套以 Infrastructure as Code（IaC）理念為核心建置的基礎架構實驗室專案。

本專案將 Active Directory、Public Key Infrastructure（PKI）、Docker 服務、網路設備設定、Windows 安全強化與各類基礎服務之部署流程，以腳本化、標準化及版本化方式進行管理，藉此達成：

- 可重複建置（Repeatable）
- 可版本控制（Version Controlled）
- 可文件化（Documented）
- 可驗證（Verifiable）
- 可持續改善（Continuous Improvement）

除了自動化部署之外，本專案亦作為研究、學習、驗證及教育訓練用途之實驗平台。

---

## 設計目標

本專案旨在建立一套可快速複製、容易維護且安全性良好的企業基礎架構實驗環境，涵蓋：

- Microsoft Active Directory
- Microsoft AD CS
- OpenSSL Root CA
- Docker Container Platform
- Windows Server Infrastructure
- Enterprise Networking
- Security Baseline
- Identity and Access Management
- Infrastructure Automation

---

## 專案結構
```text
.
├── active-directory   # AD DS
│   ├── bootstrap      # AD DS建置指令
│   └── groups-ous     # 群組與OU
│
├── archive            # 暫存中檔案
│
├── containers         # Docker 容器
│   ├── diouxx_glpi    # GLPI 資訊資產盤點 修改自 https://hub.docker.com/r/diouxx/glpi
│   ├── forgejo        # 內部Git Repository
│   ├── portainerce    # Docker 容器管理
│   └── redmine        # REDMINE 專案管理
│
├── network            # 網通相關
│   ├── cisco          # cisco 網通設備設定檔
│   └── docs           # 網通相關說明文件
│
├── pki                # 企業內PKI
│   ├── rootca_openssl # Air-gapped OpenSSL root CA建置
│   └── subca-adcs     # AD CS 次級CA (subordinate CA)建置, 包含EAP-TLS範本建置
│
└── radius-nps         # Microsoft Network Policy Server (RADIUS) 相關設定
```


---

## 主要內容

### Active Directory

透過 PowerShell 自動化部署：

- Forest 建立
- Domain Controller 部署
- OU 結構建立
- 使用者與群組管理
- 權限委派
- 基本安全強化
- 稽核政策

---

### Public Key Infrastructure (PKI)

#### OpenSSL Root CA

包含：

- Offline Root CA 建立
- Root Certificate 發行
- CRL 發布
- Certificate Signing Workflow

#### Microsoft AD CS Subordinate CA

包含：

- Enterprise Subordinate CA 建置
- CA 組態設定
- CRL 及 AIA 發布設定
- 憑證範本管理
- PKI 驗證與測試

---

### Docker Services

提供各類服務部署範例：

- Docker Compose
- Environment Files
- Container Configuration Files

可作為：

- 管理平台
- 監控平台
- 測試平台
- 驗證平台

之基礎環境。

---

### Network Infrastructure

收錄多種網路設備設定範例：

#### Cisco

- VLAN
- Trunk
- Routing
- Security Hardening
- Access Control

---

### 自動化維運工具

收錄各類：

- PowerShell Scripts
- Batch Scripts
- CMD Scripts
- Configuration Files

用於：

- 部署
- 維運
- 驗證
- 稽核
- 故障排除

---

## 使用建議

建議依照以下順序進行建置：

1. 規劃 IP 位址與 VLAN
2. 規劃 Firewall Policy
3. 規劃 Active Directory 網域參數
4. 建立虛擬化平台
5. 建立 Active Directory Domain Services
6. 建立 Offline Root CA
7. 建立 AD CS Subordinate CA
8. 建立 EAP-TLS 憑證範本
9. 部署所需 Container Services
10. 驗證各項服務功能

---

## 授權

本專案採用 Apache License 2.0 授權。

您可以在遵守 Apache License 2.0 條款的前提下：

* 自由使用本專案
* 修改與延伸本專案內容
* 再散布原始碼或衍生作品
* 用於教育、研究或商業用途
* 建立並發佈衍生專案

Apache License 2.0 同時提供明確的專利授權條款，可降低企業導入與二次開發時的法律風險。

完整授權內容請參閱：

LICENSE

---

## 免責聲明

本專案主要用於：

* 技術研究
* 教育訓練
* 實驗室環境建置
* 概念驗證（PoC）
* 基礎架構自動化驗證

所有腳本與設定皆應先於測試環境驗證後再導入正式環境。

正式環境部署前建議：

* 完整測試所有腳本
* 執行安全性評估
* 驗證系統相容性
* 建立備份與回復機制
* 遵循組織變更管理流程

專案作者不對因使用本專案而造成之任何直接或間接損失承擔責任。

---

## AI 協作說明

本專案於研究、文件撰寫、腳本開發、架構設計討論與技術驗證過程中，使用多種生成式 AI 工具作為輔助協作平台。

AI 協作範圍包含：

- 技術文件撰寫
- PowerShell 腳本開發
- Docker Compose 與 YAML 設定建議
- Active Directory 架構討論
- Public Key Infrastructure（PKI）設計討論
- 網路設備設定建議
- 安全控制措施研究
- 技術問題分析與故障排除
- 教育訓練教材撰寫
- Infrastructure as Code 實作規劃

### 使用之 AI 平台 (依原廠字母排序)

- Anthropic Claude
- Google Gemini
- Microsoft Copilot
- OpenAI ChatGPT

### 重要聲明

所有由 AI 產生的內容，包括但不限於：

- 程式碼
- 腳本
- 設定檔
- 架構建議
- 技術文件
- 安全建議

皆必須經過人工審查、實驗室驗證與實際測試後，方可納入本專案。

AI 為輔助工具，而非最終決策者。

### 專案開發原則

本專案遵循以下原則：

> 理解原理優先於直接套用方案。

> 驗證結果優先於理論推測。

> 人工審查優先於 AI 建議。

> 實際測試優先於文件說明。

所有技術內容皆以實際驗證結果為準。

---

### 實驗測試環境

防火牆: pfsense Community Edition
虛擬化平台: PROXMOX VE 9.2
Windows Server 2022
Debian Linux 13
Windows 11 Pro
Core switch: Cisco Catalyst WS-C2960X-24TS-L
Edge switch: Cisco Catalyst WS-C2960X-24TS-L
SIP話機: FANVIL SIP IP Phone
WiFi AP: HPE Aruba AP-305 (刷成胖AP)

---

## 作者理念

InfraLab01 並非單純的腳本倉庫，而是一套持續演進的基礎架構實驗室框架。

專案聚焦於：

- Microsoft Active Directory
- Public Key Infrastructure (PKI)
- Windows Security
- Enterprise Networking
- Container Platform
- Infrastructure Automation

並以：

> 「中小企業也能建置企業級管理與安全能力」

作為長期發展方向。

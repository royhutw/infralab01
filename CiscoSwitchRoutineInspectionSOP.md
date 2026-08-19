# Cisco Edge/Core Switch 網路安全架構巡檢 SOP

適用範圍：802.1X (EAP-TLS) + MAB + Guest/Critical VLAN + DHCP Snooping + DAI + Port-Security + CoPP 架構
適用設備：SW-HQ-Core-02、SW-HQ-Edge-200（可依實際設備數量擴充）

---

## 一、每日巡檢（建議：上班時段開始前執行一次，約5-10分鐘）

目的：快速掌握「有沒有Port被鎖住」、「認證系統是否健康」，若有異常能在使用者回報前先發現。

| # | 檢查項目 | 指令 | 正常標準 / 異常判斷 |
|---|---|---|---|
| 1 | Port 是否有被 err-disable | `show interfaces status err-disabled` | 應為空清單；若有輸出，記錄Port與err-disable原因(arp-inspection/dhcp-rate-limit/bpduguard/port-security) |
| 2 | RADIUS Server 存活狀態 | `show aaa servers` | 兩台NPS皆應為 `alive`；若任一台顯示 `dead`，需立即通報並檢查NPS服務狀態 |
| 3 | 目前所有認證Session總覽 | `show authentication sessions` | 確認Session數量與預期接入裝置數量大致相符；留意是否有大量卡在 `Authenticating` 未完成 |
| 4 | DAI/Snooping近期是否有異常增長 | `show ip arp inspection statistics` <br> `show ip dhcp snooping statistics detail` | 與前一日數字比對，Deny/Failure計數是否有異常暴增(可能代表攻擊或裝置異常) |
| 5 | STP是否有不一致或Root變動 | `show spanning-tree inconsistentports` <br> `show spanning-tree summary` | 應無 inconsistent ports；Root Bridge 應維持為 Core Switch |
| 6 | 關鍵錯誤日誌彙總 | `show logging \| include %SW_DAI\|%DOT1X\|%MAB\|%AUTHMGR\|%DHCP_SNOOPING\|%PM-4-ERR_DISABLE` | 檢視是否有新增、未處理過的錯誤訊息 |

**若第1項發現有 err-disable 的Port** → 跳到本文件「四、事件排錯流程」對應章節處理，勿直接 `shutdown`/`no shutdown` 就結案，需先確認根因。

---

## 二、每週巡檢（建議：每週固定一天，約20-30分鐘）

目的：檢查設定一致性、累積性風險，避免小問題演變成大故障。

| # | 檢查項目 | 指令 | 重點 |
|---|---|---|---|
| 1 | Port-Security學習狀態 | `show port-security` <br> `show port-security address` | 確認Eth0/2(應2組MAC: Voice+Data)、Eth0/3(應1組MAC)實際學到的數量符合預期，無異常多出的MAC |
| 2 | Trunk兩端設定一致性 | `show interfaces trunk` | Core↔Edge、Core↔Firewall兩端Trunk的Allowed VLAN、Native VLAN需完全一致，避免單邊漏改 |
| 3 | VLAN清單完整性 | `show vlan brief` | 確認沒有裝置誤落在非預期VLAN（尤其留意是否有裝置意外留在VLAN 98 Critical，代表曾發生過RADIUS中斷） |
| 4 | DHCP Snooping Binding Table檢視 | `show ip dhcp snooping binding` | 抽查幾筆Static Binding(VM Host靜態IP)是否都還在，尤其近期有無新增/汰換伺服器 |
| 5 | RADIUS統計趨勢 | `show radius statistics` | 觀察Access-Reject、Timeout比例是否有上升趨勢，可能是憑證即將大量到期或NPS效能吃緊的前兆 |
| 6 | CoPP流量分類統計 | `show policy-map control-plane` | 確認各class-map的conform/drop封包數，留意 class-default 是否有異常大量流量被丟棄(可能代表有未分類的異常流量) |

---

## 三、每月健檢（建議：每月月初，約1小時，可安排在維護窗口）

目的：處理累積性、規劃性的項目，而非單純故障排除。

| # | 檢查項目 | 指令 / 動作 | 說明 |
|---|---|---|---|
| 1 | 憑證到期盤點 | 於AD CS / NPS端檢查即將到期的機器憑證清單 | EAP-TLS依賴憑證，建議提前30天盤點，避免大量裝置同時因憑證到期集體認證失敗 |
| 2 | DHCP Snooping Database備份確認 | `show ip dhcp snooping database` | 確認write-delay有正常寫入，且備份檔案存在、可讀取 |
| 3 | Static Binding盤點更新 | 對照VM Host實際伺服器清單 vs. `show ip source binding` | 確認是否有新增/淘汰的靜態IP伺服器尚未同步登記 |
| 4 | err-disable歷史事件回顧 | 彙整當月`err-disable`相關log | 若同一Port重複發生，需評估是否為裝置本身異常(壞NIC/迴圈)而非單純誤觸發 |
| 5 | RADIUS雙機備援演練 | 手動停用其中一台NPS服務，觀察`show aaa servers`是否正確判斷dead並切換 | 驗證備援機制實際可用，而非只是設定存在但沒驗證過 |
| 6 | 設定備份與版本比對 | 匯出`show running-config`並與上次備份做diff | 確認沒有未經記錄的手動變更(Configuration Drift) |
| 7 | CoPP速率合理性複查 | 對照當月`show policy-map control-plane`峰值流量 | 依實際觀察到的流量調整police速率，避免長期沿用上線初期的保守估計值；若本月有調整CoPP設定，需重新執行「四、CoPP生效驗證」章節的驗收流程 |

---

## 四、CoPP生效驗證（上線前一次性驗收，僅需執行一次，設定變更後需重跑）

目的：CoPP是靠底層ASIC/TCAM資源支援的功能，部分平台曾出現「CLI語法被接受，但硬體層並未真正強制生效」的情況。此驗收確保`policy-map COPP-POLICY`不只是設定成功，而是真的在硬體層限流。

**此章節與每日/每週/每月巡檢性質不同，屬於「一次性上線驗收」，建議在正式套用CoPP設定後、以及往後每次修改CoPP相關設定(class-map/ACL/police速率)後，都重新執行一次。**

| # | 步驟 | 指令 | 判斷標準 |
|---|---|---|---|
| 1 | 確認policy-map已正確掛載到control-plane | `show policy-map control-plane` <br> `show policy-map interface control-plane` | 應能看到完整的class清單(ICMP/ARP/DHCP/RADIUS/SSH/class-default)，且各class的police參數與設定檔一致 |
| 2 | 記錄基準值 | `show policy-map control-plane` | 套用初期先記錄一次所有class的conform/exceed封包計數器當作基準(此時應接近0) |
| 3 | 主動觸發超量流量測試(逐一驗證各class) | 見下方「各class觸發方式」 | 觸發後封包量應明顯超過該class設定的police速率 |
| 4 | 複查計數器是否確實變動 | `show policy-map control-plane` | conform計數器應增加；若刻意送出超過速率上限的流量，exceed(drop)計數器也應同步增加。**若計數器持續為0，代表該class很可能只是語法被接受、硬體層未真正生效，需進一步排查(檢查IOS版本、平台TCAM資源、是否需要`mls qos`全域啟用)** |
| 5 | 確認沒有非預期的雙重限流 | `show mls qos copp protocols`(若曾測試或啟用過`mls qos copp protocol`系列指令) | 確認沒有同時存在`mls qos copp protocol`與`control-plane policy-map`兩套機制同時作用在重疊流量上(例如ARP/DAI)，避免疊加限流互相干擾 |
| 6 | 確認class-default目前為監控模式 | `show running-config \| section COPP-POLICY` | 確認`class class-default`目前為`exceed-action transmit`(觀察階段)，尚未改為`drop`；待完成第7步觀察期後再決定是否收斂 |
| 7 | 觀察期後檢視class-default實際流量分布 | `show policy-map control-plane` (建議上線後持續觀察5-7天) | 確認class-default底下沒有大量非預期的合法流量被歸類於此；若有，考慮新增對應class明確分類，而非讓它一直落在兜底規則 |

### 各class觸發方式（用於第3步的主動測試）

| Class | 建議觸發方式 |
|---|---|
| ICMP-CLASS | 從管理主機對Switch管理IP(VLAN10)連續高速ping (`ping -t`或`fping`短間隔) |
| ARP-CLASS | 在同網段任意主機執行`arping`或`nmap -sn`對整個子網段掃描，製造大量ARP Request |
| DHCP-CLASS | 觀察VM Host或多台裝置同時開機時段(自然流量)，或用DHCP測試工具模擬多筆Discover |
| RADIUS-CLASS | 在多個Port同時觸發802.1X重新認證(`authentication timer restart`到期或手動bounce port)，製造密集RADIUS Request/Response |
| SSH-CLASS | 從PAW網段對Switch建立多個SSH連線嘗試(注意：勿觸發`login block-for`鎖定，測試前先確認帳密正確) |
| class-default | 較難主動觸發，建議以自然流量觀察為主，或送出一個刻意不在其他class定義範圍內的協定封包(如非標準UDP port)測試 |

### 驗收結論記錄表（建議填寫存檔，作為上線紀錄）

| Class | 語法確認 | 計數器有變動 | 速率符合預期 | 驗收日期 | 備註 |
|---|---|---|---|---|---|
| ICMP-CLASS | ☐ | ☐ | ☐ | | |
| ARP-CLASS | ☐ | ☐ | ☐ | | |
| DHCP-CLASS | ☐ | ☐ | ☐ | | |
| RADIUS-CLASS | ☐ | ☐ | ☐ | | |
| SSH-CLASS | ☐ | ☐ | ☐ | | |
| class-default | ☐ | ☐ | ☐（監控模式） | | |

---

## 五、正式設備到位後一次性檢查清單（Core-to-Core 升級為 10Gbit × 2 LACP）

目的：Lab環境使用單一實體連線驗證邏輯，正式環境Core-02↔Core-3改用10Gbit × 2 LACP，屬於拓樸與硬體層級的變更，需要一次性檢查設定是否正確轉換、並重新校準流量相關閾值。**此清單僅需在正式設備到位、完成LACP建置後執行一次；若日後再增減LACP成員或更換介面，需重新執行。**

### 5.1 LACP 設定範本（取代原本單一Interface的Trunk設定）

```
! 兩台Core Switch皆建議使用 mode active，確保任一端重啟時可主動發起協商
interface range TenGigabitEthernet1/0/1 , TenGigabitEthernet1/0/2
 channel-group 1 mode active
 channel-protocol lacp
!
interface Port-channel1
 description Peer Link to SW-HQ-Core-3 (LACP 2x10G)
 switchport trunk encapsulation dot1q
 switchport trunk native vlan 999
 switchport trunk allowed vlan 10,20,25,30,35,37,38,40,50,60,70-75,80,90,98
 switchport mode trunk
 ip dhcp snooping trust
 ip arp inspection trust
 spanning-tree guard root
 ! Storm-Control數值待5.2完成監控後再校準，此處先沿用保守值上線
 storm-control broadcast level pps 3000 1500
 storm-control multicast level pps 3000 1500
```

**重要提醒**：`ip dhcp snooping trust`、`ip arp inspection trust`、`switchport trunk allowed vlan` 等設定，**必須下在 `Port-channel1` 邏輯介面上，不要分別下在兩個實體介面(Te1/0/1、Te1/0/2)上**——這是LACP設定最常見的誤區，分別設定在實體介面上可能不生效或造成兩條成員鏈路行為不一致。

| # | 檢查項目 | 指令 | 判斷標準 |
|---|---|---|---|
| 1 | LACP是否成功協商為Bundle | `show etherchannel summary` | Port-channel1狀態應為`(SU)`，兩個成員Port應為`P`(bundled in port-channel)，而非`I`(individual，代表協商失敗) |
| 2 | 確認邏輯介面設定正確套用 | `show run interface Port-channel1` | 確認`trust`、`allowed vlan`、`guard root`皆已正確顯示在Port-channel邏輯介面上 |
| 3 | 確認兩個成員實體介面設定單純 | `show run interface TenGigabitEthernet1/0/1` <br> `show run interface TenGigabitEthernet1/0/2` | 應只有`channel-group 1 mode active`，不應殘留舊有的`switchport trunk`等個別設定 |
| 4 | 拔線測試單條成員故障切換 | 實際拔除其中一條10G線材，觀察 `show etherchannel summary` | 應剩餘Port自動承擔全部流量，不中斷；兩邊Core互通性(ping對方VLAN10管理IP)應維持正常 |
| 5 | 確認DAI/DHCP Snooping信任鏈仍完整 | `show ip dhcp snooping` <br> `show ip arp inspection interfaces` | Port-channel1應正確顯示為trusted，與Lab階段的驗證邏輯一致 |

### 5.2 Storm-Control 重新校準（10G鏈路流量基準線與Gigabit不同）

Lab階段的`storm-control broadcast/multicast level pps 3000 1500`是針對Gigabit鏈路估算的保守值，直接套用在10G鏈路上可能過於寬鬆（等於變相失去防護效果）或過於嚴格（誤擋正常尖峰流量），需要重新觀察後校準。

| # | 步驟 | 指令 | 說明 |
|---|---|---|---|
| 1 | 上線初期先維持監控心態 | `show interfaces Port-channel1 counters broadcast` <br> `show interfaces Port-channel1 counters multicast` | 記錄至少1-2週的日常廣播/多播封包量基準值，涵蓋VM Host開機、日常辦公尖峰等情境 |
| 2 | 比對Lab保守值與實際觀察值 | 人工比對 | 若實際尖峰流量已接近或超過`3000/1500 pps`，需調高數值避免正式環境誤觸發storm-control導致Port被關閉 |
| 3 | 校準後正式套用 | `storm-control broadcast level pps <新數值> <新數值*0.5左右>` | 建議校準後的數值仍保留一定緩衝空間（如實際尖峰值的1.5-2倍），而非貼著實際尖峰值設定 |
| 4 | 同步檢視CoPP的ARP/DHCP-CLASS速率 | `show policy-map control-plane` | 10G鏈路匯聚流量後，ARP/DHCP相關CoPP速率(`ARP-CLASS`的500pps、`DHCP-CLASS`的128000bps)也建議一併重新評估是否仍然合理，避免鏈路升級後CoPP反而成為新的效能瓶頸 |

### 5.3 Firewall/pfSense 上聯備援評估（待辦事項，非本次必要條件）

Core-to-Core已升級為雙鏈路LACP後，`Gi0/0`(Core接Firewall/pfSense)這條路徑相對成為**架構中新的相對單點瓶頸**——若此鏈路中斷，即使Core-to-Core本身有備援，所有VLAN仍會因為失去對外Gateway與DHCP/DNS服務而無法正常運作。

| # | 評估項目 | 說明 |
|---|---|---|
| 1 | 確認pfSense硬體是否具備多個可用介面 | 若pfSense本身有支援LACP的網卡，評估是否能提供對稱的雙上聯 |
| 2 | 若pfSense暫無法支援LACP | 考慮至少規劃一條實體備援線材(即使是Standby、非Active-Active)，並搭配`spanning-tree`或簡單的Failover機制 |
| 3 | 長期規劃：pfSense CARP雙機 | 如先前討論，若要做到「Gateway層級的高可用性」，根本解法是評估pfSense CARP雙機部署，而非在Switch端疊加機制；此項目需要獨立的預算與專案規劃，本次僅記錄為待辦 |
| 4 | 記錄現況風險 | 若本次暫不處理，建議在架構文件中明確記錄「Firewall上聯目前為單點，已知風險，待後續預算規劃改善」，避免此風險被遺忘 |

---

## 六、Wi-Fi AP（Aruba IAP-305）上線一次性檢查清單

目的：Edge Switch `Gi0/1` 原先僅預留給支援802.1X的企業級AP，本節記錄實際選型（Aruba IAP-305）後的完整上線設定與驗證項目。**此清單僅需在AP正式上線時執行一次；若日後更換AP型號或調整SSID規劃，需重新檢視。**

### 6.1 架構決策摘要

| 項目 | 設計 |
|---|---|
| AP管理介面VLAN | VLAN 34（獨立規劃，不與VLAN37 IoT裝置混用，避免信任層級混雜） |
| 企業SSID（員工用） | WPA3-Enterprise，802.1X，AP擔任Authenticator，使用者VLAN由NPS依RADIUS Policy動態指派（依機器/使用者身份分配對應部門VLAN，**不是固定VLAN**） |
| 訪客SSID | WPA3-Personal（過渡模式，兼容WPA2），對應VLAN 90（Guest），沿用既有pfSense的Guest VLAN限制（僅WAN + 指定DNS） |
| `Gi0/1`（Core/Edge接AP的Port）裝置層防護 | **不使用802.1X/MAB**（Trunk Port不支援，詳見下方），改採 **Port-Security MAC綁定**，防止使用者誤將AP拔除、改接自己裝置 |

**重要提醒（避免混淆）**：AP管理介面VLAN與「連上企業SSID的使用者被分配到的VLAN」是兩件不同的事。前者只是AP自己被管理、以及作為RADIUS Client來源IP的網段；後者由NPS依裝置/使用者身份動態指派對應部門VLAN，兩者不可混為一談。

**為什麼`Gi0/1`不使用802.1X/MAB（重要，避免日後被誤認為設定遺漏）**：

Cisco IOS的802.1X框架（`dot1x`/`mab`/`authentication port-control auto`等指令）**不支援套用在Trunk Port上**，這是Cisco原生的結構性限制，橫跨各世代Catalyst平台（含2960-X及最新Catalyst 9000系列），並非本專案設定疏漏。官方文件明確指出：802.1X僅支援Layer 2 static-access Port與Layer 3 routed Port，若嘗試在Trunk Port上啟用802.1X會直接遭拒，反之亦然。由於`Gi0/1`需要以Trunk方式承載多個SSID對應的VLAN，無法改為Access模式，因此802.1X/MAB在此Port架構上完全不可行。

**為什麼`Gi0/1`最終採用 Port-Security MAC綁定**：

本組織的Edge Switch雖然安裝於有門禁管制的壁掛機櫃內，實體接觸風險已相對較低，但考量真正的威脅模型並非「蓄意攻擊者刻意繞過防護」，而是**一般使用者貪圖方便、隨手將AP網路線拔除改接自己裝置**這類非惡意情境——這種情境下，使用者通常不會特意偽造MAC位址，Port-Security的MAC-based防護即可有效攔阻。因此權衡實際威脅模型後，決定加回Port-Security，作為低成本、高效益的第一道防線。

**需要理解的防護邊界（非防護失效，是設計上已知的限制）**：MAC位址本質上可被軟體任意偽造，Port-Security無法防範真正蓄意繞過的攻擊者，僅能有效阻擋「不知情/圖方便」這類低成本情境。若威脅模型日後改變（例如評估有蓄意繞過的風險），需搭配其他機制（如加強實體門禁管制、或改用支援802.1X Supplicant的AP機種改走Access Port）補強，而非僅依賴Port-Security。

**設定語法重點（避免常見誤用）**：

```
interface GigabitEthernet0/1
 ...（Trunk相關設定不變）...
 ip dhcp snooping trust
 ip arp inspection trust
 ip arp inspection limit rate 100
 ! Port-Security：防止使用者誤將AP拔除、改接自己的裝置
 switchport port-security
 switchport port-security maximum 1
 switchport port-security mac-address <AP實際MAC位址>
 switchport port-security violation restrict
```

- **`maximum 1` 不可加 `vlan <ID>` 限定**——若限定特定VLAN（如`maximum 1 vlan 34`），只有該VLAN的MAC數量受限，Trunk上其餘VLAN（35/37/38/40…等）完全不受保護，達不到防止改接裝置的目的。務必使用不限定VLAN的全域`maximum 1`，涵蓋整個Trunk上所有VLAN流量加總僅允許1個MAC。
- **手動指定MAC，不使用`sticky`**——`sticky`會自動學習「第一個接上的裝置」的MAC並寫入設定，若套用順序不慎（例如尚未接上AP、或有人搶先接了其他裝置），會錯誤地把非AP裝置的MAC當作合法清單。應直接以`switchport port-security mac-address <AP實際MAC位址>`明確指定，避免因操作順序造成誤判。
- **`violation restrict`（而非`shutdown`）**——違規流量會被擋下但Port保持啟用，AP本身正常運作不受影響，僅多餘裝置的流量被阻擋，且會累計Counter供後續稽核，不需要人工介入重啟Port。

**設定變更前的建議習慣**：修改正式Port設定前，建議先執行 `show running-config interface <Port>` 存一份現況記錄，避免CLI逐行貼上設定時的操作失誤（如不慎刪除既有行）難以追查。

### 6.2 上線檢查清單

| # | 檢查項目 | 說明 |
|---|---|---|
| 1 | AP初始設定於隔離環境完成 | 透過Aruba Instant臨時Setup SSID或直連方式，先完成VLAN/RADIUS/SSID設定並驗證正常，再移至`Gi0/1`正式上線，避免設定過程干擾正式網路 |
| 2 | AP管理介面IP設定於VLAN 34 | 手動指定，不使用DHCP自動取得（除非VLAN34的DHCP範圍已規劃保留給AP的固定/保留位址） |
| 3 | Virtual Controller IP固定 | Aruba Instant叢集模式下，實際發送RADIUS請求的來源IP會是Virtual Controller，須明確配置固定IP，避免叢集內Failover導致來源IP漂移、RADIUS Client設定失效 |
| 4 | NPS新增此AP為RADIUS Client | 來源IP填入VLAN34網段內的Virtual Controller固定IP，設定獨立Shared Secret |
| 5 | NPS政策補上Wireless NAS-Port-Type分支 | 既有Machine/User Auth政策若條件限定`NAS-Port-Type = Ethernet`，需另外複製一份條件改為`Wireless - IEEE 802.11`，否則所有Wi-Fi裝置的802.1X認證會因條件不符而落入Deny All，導致企業SSID完全無法使用 |
| 6 | 企業SSID正確設定WPA3-Enterprise + 802.1X | 確認RADIUS Server指向NPS雙機（NPS-1/NPS-2），且VLAN欄位設定為「依RADIUS動態指派」，不手動寫死VLAN |
| 7 | 訪客SSID正確對應VLAN 90 | 手動指定VLAN 90，不可使用預設跟隨AP管理VLAN；開啟Client Isolation（用戶端隔離），避免訪客裝置互相可見 |
| 8 | 訪客SSID採WPA3-Personal過渡模式 | 使用Transition/Mixed Mode相容WPA2裝置，避免較舊訪客裝置無法連線 |
| 9 | `Gi0/1` 設定為純Trunk，不套用802.1X/MAB/Port-Security | 確認`switchport mode trunk`、`switchport trunk allowed vlan`（含VLAN34、不含VLAN10）、`ip dhcp snooping trust`、`ip arp inspection trust`、`ip arp inspection limit rate 100`皆已正確設定；確認未殘留任何`dot1x`/`mab`/`authentication`相關指令（Trunk Port不支援，殘留設定僅造成混淆） |
| 10 | 確認壁掛機櫃門禁管制前提成立 | 確認機櫃鑰匙/門禁為集中管理、領用登記，此為「不套用Port-Security」決策的成立前提，需定期覆核 |
| 11 | 端對端測試 | 分別用一台已加入AD網域的公司筆電（企業SSID）與一台未設定的裝置（訪客SSID）實際連線測試，確認VLAN指派、上網範圍符合預期；並在NPS Event Log與交換器端確認認證記錄正常 |
| 12 | 建立CDP/LLDP鄰居巡檢基準 | 執行`show cdp neighbors detail`與`show lldp neighbors detail`，記錄`Gi0/1`正常情況下應顯示的AP身份資訊，供日後巡檢比對 |

---

## 七、事件排錯流程（發生異常時的處理順序）

### 情境A：使用者回報「無法上網/認證失敗」

```
1. show authentication sessions interface <Port> details
   → 確認目前卡在哪個階段、走dot1x還是mab、被分配到哪個VLAN

2a. 若顯示 Authz Failed / Auth Fail
    → show aaa servers 確認RADIUS是否正常
    → test aaa group NPS-GROUP username <帳號> password <密碼> legacy 驗證通道
    → 檢查憑證是否過期/被撤銷（NPS端事件檢視器）

2b. 若顯示 No Response
    → 確認裝置端802.1X supplicant / Wired AutoConfig服務是否啟動
    → 確認網卡驅動、有線802.1X設定檔(GPO)是否正確套用

2c. 若被分配到VLAN 98 (Critical)
    → 立即檢查 show aaa servers，代表RADIUS當下判定為不可達
    → 檢查NPS服務狀態、網路可達性(ping/traceroute)
```

### 情境B：出現 DAI Deny 日誌（%SW_DAI-4-DHCP_SNOOPING_DENY）

```
1. show ip dhcp snooping binding
   → 該IP/MAC是否存在合法binding

2. 若binding不存在：
   → 該裝置是否為Static IP但未登記 ip source binding？（補登記）
   → 或裝置該走DHCP但DHCP流程失敗？
      → show ip dhcp snooping statistics detail 找出失敗原因
      → 確認上聯Port是否有 ip dhcp snooping trust

3. 確認後，受影響裝置需重新觸發DHCP（release/renew或重插網路線）
```

### 情境C：Port被err-disable

```
1. show interfaces status err-disabled
   → 確認觸發原因(arp-inspection / dhcp-rate-limit / bpduguard / psecure-violation / root-guard)

2. 依原因排查：
   - arp-inspection/dhcp-rate-limit → 是否為短時間內裝置大量開機(如VM Host重啟)？
     若為預期內行為，考慮調高該Port的limit rate
   - bpduguard → 該Port是否誤接了另一台Switch/Hub造成迴圈？
   - psecure-violation → 是否有非授權MAC接入，或合法裝置更換過網卡？
   - root-guard → 下游是否有Switch的STP Priority被誤改？

3. errdisable已設定30秒自動復原(errdisable recovery interval 30)
   → 若持續重複觸發，勿只靠自動復原，需找出根因並人工介入
```

### 情境D：RADIUS雙機皆判定為dead（大量Port落入VLAN 98）

```
1. 立即檢查NPS服務狀態（兩台）
2. 檢查Switch到NPS的三層連通性 (ping 192.168.10.13 / .14)
3. 檢查UDP 1812/1813是否被中間設備(防火牆規則)誤擋
4. 確認 radius-server dead-criteria / deadtime 設定是否過於敏感導致誤判
5. 問題排除後，Port不會自動離開Critical VLAN，需執行：
   authentication event server alive action reinitialize 已設定，
   RADIUS恢復後應自動觸發重新認證；若未觸發，可手動 shutdown/no shutdown 該Port
```

---

## 八、指令總覽速查表

| 分類 | 指令 |
|---|---|
| 認證/Session | `show authentication sessions [interface X details]`、`show dot1x all`、`show mab all` |
| RADIUS/AAA | `show aaa servers`、`show radius server-group NPS-GROUP`、`show radius statistics`、`test aaa group NPS-GROUP username X password Y legacy` |
| DHCP Snooping | `show ip dhcp snooping`、`show ip dhcp snooping binding`、`show ip dhcp snooping statistics detail`、`show ip dhcp snooping database` |
| DAI | `show ip arp inspection interfaces`、`show ip arp inspection statistics`、`show ip arp inspection log`、`show ip arp inspection vlan X` |
| Port-Security | `show port-security`、`show port-security interface X`、`show port-security address` |
| STP | `show spanning-tree summary`、`show spanning-tree inconsistentports`、`show spanning-tree vlan X` |
| err-disable | `show interfaces status err-disabled` |
| CoPP | `show policy-map control-plane`、`show policy-map interface control-plane` |
| Trunk/VLAN | `show interfaces trunk`、`show vlan brief`、`show interfaces switchport` |
| 日誌 | `show logging \| include %SW_DAI\|%DOT1X\|%MAB\|%AUTHMGR\|%DHCP_SNOOPING\|%PM-4-ERR_DISABLE` |

---

## 九、已知的備選強化方向（非必要，供未來評估）

本章節記錄目前架構中「已經過討論、暫不採用，但保留作為未來強化選項」的設計決策，避免這些討論內容隨時間遺失，之後有需要時可直接參考。

### 9.1 Server Port（VM Host）的 ARP 防護：最終決策為整段 Trust（不採用 ARP ACL）

**決策沿革**：本節原先評估過兩個方案——(A) Server Port整段trust，DAI/IPSG完全交由虛擬化網路層負責；(B) 改用ARP ACL（`ip arp inspection filter`），在不綁定Port的前提下，仍對VLAN 10,20,25,30保留基本的ARP Spoofing防護。方案(B)曾一度導入並測試，但**經管理層評估後，最終決定放棄方案(B)，維持方案(A)**。

**放棄ARP ACL方案的理由**：ARP ACL需要針對每一台VM的IP/MAC組合手動維護清單，這份清單必須跟虛擬化環境的VM生命週期（新增、汰換、遷移）同步更新。但虛擬化主機與VM的遷移、備份、還原本身已經是繁重的日常工作，若同時還要求維運人員在Switch上同步維護對應的ARP ACL，會在真正緊急的故障排除或緊急遷移時刻，額外增加維運壓力與人為疏漏風險（忘記同步更新清單，導致合法VM流量被誤擋）。經評估，這個維護成本與其提供的額外防護效益不成比例。

**最終設定**：

```
! Core Switch 接 Virtualization Host 的 Port
interface GigabitEthernet0/1
 ip dhcp snooping trust
 ip arp inspection trust

! VLAN 10,20,25,30 不再納入DAI啟用範圍
ip arp inspection vlan 35,37,38,40,50,60,70-75,80,90,98

! 已移除，不再維護：
! arp access-list VM-STATIC-ARP-ACL ...
! ip arp inspection filter VM-STATIC-ARP-ACL vlan 10,20,25,30 static
```

**風險轉移說明（重要）**：Tier 0（VLAN10）、T0PAW（VLAN20）、T0BZ（VLAN25）、T1（VLAN30）這幾個VLAN — 也就是架構中最敏感的管理／特權網段 — 現在**完全依賴虛擬化網路層（vDS Port Security／NSX等）做ARP Spoofing防護，Switch層級不再檢查**。此為管理層已知並接受的風險轉移，**非設定疏漏**。

**維運提醒**：
- 建議定期（每季或每次虛擬化平台重大變更後）跟虛擬化維運團隊確認，vDS Port Security／NSX等機制**是否真的已啟用、且涵蓋這四個VLAN**，而不僅是理論上可以做但尚未落實——避免變成Switch層與虛擬化層兩邊都沒有實際防護的空窗。
- 若未來虛擬化平台的維運模式改變（例如導入自動化工具，VM異動能自動同步更新網路設定），可重新評估是否有低維護成本的方式恢復ARP ACL這層防護，屆時可參考本節保留的方案(B)設定範本。
- `Gi0/0`（接Firewall）、`Gi3/2`（接Core-3）等骨幹鏈路上的`ip arp inspection trust`，雖然仍保留設定，但由於VLAN10,20,25,30已整組退出DAI管轄範圍，這幾個VLAN在這些Port上的trust設定實務上不會被觸發判斷，屬於邏輯上自然的結果，非新增風險。

**風險轉移的具體對應方案（規劃中）**：目前規劃是採用**虛擬化交換器**（vDS Port Security，或若導入NSX則用Distributed Firewall/Segmentation）在Hypervisor層直接執行ARP/IP防護，取代原本設想在Core Switch上維護ARP ACL的做法。這個方向的優勢在於：

| 比較項目 | Core Switch的ARP ACL（已放棄） | 虛擬化交換器層防護（規劃方向） |
|---|---|---|
| 維護單位 | 網路團隊，需與虛擬化團隊的VM異動同步 | 虛擬化團隊自行管理，貼近VM生命週期 |
| VM遷移/新增/汰換時 | 需人工同步更新Switch設定 | 理論上可隨VM的Port Group/安全群組設定自動套用，不需額外同步一份Switch清單 |
| 適用範圍 | 僅Core Switch的Server Port看得到 | 可涵蓋VM彼此之間的東西向流量（即使兩台VM在同一台實體Host、流量未必經過實體Switch，這層防護仍然有效） |

**待確認事項（非本次SOP範圍，需與虛擬化團隊協作追蹤）**：
1. 目前的vSphere/NSX授權版本，是否確實包含vDS Port Security或Distributed Firewall功能（部分功能僅限特定授權層級，如NSX需要額外授權）。
2. 若使用vDS Port Security，是否已針對VLAN 10,20,25,30對應的Port Group，實際啟用MAC/IP綁定或ARP過濾之類的設定，而非僅停留在規劃階段。
3. 建議請虛擬化團隊提供一份對應的「虛擬化層防護清單」或設定截圖存檔，作為本SOP風險轉移聲明的佐證，下次每月健檢或年度稽核時可一併核對。

### 9.2 Core-to-Core（SW-HQ-Core-02 ↔ SW-HQ-Core-3）採「對等延伸」而非Stack

**決策背景**：曾評估將兩台Core Switch組成Stack，但考量Stack在韌體版本同步、線材/距離限制、單一控制平面故障可能同時影響兩台設備等限制，最終決定**不採用Stack**，改採兩台獨立、對等的Core Switch，透過Trunk互連。

**決策內容**：

| 項目 | 設計 |
|---|---|
| 實體連接 | Lab環境：單一GigabitEthernet Trunk（`Gi3/2`）；Production環境：10GbE × 2 LACP（詳見「五、正式設備到位後一次性檢查清單」5.1節） |
| 兩台Switch的設定 | 幾乎完全一致，**僅STP Priority不同**（Core-02為`priority 4096`，作為Primary Root；Core-3應設定較高的數值，如`priority 8192`，作為Secondary Root或非Root） |
| `Gi3/2`（Core-02接Core-3）Port設定 | `ip dhcp snooping trust` + `ip arp inspection trust`（骨幹鏈路互信，比照`Gi0/0`接Firewall的邏輯） |
| **是否套用 `spanning-tree guard root`** | **刻意不套用**（重要，見下方理由） |

**為什麼 `Gi3/2` 不套用 `spanning-tree guard root`（避免日後被誤認為遺漏而補加）**：

`guard root` 的作用是「此Port絕不允許收到比本機更優的BPDU，一旦收到就鎖Port」，這個機制的設計前提通常是「這個Port接的是下游、不該有資格參與Root Bridge選舉」。但Core-02與Core-3是**對等延伸關係**，Core-3需要能夠正常參與STP拓樸運算（即使目前設計上Core-02靠更低的Priority數字自然贏得Root），如果`Gi3/2`套用`guard root`，未來只要Core-3的STP Priority有任何正常的調整（例如規劃Secondary Root、或日後角色互換），這個Port會被誤鎖，造成非預期的中斷。

因此，兩台Core之間的Root仲裁，**完全依賴`spanning-tree vlan ... priority`數值差異來自然決定**，不依賴`guard root`這種強制鎖定機制。`guard root`僅保留用在**真正的下游鏈路**（如`Gi3/3`接Edge Switch），因為Edge Switch理論上不該有機會、也不需要參與Root Bridge選舉。

**維運提醒**：若未來確認兩台Core的角色關係改變（例如其中一台被降級為單純下游Edge角色），才需要重新評估是否在對應Port加回`guard root`；在目前的「對等延伸」架構定位不變的前提下，`Gi3/2`保持不套用`guard root`是正確且刻意的設定，非遺漏。

### 9.3 分層防護對照表（DAI/ARP ACL/Trust 的適用範圍原則）

DAI是否檢查一台裝置的ARP，取決於「該裝置的流量從哪個Port進入、該Port是否trust」，與裝置種類無關。整體架構的分層防護原則如下：

| 層級 | 負責保護的對象 | 機制 | 對應Port範例 |
|---|---|---|---|
| 骨幹鏈路（Core↔Firewall／Core↔Core／Core↔Edge） | 上下游設備自身的管理/轉發流量 | Trust（不檢查，信任來源） | `Gi0/0`、`Gi3/2`、`Gi3/3` |
| Core直接接VM Host的Server Port | VM／Hypervisor靜態IP | Trust（整段不檢查，防護責任交由虛擬化網路層負責，詳見8.1節） | `Gi0/1` |
| 每台Edge Switch的Access Port | 終端使用者裝置 | 802.1X/MAB + DHCP Snooping動態Binding（裝置走DHCP，不需要ARP ACL） | Edge Switch的Access Port |
| 每台Edge Switch自己的VLAN10管理介面 | Edge Switch本身 | 該Edge Switch自己啟用DAI涵蓋VLAN10即可，不需要在Core端登記 | 各Edge Switch的`interface Vlan10` |

**重要提醒**：DAI啟用是VLAN層級，不是實體交換器層級。若VLAN10的裝置未來可能接在Edge Switch底下（而非直接接在Core上），該Edge Switch自己的`ip arp inspection vlan`清單**必須涵蓋VLAN10**，否則即使Core端Trust鏈設計正確，Edge Switch自身對VLAN10的ARP流量仍會完全不受檢查。

### 9.4 VLAN98（Critical VLAN）採 Fail-Secure 設計：`fail` 與 `server dead` 共用同一VLAN

**決策內容**：Edge Switch的 `authentication event fail action` 與 `authentication event server dead action` 皆指向VLAN98，不額外區分「裝置認證被拒絕」與「RADIUS基礎設施故障」兩種情境。

**決策背景**：這兩種情境原本風險等級不同——`fail`代表裝置**主動嘗試認證但被RADIUS明確拒絕**（可能是憑證過期/撤銷/帳號停用，也可能是惡意嘗試混入），`server dead`則代表**RADIUS基礎設施本身故障**，與裝置好壞無關。曾評估是否應分開規劃獨立的VLAN（如額外的Restricted VLAN）以利排錯時快速分辨情境，但考量本組織訪客/BYOD裝置量體非常小，為此額外規劃一個VLAN、多維護一份pfSense政策的成本效益不划算，最終決定兩者共用VLAN98。

**採用Fail-Secure原則彌補分流缺失**：由於共用VLAN98，`fail`情境（裝置可能是異常/惡意嘗試）與`server dead`情境（單純基礎設施故障、裝置本身可能完全合法）被一視同仁對待。為避免因此在`server dead`情境下無意間放寬了`fail`情境該有的嚴格限制，VLAN98上pfSense的存取政策**設計為比VLAN90（Guest）更嚴格**——僅能存取受限制的白名單網站與Server，而非比照Guest VLAN的「WAN+指定DNS」等級。此設計確保不論觸發原因為何，落入VLAN98的裝置都被收斂到最低可用網路權限，不會因為情境不同而產生安全等級落差。

**已同步套用的Port**：`Gi0/2`（Multi-Domain）、`Gi0/3`（Single-Host），皆設定：
```
authentication event fail action authorize vlan 98
authentication event no-response action authorize vlan 90
authentication event server dead action authorize vlan 98
```
（`Gi0/2`額外保留 `authentication event server dead action authorize voice`，確保RADIUS故障時IP Phone仍可通話，此設定不受本節決策影響。）

**維運提醒（排錯方式需配合調整）**：由於VLAN98不再能單靠membership分辨觸發原因，查核VLAN98異常時，需先用 `show authentication sessions | include Vlan98` 找出受影響Port，再用 `show authentication sessions interface <Port> details` 確認個別Port的實際觸發事件是`Auth Failed`還是`Server Dead`，不可僅憑VLAN98人數判斷是否為RADIUS故障（呼應「七、事件排錯流程」情境D的判斷方式，此處為補充細節）。

---

- 本SOP基於IOU Lab環境設計，部分指令（如CoPP硬體驗證、NBAR protocol比對）在正式Catalyst設備上行為可能與Lab不同，正式上線前建議重新驗證一次。
- 建議將「每日巡檢」項目未來納入自動化腳本（如Python + Netmiko/Paramiko定期抓取並比對），減少人工執行負擔並能更早發現異常趨勢。
- NPS本身不支援RADIUS CoA，因此「情境D」中RADIUS恢復後的Port重新認證，依賴的是Switch端`authentication event server alive action reinitialize`機制，而非NPS主動推播，這點在教育維運人員時需特別說明清楚。
- Server Port（VM Host）目前採整段trust設計，已知的備選強化方向（ARP ACL）記錄於「八、已知的備選強化方向」，建議每次每月健檢覆盤虛擬化層防護狀態時一併參考，評估是否需要導入。
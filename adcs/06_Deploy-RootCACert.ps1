# ============================================================
#  Deploy-RootCACert.ps1
#  將 Root CA 憑證部署到網域內所有電腦的
#  受信任根憑證授權單位（Trusted Root Certification Authorities）存放區
#
#  部署方式：透過 GPO（群組原則）自動派發
#    電腦設定 → Windows 設定 → 安全性設定
#    → 公開金鑰原則 → 受信任的根憑證授權單位
#
#  適用網域：corp.foo.bar.tw
#  執行地點：DC 或具備 GroupPolicy / RSAT 模組的成員伺服器
#  執行身份：Domain Admins / Enterprise Admins
# ============================================================

#region ── 參數區（請依實際環境修改） ────────────────────────
$Params = @{
    # ── 網域設定 ─────────────────────────────────────────────
    DomainName      = 'corp.foo.bar.tw'
    DomainDN        = 'DC=corp,DC=foo,DC=bar,DC=tw'

    # ── Root CA 憑證路徑 ─────────────────────────────────────
    # 請將 RootCA.crt 複製到 DC 可存取的路徑
    RootCACertPath  = 'C:\CAConfig\RootCA.crt'

    # ── GPO 設定 ─────────────────────────────────────────────
    GPOName         = 'PKI - Deploy Root CA Certificate'
    GPOComment      = '部署 Root CA 憑證至所有電腦受信任根憑證存放區'

    # ── 套用目標（網域根層級，涵蓋所有電腦）────────────────
    GPOTarget       = 'DC=corp,DC=foo,DC=bar,DC=tw'

    # ── 憑證部署的登錄路徑（GPO 使用此路徑寫入憑證）────────
    # 此為 GPO 內部使用的固定路徑，一般不需修改
    TrustedRootStore = 'HKLM\SOFTWARE\Policies\Microsoft\SystemCertificates\Root\Certificates'
}
#endregion

Write-Host ""
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host "  部署 Root CA 憑證至網域所有電腦"                  -ForegroundColor Cyan
Write-Host "  網域：$($Params.DomainName)"                      -ForegroundColor Cyan
Write-Host "=================================================="  -ForegroundColor Cyan
Write-Host ""

#region ── 前置確認 ──────────────────────────────────────────

# ── 確認必要模組 ─────────────────────────────────────────────
Write-Host "[前置] 載入必要模組..." -ForegroundColor Yellow
Import-Module GroupPolicy    -ErrorAction Stop
Import-Module ActiveDirectory -ErrorAction Stop
Write-Host "      [OK] 模組載入完成" -ForegroundColor Green

# ── 確認 Root CA 憑證檔案存在 ────────────────────────────────
Write-Host "[前置] 確認 Root CA 憑證檔案..." -ForegroundColor Yellow
if (-not (Test-Path $Params.RootCACertPath)) {
    Write-Host "      [ERROR] 找不到 Root CA 憑證：$($Params.RootCACertPath)" -ForegroundColor Red
    Write-Host "      請將 RootCA.crt 複製到指定路徑後重新執行。" -ForegroundColor Red
    exit 1
}

# 讀取並驗證憑證
try {
    $RootCACert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
        $Params.RootCACertPath)
    Write-Host "      [OK] 憑證讀取成功" -ForegroundColor Green
    Write-Host "      Subject    : $($RootCACert.Subject)" -ForegroundColor Gray
    Write-Host "      Thumbprint : $($RootCACert.Thumbprint)" -ForegroundColor Gray
    Write-Host "      到期日     : $($RootCACert.NotAfter)" -ForegroundColor Gray
    Write-Host "      是否為 CA  : $($RootCACert.Extensions |
        Where-Object { $_.Oid.FriendlyName -eq 'Basic Constraints' } |
        ForEach-Object { $_.CertificateAuthority })" -ForegroundColor Gray
}
catch {
    Write-Host "      [ERROR] 憑證檔案無效：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

#endregion

#region ── Step 1：建立或取得 GPO ────────────────────────────
Write-Host ""
Write-Host "[1/5] 建立 GPO：$($Params.GPOName)..." -ForegroundColor Yellow

$GPO = Get-GPO -Name $Params.GPOName -Domain $Params.DomainName -ErrorAction SilentlyContinue
if ($null -eq $GPO) {
    $GPO = New-GPO -Name    $Params.GPOName `
                   -Comment $Params.GPOComment `
                   -Domain  $Params.DomainName
    Write-Host "      [OK] GPO 已建立：$($Params.GPOName)" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] GPO 已存在，將更新設定。" -ForegroundColor Yellow
}
Write-Host "      GPO ID：$($GPO.Id)" -ForegroundColor Gray
#endregion

#region ── Step 2：將 Root CA 憑證寫入 GPO ───────────────────
Write-Host ""
Write-Host "[2/5] 將 Root CA 憑證寫入 GPO..." -ForegroundColor Yellow

# 取得 GPO 的 SYSVOL 路徑
$GPOPath = "\\$($Params.DomainName)\SYSVOL\$($Params.DomainName)\Policies\{$($GPO.Id)}"

# 確認 GPO 目錄結構
$MachineRegPath = "$GPOPath\Machine\Microsoft\Windows NT\SecEdit"
New-Item -Path $MachineRegPath -ItemType Directory -Force | Out-Null

# ── 方法：使用 certutil 將憑證發布至 GPO ─────────────────────
# certutil -dspublish 會將憑證寫入 AD，
# 搭配 GPO 的「受信任根憑證授權單位」原則部署至所有電腦

# 先將憑證加入本機受信任根憑證存放區（供立即生效）
Write-Host "      將憑證加入本機受信任根存放區..." -ForegroundColor Gray
$LocalStore = New-Object System.Security.Cryptography.X509Certificates.X509Store(
    'Root', 'LocalMachine')
$LocalStore.Open('ReadWrite')

$ExistingCert = $LocalStore.Certificates |
    Where-Object { $_.Thumbprint -eq $RootCACert.Thumbprint }

if ($null -eq $ExistingCert) {
    $LocalStore.Add($RootCACert)
    Write-Host "      [OK] 已加入本機受信任根存放區" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] 憑證已存在於本機存放區" -ForegroundColor Yellow
}
$LocalStore.Close()

# ── 將憑證發布至 AD NTAuth 與 Root CA 容器 ───────────────────
Write-Host "      發布 Root CA 憑證至 AD..." -ForegroundColor Gray
certutil -dspublish -f $Params.RootCACertPath RootCA | Out-Null
Write-Host "      [OK] 已發布至 AD" -ForegroundColor Green

# ── 使用 GPO 登錄值部署憑證 ──────────────────────────────────
# 將憑證的 Thumbprint 與二進位內容寫入 GPO 登錄設定
# 讓所有收到此 GPO 的電腦自動信任此 Root CA

$CertThumbprint = $RootCACert.Thumbprint
$CertBytes      = $RootCACert.RawData

# 將憑證二進位資料轉為 Hex 字串（GPO 登錄格式）
$CertHex = ($CertBytes | ForEach-Object { $_.ToString('X2') }) -join ''

# 寫入 GPO 登錄值（電腦設定）
# 路徑對應：受信任的根憑證授權單位 → 憑證
$RegKey   = "HKLM\SOFTWARE\Policies\Microsoft\SystemCertificates\Root\Certificates\$CertThumbprint"

# Blob 格式：3 個固定 DWORD + 憑證原始資料
# DWORD 1：0x00000001（憑證類型）
# DWORD 2：0x00000001（編碼類型 = X509_ASN_ENCODING）
# DWORD 3：憑證資料長度
$BlobPrefix = [byte[]](
    0x01, 0x00, 0x00, 0x00,   # 憑證類型
    0x01, 0x00, 0x00, 0x00,   # 編碼類型
    ($CertBytes.Length -band 0xFF),
    (($CertBytes.Length -shr 8) -band 0xFF),
    (($CertBytes.Length -shr 16) -band 0xFF),
    (($CertBytes.Length -shr 24) -band 0xFF)
)
$BlobData = $BlobPrefix + $CertBytes

Set-GPRegistryValue -Name $Params.GPOName `
    -Key       $RegKey `
    -ValueName 'Blob' `
    -Type      Binary `
    -Value     $BlobData | Out-Null

Write-Host "      [OK] 憑證已寫入 GPO 登錄設定" -ForegroundColor Green
Write-Host "      登錄路徑：$RegKey" -ForegroundColor Gray
#endregion

#region ── Step 3：連結 GPO 至網域根層級 ─────────────────────
Write-Host ""
Write-Host "[3/5] 連結 GPO 至網域根層級..." -ForegroundColor Yellow

$ExistingLink = Get-GPInheritance -Target $Params.GPOTarget -Domain $Params.DomainName |
    Select-Object -ExpandProperty GpoLinks |
    Where-Object { $_.DisplayName -eq $Params.GPOName }

if ($null -eq $ExistingLink) {
    New-GPLink -Guid        $GPO.Id `
               -Target      $Params.GPOTarget `
               -Domain      $Params.DomainName `
               -LinkEnabled Yes `
               -Enforced    Yes | Out-Null
    Write-Host "      [OK] GPO 已連結（Enforced = Yes）" -ForegroundColor Green
} else {
    Write-Host "      [SKIP] GPO 連結已存在。" -ForegroundColor Yellow
}
#endregion

#region ── Step 4：強制套用至 DC（立即生效）──────────────────
Write-Host ""
Write-Host "[4/5] 強制更新本機群組原則..." -ForegroundColor Yellow
gpupdate /force /target:computer | Out-Null
Write-Host "      [OK] 本機 GPO 已更新" -ForegroundColor Green
#endregion

#region ── Step 5：驗證 ──────────────────────────────────────
Write-Host ""
Write-Host "[5/5] 驗證部署結果..." -ForegroundColor Yellow

# 確認憑證是否在本機受信任根存放區
$VerifyStore = New-Object System.Security.Cryptography.X509Certificates.X509Store(
    'Root', 'LocalMachine')
$VerifyStore.Open('ReadOnly')
$DeployedCert = $VerifyStore.Certificates |
    Where-Object { $_.Thumbprint -eq $RootCACert.Thumbprint }
$VerifyStore.Close()

if ($DeployedCert) {
    Write-Host "      [OK] Root CA 憑證已在本機受信任根存放區" -ForegroundColor Green
    Write-Host "      Subject    : $($DeployedCert.Subject)" -ForegroundColor Gray
    Write-Host "      Thumbprint : $($DeployedCert.Thumbprint)" -ForegroundColor Gray
} else {
    Write-Host "      [WARN] 本機受信任根存放區找不到憑證，請手動確認。" -ForegroundColor Yellow
}

# 確認 GPO 設定報告
Write-Host ""
Write-Host "      產生 GPO 報告..." -ForegroundColor Gray
Get-GPOReport -Name $Params.GPOName `
    -ReportType Html `
    -Path       '.\RootCA_Deploy_GPO_Report.html' `
    -Domain     $Params.DomainName
Write-Host "      [OK] GPO 報告：.\RootCA_Deploy_GPO_Report.html" -ForegroundColor Green
#endregion

#region ── 完成提示 ──────────────────────────────────────────
Write-Host @"

==================================================
  Root CA 憑證部署完成！

  GPO 名稱  ：$($Params.GPOName)
  套用範圍  ：$($Params.GPOTarget)（整個網域）
  憑證主體  ：$($RootCACert.Subject)
  Thumbprint：$($RootCACert.Thumbprint)
  到期日    ：$($RootCACert.NotAfter)

  用戶端生效方式：
    自動：等待 GPO 更新週期（約 90 分鐘）
    手動：在用戶端執行 gpupdate /force

  驗證方式（在用戶端執行）：
    # 確認憑證是否已部署
    Get-ChildItem Cert:\LocalMachine\Root |
        Where-Object { `$_.Thumbprint -eq '$($RootCACert.Thumbprint)' }

    # 或開啟憑證管理員確認
    certlm.msc
    → 受信任的根憑證授權單位 → 憑證
    → 尋找：$($RootCACert.Subject)

  注意事項：
    1. 新加入網域的電腦在第一次 GPO 套用後即自動信任
    2. 若有多台 DC，請等待 AD 複寫完成（預設 15 分鐘）
    3. 若環境有 OU 封鎖繼承（Block Inheritance），
       需另外在該 OU 連結此 GPO 或設定 Enforced
==================================================
"@ -ForegroundColor Green
#endregion

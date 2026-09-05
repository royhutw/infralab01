@echo off
:: ============================================================================
:: GLPI Agent 自動化無聲安裝與部署腳本 (適用於無 AD Workgroup 環境)
:: ============================================================================
title GLPI Agent Auto Installer

:: 1. 檢查是否具備系統管理員權限
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ERROR] 請「右鍵 - 以系統管理員身份執行」此批次檔！
    pause
    exit /b 1
)

echo =========================================================
echo  開始安裝 GLPI Agent...
echo =========================================================

:: 2. 設定參數與變數
set "SERVER_URL=http://glpi.foo.bar.tw:8080/front/inventory.php"
set "INSTALL_DIR=C:\Program Files\GLPI-Agent"

:: 自動搜尋當前目錄下的 GLPI-Agent MSI 安裝檔
set "MSI_FILE="
for %%f in ("%~dp0GLPI-Agent-*.msi") do set "MSI_FILE=%%f"

if not defined MSI_FILE (
    echo [ERROR] 在當前目錄找不到 GLPI-Agent-*.msi 安裝檔！
    echo 請將 MSI 安裝檔與此批次檔放在同一資料夾下。
    pause
    exit /b 1
)

echo [INFO] 找到安裝檔: %MSI_FILE%
echo [INFO] GLPI Server 網址: %SERVER_URL%

:: 3. 執行 MSI 無聲安裝 (Silent Installation)
:: /quiet: 無介面安裝
:: RUNNOW=1: 安裝完畢立刻發送第一次盤點資產
:: ADD_FIREWALL_EXCEPTION=1: 自動設定防火牆例外 (允許本地 HTTPD 服務)
echo [INFO] 正在進行無聲安裝，請稍候...
msiexec.exe /i "%MSI_FILE%" /quiet /norestart SERVER="%SERVER_URL%" RUNNOW=1 ADD_FIREWALL_EXCEPTION=1

if %errorlevel% neq 0 (
    echo [ERROR] MSI 安裝失敗，錯誤代碼: %errorlevel%
    pause
    exit /b 1
)

echo [SUCCESS] GLPI Agent 安裝完成！

:: 4. 觸發第一次完整資產盤點 (Force Inventory)
echo [INFO] 正在強制發送第一次完整資產盤點資料至 GLPI Server...
timeout /t 3 >nul
if exist "%INSTALL_DIR%\glpi-agent.bat" (
    call "%INSTALL_DIR%\glpi-agent.bat" --force
)

echo =========================================================
echo  GLPI Agent 部署完畢！
echo  該電腦已被註冊為 Windows 服務，未來將自動背景回報。
echo =========================================================
timeout /t 5
exit /b 0
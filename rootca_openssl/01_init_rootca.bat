@echo off
:: ============================================================
::  01_init_rootca.bat
::  Root CA 初始化腳本（只需執行一次）
::  建立目錄結構、產生私鑰、自簽 Root CA 憑證
::  適用：Windows 7 x64 + OpenSSL
:: ============================================================

setlocal

:: ── 參數區（請依實際環境修改） ──────────────────────────────
set CA_DIR=C:\RootCA
set OPENSSL=C:\OpenSSL-Win64\bin\openssl.exe
set CONFIG=%CA_DIR%\openssl-rootca.cnf

:: Root CA 私鑰長度（建議 4096）
set KEY_BITS=4096

:: Root CA 憑證有效期（25年 = 9131天，含6個閏年）
set CA_DAYS=9131

:: Root CA 辨別名稱（DN）
set CA_COUNTRY=TW
set CA_STATE=Taiwan
set CA_LOCALITY=Taipei
set CA_ORG=MyOrg Ltd
set CA_OU=IT Department
set CA_CN=MyOrg Root CA

:: ────────────────────────────────────────────────────────────

echo.
echo [INFO] ================================================
echo [INFO]  Root CA 初始化開始
echo [INFO] ================================================
echo.

:: ── Step 1：建立目錄結構 ─────────────────────────────────────
echo [1/6] 建立目錄結構...
mkdir "%CA_DIR%\private"   2>nul
mkdir "%CA_DIR%\certs"     2>nul
mkdir "%CA_DIR%\crl"       2>nul
mkdir "%CA_DIR%\newcerts"  2>nul
mkdir "%CA_DIR%\db"        2>nul
mkdir "%CA_DIR%\requests"  2>nul

:: ── Step 2：初始化資料庫檔案 ─────────────────────────────────
echo [2/6] 初始化資料庫...
if not exist "%CA_DIR%\db\index.txt"  type nul > "%CA_DIR%\db\index.txt"
if not exist "%CA_DIR%\db\index.txt.attr" echo unique_subject = yes > "%CA_DIR%\db\index.txt.attr"
if not exist "%CA_DIR%\db\serial"     echo 1000 > "%CA_DIR%\db\serial"
if not exist "%CA_DIR%\db\crlnumber"  echo 01   > "%CA_DIR%\db\crlnumber"

echo [INFO] 目錄結構如下：
echo        %CA_DIR%\
echo        ├── private\      （Root CA 私鑰，請嚴格保護）
echo        ├── certs\        （已簽發憑證）
echo        ├── crl\          （CRL 憑證撤銷清單）
echo        ├── newcerts\     （新簽發憑證備份）
echo        ├── db\           （資料庫與序號）
echo        └── requests\     （CSR 暫存）
echo.

:: ── Step 3：複製設定檔 ────────────────────────────────────────
echo [3/6] 複製設定檔...
if not exist "%CONFIG%" (
    echo [ERROR] 找不到設定檔：%CONFIG%
    echo [ERROR] 請先將 openssl-rootca.cnf 複製到 %CA_DIR%\
    pause
    exit /b 1
)

:: ── Step 4：產生 Root CA 私鑰（AES-256 加密保護） ────────────
echo [4/6] 產生 Root CA 私鑰（%KEY_BITS% bits，AES-256 加密）...
echo.
echo [WARN] 請設定一組強密碼來保護私鑰，此密碼之後每次簽發憑證都需要輸入！
echo.
"%OPENSSL%" genrsa -aes256 -out "%CA_DIR%\private\rootCA.key" %KEY_BITS%

if errorlevel 1 (
    echo [ERROR] 私鑰產生失敗！請確認 OpenSSL 路徑是否正確：%OPENSSL%
    pause
    exit /b 1
)

:: 設定私鑰檔案為唯讀，防止意外覆寫
attrib +R "%CA_DIR%\private\rootCA.key"
echo [INFO] 私鑰已設為唯讀保護。

:: ── Step 5：自簽 Root CA 憑證（25年）────────────────────────
echo.
echo [5/6] 自簽 Root CA 憑證（有效期 %CA_DAYS% 天 / 25 年）...
echo.
"%OPENSSL%" req -config "%CONFIG%" ^
    -new -x509 ^
    -key    "%CA_DIR%\private\rootCA.key" ^
    -out    "%CA_DIR%\rootCA.crt" ^
    -days   %CA_DAYS% ^
    -extensions v3_root_ca ^
    -subj   "/C=%CA_COUNTRY%/ST=%CA_STATE%/L=%CA_LOCALITY%/O=%CA_ORG%/OU=%CA_OU%/CN=%CA_CN%"

if errorlevel 1 (
    echo [ERROR] Root CA 憑證產生失敗！
    pause
    exit /b 1
)

:: ── Step 6：產生第一份 CRL（空白，有效期 1 年）───────────────
echo.
echo [6/6] 產生初始 CRL（有效期 365 天）...
"%OPENSSL%" ca -config "%CONFIG%" ^
    -gencrl ^
    -crldays 365 ^
    -out "%CA_DIR%\crl\rootCA.pem"

if errorlevel 1 (
    echo [ERROR] CRL 產生失敗！
    pause
    exit /b 1
)

:: 同時輸出 DER 格式（.crl）
"%OPENSSL%" crl -in "%CA_DIR%\crl\rootCA.pem" ^
    -outform DER ^
    -out "%CA_DIR%\crl\rootCA.crl"

:: ── 完成，顯示憑證資訊 ───────────────────────────────────────
echo.
echo [INFO] ================================================
echo [INFO]  Root CA 初始化完成！
echo [INFO] ================================================
echo.
echo [INFO] 驗證 Root CA 憑證內容：
"%OPENSSL%" x509 -in "%CA_DIR%\rootCA.crt" -noout -text -certopt no_pubkey,no_sigdump

echo.
echo [INFO] 重要檔案位置：
echo        Root CA 憑證：%CA_DIR%\rootCA.crt
echo        Root CA 私鑰：%CA_DIR%\private\rootCA.key  ← 請妥善保管！
echo        CRL (PEM)   ：%CA_DIR%\crl\rootCA.pem
echo        CRL (DER)   ：%CA_DIR%\crl\rootCA.crl
echo.
echo [WARN] ================================================
echo [WARN]  請立即備份 private\rootCA.key 到離線安全媒體！
echo [WARN]  此 VM 建議從此保持離線狀態。
echo [WARN] ================================================
echo.
pause
endlocal
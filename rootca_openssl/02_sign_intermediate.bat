@echo off
:: ============================================================
::  02_sign_intermediate.bat
::  使用 Root CA 簽發 Intermediate CA 憑證
::  執行時機：建立新的 Intermediate CA 時（數年一次）
::  流程：接收 Intermediate CA 的 CSR → 簽發 → 輸出憑證
:: ============================================================

setlocal

:: ── 參數區（請依實際環境修改） ──────────────────────────────
set CA_DIR=C:\RootCA
set OPENSSL=C:\OpenSSL-Win64\bin\openssl.exe
set CONFIG=%CA_DIR%\openssl-rootca.cnf

:: Intermediate CA CSR 檔案路徑（從 Intermediate CA 機器複製過來）
set INT_CSR=%CA_DIR%\requests\intermediateCA.csr

:: 簽發的 Intermediate CA 憑證輸出路徑
set INT_CRT=%CA_DIR%\certs\intermediateCA.crt

:: Intermediate CA 憑證有效期（10年 = 3650天）
set INT_DAYS=3650

:: ────────────────────────────────────────────────────────────

echo.
echo [INFO] ================================================
echo [INFO]  簽發 Intermediate CA 憑證
echo [INFO] ================================================
echo.

:: ── 確認 CSR 檔案存在 ────────────────────────────────────────
if not exist "%INT_CSR%" (
    echo [ERROR] 找不到 CSR 檔案：%INT_CSR%
    echo.
    echo [INFO]  請將 Intermediate CA 機器產生的 .csr 檔案
    echo [INFO]  複製到：%CA_DIR%\requests\intermediateCA.csr
    echo.
    pause
    exit /b 1
)

:: ── 顯示 CSR 內容供確認 ──────────────────────────────────────
echo [INFO] CSR 內容確認：
"%OPENSSL%" req -in "%INT_CSR%" -noout -text -reqopt no_pubkey,no_sigdump
echo.
echo [WARN] 請確認以上 CSR 資訊正確後再繼續。
echo.
pause

:: ── 使用 Root CA 簽發 Intermediate CA 憑證 ───────────────────
echo.
echo [INFO] 使用 Root CA 簽發 Intermediate CA 憑證（%INT_DAYS% 天）...
echo [INFO] 請輸入 Root CA 私鑰密碼：
echo.
"%OPENSSL%" ca -config "%CONFIG%" ^
    -extensions v3_intermediate_ca ^
    -days %INT_DAYS% ^
    -notext ^
    -md sha256 ^
    -in  "%INT_CSR%" ^
    -out "%INT_CRT%"

if errorlevel 1 (
    echo [ERROR] 簽發失敗！請確認：
    echo         1. Root CA 私鑰密碼是否正確
    echo         2. CSR 檔案是否有效
    pause
    exit /b 1
)

:: ── 驗證簽發結果 ─────────────────────────────────────────────
echo.
echo [INFO] 驗證 Intermediate CA 憑證：
"%OPENSSL%" x509 -in "%INT_CRT%" -noout -text -certopt no_pubkey,no_sigdump

echo.
echo [INFO] 驗證憑證鏈（Intermediate CA → Root CA）：
"%OPENSSL%" verify -CAfile "%CA_DIR%\rootCA.crt" "%INT_CRT%"

:: ── 建立憑證鏈檔案（Chain Bundle）────────────────────────────
echo.
echo [INFO] 建立憑證鏈檔案（chain.crt）...
copy /b "%INT_CRT%" + "%CA_DIR%\rootCA.crt" "%CA_DIR%\certs\chain.crt" >nul

echo.
echo [INFO] ================================================
echo [INFO]  Intermediate CA 憑證簽發完成！
echo [INFO] ================================================
echo.
echo [INFO] 輸出檔案：
echo        Intermediate CA 憑證：%INT_CRT%
echo        憑證鏈（Chain）      ：%CA_DIR%\certs\chain.crt
echo.
echo [INFO] 請將以下檔案複製回 Intermediate CA 機器：
echo        1. %INT_CRT%          （Intermediate CA 憑證）
echo        2. %CA_DIR%\rootCA.crt         （Root CA 憑證，供信任鏈使用）
echo        3. %CA_DIR%\crl\rootCA.crl     （Root CA CRL）
echo.
echo [WARN] 完成後請立即將此 VM 關機並保持離線！
echo.
pause
endlocal
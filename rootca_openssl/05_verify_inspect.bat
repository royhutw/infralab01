@echo off
:: ============================================================
::  05_verify_inspect.bat
::  憑證驗證與查看工具腳本
::  用途：上線時快速確認各憑證狀態與到期時間
:: ============================================================

setlocal

:: ── 參數區（請依實際環境修改） ──────────────────────────────
set CA_DIR=C:\RootCA
set OPENSSL=C:\OpenSSL-Win64\bin\openssl.exe

:: ────────────────────────────────────────────────────────────

echo.
echo [INFO] ================================================
echo [INFO]  Root CA 憑證狀態檢查
echo [INFO] ================================================
echo.

:: ── Root CA 憑證到期日 ────────────────────────────────────────
echo [1] Root CA 憑證到期資訊：
"%OPENSSL%" x509 -in "%CA_DIR%\rootCA.crt" -noout ^
    -subject -issuer -serial -startdate -enddate
echo.

:: ── CRL 到期日 ────────────────────────────────────────────────
echo [2] CRL 到期資訊：
if exist "%CA_DIR%\crl\rootCA.pem" (
    "%OPENSSL%" crl -in "%CA_DIR%\crl\rootCA.pem" -noout ^
        -issuer -lastupdate -nextupdate
) else (
    echo [WARN] 找不到 CRL 檔案：%CA_DIR%\crl\rootCA.pem
)
echo.

:: ── 已撤銷憑證清單 ────────────────────────────────────────────
echo [3] 已撤銷憑證清單（index.txt）：
if exist "%CA_DIR%\db\index.txt" (
    type "%CA_DIR%\db\index.txt"
    echo.
    for /f %%i in ('find /c "R " "%CA_DIR%\db\index.txt"') do echo [INFO] 已撤銷憑證數：%%i
) else (
    echo [WARN] 找不到資料庫檔案。
)
echo.

:: ── 已簽發憑證清單 ────────────────────────────────────────────
echo [4] 已簽發憑證清單（certs 目錄）：
dir /b "%CA_DIR%\certs\*.crt" 2>nul
echo.

:: ── 驗證 Intermediate CA 憑證鏈 ──────────────────────────────
echo [5] 驗證 Intermediate CA 憑證鏈：
if exist "%CA_DIR%\certs\intermediateCA.crt" (
    "%OPENSSL%" verify -CAfile "%CA_DIR%\rootCA.crt" ^
        "%CA_DIR%\certs\intermediateCA.crt"
) else (
    echo [INFO] 尚未簽發 Intermediate CA 憑證。
)
echo.

:: ── 目前 CRL 序號 ─────────────────────────────────────────────
echo [6] CRL 序號（crlnumber）：
if exist "%CA_DIR%\db\crlnumber" (
    type "%CA_DIR%\db\crlnumber"
) else (
    echo [WARN] 找不到 crlnumber 檔案。
)
echo.

echo [INFO] ================================================
echo [INFO]  檢查完畢
echo [INFO] ================================================
echo.
pause
endlocal
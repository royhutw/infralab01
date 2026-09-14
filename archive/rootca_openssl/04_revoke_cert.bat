@echo off
:: ============================================================
::  04_revoke_cert.bat
::  撤銷憑證腳本
::  執行時機：需要撤銷某張由 Root CA 直接簽發的憑證時
::  （若撤銷 Intermediate CA 簽發的憑證，請在 Intermediate CA 執行）
::  執行完畢後請重新執行 03_renew_crl.bat 更新 CRL
:: ============================================================

setlocal

:: ── 參數區（請依實際環境修改） ──────────────────────────────
set CA_DIR=C:\RootCA
set OPENSSL=C:\OpenSSL-Win64\bin\openssl.exe
set CONFIG=%CA_DIR%\openssl-rootca.cnf

:: ── 要撤銷的憑證路徑（請修改為實際路徑）────────────────────
set REVOKE_CRT=%CA_DIR%\certs\intermediateCA.crt

:: ── 撤銷原因（請從下列選項擇一填入）────────────────────────
::   unspecified       - 未指定原因
::   keyCompromise     - 私鑰外洩（最常用）
::   cACompromise      - CA 私鑰外洩
::   affiliationChanged- 組織異動
::   superseded        - 已被新憑證取代
::   cessationOfOperation - 服務停止運作
::   certificateHold   - 暫時凍結
set REVOKE_REASON=keyCompromise

:: ────────────────────────────────────────────────────────────

echo.
echo [INFO] ================================================
echo [INFO]  憑證撤銷作業
echo [INFO] ================================================
echo.

:: ── 確認憑證存在 ─────────────────────────────────────────────
if not exist "%REVOKE_CRT%" (
    echo [ERROR] 找不到憑證：%REVOKE_CRT%
    echo [INFO]  請修改腳本中的 REVOKE_CRT 路徑後重新執行。
    pause
    exit /b 1
)

:: ── 顯示憑證資訊供確認 ───────────────────────────────────────
echo [INFO] 即將撤銷的憑證資訊：
"%OPENSSL%" x509 -in "%REVOKE_CRT%" -noout ^
    -subject -issuer -serial -startdate -enddate
echo.
echo [WARN] 撤銷原因：%REVOKE_REASON%
echo [WARN] 此操作無法復原（除非使用 certificateHold 暫時凍結）！
echo.
set /p CONFIRM=確認撤銷？請輸入 YES 繼續，其他鍵取消：
if /i not "%CONFIRM%"=="YES" (
    echo [INFO] 已取消撤銷操作。
    pause
    exit /b 0
)

:: ── 執行撤銷 ─────────────────────────────────────────────────
echo.
echo [INFO] 執行撤銷，請輸入 Root CA 私鑰密碼：
echo.
"%OPENSSL%" ca -config "%CONFIG%" ^
    -revoke "%REVOKE_CRT%" ^
    -crl_reason %REVOKE_REASON%

if errorlevel 1 (
    echo [ERROR] 撤銷失敗！
    pause
    exit /b 1
)

echo.
echo [INFO] ================================================
echo [INFO]  憑證已成功撤銷！
echo [INFO] ================================================
echo.
echo [WARN] 重要：撤銷後必須立即更新並發布 CRL！
echo [WARN] 請接著執行：03_renew_crl.bat
echo.
pause
endlocal
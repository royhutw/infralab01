@echo off
:: ============================================================
::  04_revoke_cert.bat
::  撤銷憑證腳本
::  執行時機：需要撤銷某張由 Root CA 直接簽發的憑證時
::  （若撤銷 Intermediate CA 簽發的憑證，請在 Intermediate CA 執行）
::  執行完畢後請重新執行 03_renew_crl.bat 更新 CRL
::
::  用法：
::    04_revoke_cert.bat "<憑證檔案完整路徑>" <撤銷原因>
::    04_revoke_cert.bat                         （不帶參數則進入互動模式）
::
::  範例：
::    04_revoke_cert.bat "C:\RootCA\certs\intermediateCA.crt" keyCompromise
::
::  【變更說明】原本要撤銷的憑證路徑與原因需要直接編輯本檔案，
::  這是最容易出錯的一步。現在改為命令列參數 / 互動輸入，
::  不需要再修改任何腳本原始碼。
:: ============================================================

setlocal EnableDelayedExpansion
call "%~dp0ca-env.bat"

set REVOKE_CRT=%~1
set REVOKE_REASON=%~2

echo.
echo [INFO] ================================================
echo [INFO]  憑證撤銷作業
echo [INFO] ================================================
echo.

:: ── 若未帶入憑證路徑，進入互動輸入 ───────────────────────────
if "%REVOKE_CRT%"=="" (
    echo [INFO] 目前 %CA_DIR%\certs\ 底下的憑證檔案：
    dir /b "%CA_DIR%\certs\*.crt" 2>nul
    echo.
    set /p REVOKE_CRT=請輸入欲撤銷的憑證完整路徑：
)

if not exist "%REVOKE_CRT%" (
    echo [ERROR] 找不到憑證：%REVOKE_CRT%
    pause
    exit /b 1
)

:: ── 若未帶入撤銷原因，進入互動選單 ───────────────────────────
if "%REVOKE_REASON%"=="" (
    echo.
    echo [INFO] 請選擇撤銷原因：
    echo        1. keyCompromise          - 私鑰外洩（最常用）
    echo        2. cACompromise           - CA 私鑰外洩
    echo        3. affiliationChanged     - 組織異動
    echo        4. superseded             - 已被新憑證取代
    echo        5. cessationOfOperation   - 服務停止運作
    echo        6. certificateHold        - 暫時凍結
    echo        7. unspecified            - 未指定原因
    set /p REASON_CHOICE=請輸入選項編號：

    if "!REASON_CHOICE!"=="1" set REVOKE_REASON=keyCompromise
    if "!REASON_CHOICE!"=="2" set REVOKE_REASON=cACompromise
    if "!REASON_CHOICE!"=="3" set REVOKE_REASON=affiliationChanged
    if "!REASON_CHOICE!"=="4" set REVOKE_REASON=superseded
    if "!REASON_CHOICE!"=="5" set REVOKE_REASON=cessationOfOperation
    if "!REASON_CHOICE!"=="6" set REVOKE_REASON=certificateHold
    if "!REASON_CHOICE!"=="7" set REVOKE_REASON=unspecified
)

if "%REVOKE_REASON%"=="" (
    echo [ERROR] 未選擇有效的撤銷原因，中止執行。
    pause
    exit /b 1
)

:: ── 顯示憑證資訊供確認 ───────────────────────────────────────
echo.
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
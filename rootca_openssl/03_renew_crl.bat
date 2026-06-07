@echo off
:: ============================================================
::  03_renew_crl.bat
::  Root CA 年度 CRL 更新腳本
::  執行時機：每年 Root CA 需要上線時執行
::  執行完畢後請立即將更新的 CRL 複製到發布伺服器，然後關機
:: ============================================================

setlocal

:: ── 參數區（請依實際環境修改） ──────────────────────────────
set CA_DIR=C:\RootCA
set OPENSSL=C:\OpenSSL-Win64\bin\openssl.exe
set CONFIG=%CA_DIR%\openssl-rootca.cnf

:: CRL 有效期（天）- 設 400 天，預留 35 天緩衝
set CRL_DAYS=400

:: CRL 發布目的地（若有網路可直接複製，否則手動複製）
:: set CRL_PUBLISH=\\fileserver\pki\rootCA.crl

:: ────────────────────────────────────────────────────────────

:: ── 取得目前時間（用於備份檔名）──────────────────────────────
for /f "tokens=1-3 delims=/ " %%a in ('date /t') do (
    set TODAY=%%c%%b%%a
)
for /f "tokens=1-2 delims=: " %%a in ('time /t') do (
    set NOWTIME=%%a%%b
)
set TIMESTAMP=%TODAY%_%NOWTIME%

echo.
echo [INFO] ================================================
echo [INFO]  Root CA 年度 CRL 更新
echo [INFO]  時間戳記：%TIMESTAMP%
echo [INFO] ================================================
echo.

:: ── 備份舊的 CRL ─────────────────────────────────────────────
echo [1/4] 備份舊的 CRL...
if exist "%CA_DIR%\crl\rootCA.pem" (
    copy "%CA_DIR%\crl\rootCA.pem" "%CA_DIR%\crl\rootCA_%TIMESTAMP%.pem.bak" >nul
    echo [INFO] 已備份至：rootCA_%TIMESTAMP%.pem.bak
) else (
    echo [WARN] 找不到舊 CRL，將直接產生新 CRL。
)

:: ── 顯示目前撤銷清單 ──────────────────────────────────────────
echo.
echo [2/4] 目前已撤銷的憑證清單：
if exist "%CA_DIR%\crl\rootCA.pem" (
    "%OPENSSL%" crl -in "%CA_DIR%\crl\rootCA.pem" -noout -text 2>nul | findstr /i "Serial Reason Date Issuer"
) else (
    echo [INFO] （目前無已撤銷憑證）
)
echo.

:: ── 產生新 CRL（PEM 格式）────────────────────────────────────
echo [3/4] 產生新 CRL（有效期 %CRL_DAYS% 天）...
echo [INFO] 請輸入 Root CA 私鑰密碼：
echo.
"%OPENSSL%" ca -config "%CONFIG%" ^
    -gencrl ^
    -crldays %CRL_DAYS% ^
    -out "%CA_DIR%\crl\rootCA.pem"

if errorlevel 1 (
    echo [ERROR] CRL 產生失敗！請確認 Root CA 私鑰密碼是否正確。
    pause
    exit /b 1
)

:: ── 轉換為 DER 格式（.crl）───────────────────────────────────
echo.
echo [4/4] 轉換為 DER 格式（.crl）...
"%OPENSSL%" crl ^
    -in  "%CA_DIR%\crl\rootCA.pem" ^
    -outform DER ^
    -out "%CA_DIR%\crl\rootCA.crl"

if errorlevel 1 (
    echo [ERROR] DER 格式轉換失敗！
    pause
    exit /b 1
)

:: ── 同時備份一份含時間戳記的 DER CRL（長期保存） ─────────────
copy "%CA_DIR%\crl\rootCA.crl" "%CA_DIR%\crl\rootCA_%TIMESTAMP%.crl" >nul

:: ── 驗證新 CRL ────────────────────────────────────────────────
echo.
echo [INFO] 新 CRL 資訊：
"%OPENSSL%" crl -in "%CA_DIR%\crl\rootCA.pem" -noout ^
    -issuer -lastupdate -nextupdate

:: ── 選用：自動複製到發布伺服器 ───────────────────────────────
:: if defined CRL_PUBLISH (
::     echo [INFO] 複製 CRL 到發布伺服器...
::     copy "%CA_DIR%\crl\rootCA.crl" "%CRL_PUBLISH%" >nul
::     if errorlevel 1 (
::         echo [WARN] 自動複製失敗，請手動複製！
::     ) else (
::         echo [INFO] 已成功發布到：%CRL_PUBLISH%
::     )
:: )

echo.
echo [INFO] ================================================
echo [INFO]  CRL 更新完成！
echo [INFO] ================================================
echo.
echo [INFO] 輸出檔案（請複製到 CRL 發布伺服器）：
echo.
echo        PEM 格式：%CA_DIR%\crl\rootCA.pem
echo        DER 格式：%CA_DIR%\crl\rootCA.crl  ← 發布用
echo        備份檔案：%CA_DIR%\crl\rootCA_%TIMESTAMP%.crl
echo.
echo [INFO] CRL 發布後，請確認：
echo        1. 將 rootCA.crl 複製到 Web / 檔案伺服器
echo        2. URL 路徑須與憑證內 CDP 欄位一致
echo        3. 下次需在有效期到期前執行此腳本更新
echo.
echo [WARN] ================================================
echo [WARN]  請完成 CRL 複製後立即關機，保持 Root CA 離線！
echo [WARN] ================================================
echo.
pause
endlocal
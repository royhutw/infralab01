@echo off
:: ============================================================
::  ca-env.bat
::  Root CA 共用環境參數（唯一參數來源）
::
::  【重要】所有其他腳本一律用 call 載入本檔案，
::         不要在個別 .bat 裡重複 set 這些變數。
::         修改路徑 / 天數 / DN 欄位，只需要改這一個檔案。
::
::  本檔案同時提供變數給 openssl-rootca.cnf 透過
::  $ENV::變數名稱 讀取（見該檔案的對應段落），
::  因此 CA_DIR / DN 欄位 / CRL URL 不會有第二個定義來源。
:: ============================================================

:: ── 執行環境路徑 ──────────────────────────────────────────────
:: 注意：這裡刻意使用正斜線 (/)，Windows 與 OpenSSL 都能正確解析，
:: 且可讓 openssl-rootca.cnf 用同一個字串 (dir = $ENV::CA_DIR) 直接引用，
:: 不需要再另外維護一份 C:/RootCA。
set CA_DIR=C:/RootCA
set OPENSSL=C:/OpenSSL-Win64/bin/openssl.exe
set CONFIG=%CA_DIR%/openssl-rootca.cnf

:: ── 金鑰長度與有效期（天）────────────────────────────────────
set KEY_BITS=4096
set CA_DAYS=9131
:: Root CA 憑證：25 年
set INT_DAYS=3650
:: Intermediate CA 憑證：10 年
set CRL_DAYS=400
:: CRL：400 天（含 35 天緩衝，每年更新一次）

:: ── Root CA 辨別名稱（DN）────────────────────────────────────
:: 這些值會透過 $ENV:: 被 openssl-rootca.cnf 的
:: [req_distinguished_name] 區塊直接引用，兩邊不會不一致。
set CA_COUNTRY=TW
set CA_STATE=
set CA_LOCALITY=
set CA_ORG=MyOrg Ltd
set CA_OU=
set CA_CN=MyOrg Root CA

:: ── CRL 發布 URL ──────────────────────────────────────────────
:: 對應 openssl-rootca.cnf 的 crlDistributionPoints。
:: 以前需要另外去改 .cnf，現在只需要改這裡一處。
set CA_CRL_URL=http://crl.corp.foo.bar.tw/crl/rootca.crl